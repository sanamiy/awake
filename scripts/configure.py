#!/usr/bin/env python3
"""Render distribution metadata and self-contained runtime from Product.xcconfig."""
import argparse
import html
import re
import shlex
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def read_config(path):
    values = {}
    for line in path.read_text().splitlines():
        line = line.split('//', 1)[0].strip()
        if not line:
            continue
        match = re.fullmatch(r'([A-Z_]+)\s*=\s*(.+?)\s*', line)
        if not match or match[1] in values:
            raise ValueError('Invalid or duplicate product setting: ' + line)
        values[match[1]] = match[2]
    patterns = {
        'AWAKE_APP_NAME': r'[A-Za-z0-9][A-Za-z0-9 ._-]*',
        'AWAKE_BUNDLE_ID': r'[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)+',
        'AWAKE_PACKAGE_ID': r'[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)+',
        'AWAKE_TEAM_ID': r'[A-Z0-9]{10}',
        'AWAKE_SIGNING_NAME': r'[A-Za-z0-9][A-Za-z0-9 ._-]*',
        'AWAKE_NOTARY_PROFILE': r'[A-Za-z0-9][A-Za-z0-9._-]*',
        'MACOSX_DEPLOYMENT_TARGET': r'[0-9]+\.[0-9]+(?:\.[0-9]+)?',
        'ARCHS': r'(?:arm64|x86_64)(?: (?:arm64|x86_64))?',
    }
    if set(values) != set(patterns):
        raise ValueError('Product settings have missing or unknown keys')
    for key, pattern in patterns.items():
        if not re.fullmatch(pattern, values[key]):
            raise ValueError('Invalid product setting: ' + key)
    return values

def shell_config(values):
    name = values['AWAKE_APP_NAME']
    app = '/Applications/' + name + '.app'
    shell = {
        'LA_APP_NAME': name,
        'LA_BUNDLE_ID': values['AWAKE_BUNDLE_ID'],
        'LA_PACKAGE_ID': values['AWAKE_PACKAGE_ID'],
        'LA_MIN_OS': values['MACOSX_DEPLOYMENT_TARGET'],
        'LA_ARCHS': values['ARCHS'],
        'LA_APP_PATH': app,
        'LA_EXECUTABLE': app + '/Contents/MacOS/' + name,
        'LA_APPLICATION_IDENTITY': 'Developer ID Application: ' + values['AWAKE_SIGNING_NAME'] + ' (' + values['AWAKE_TEAM_ID'] + ')',
        'LA_INSTALLER_IDENTITY': 'Developer ID Installer: ' + values['AWAKE_SIGNING_NAME'] + ' (' + values['AWAKE_TEAM_ID'] + ')',
        'LA_NOTARY_PROFILE': values['AWAKE_NOTARY_PROFILE'],
        'LA_SIGNING_REQUIREMENT': '=identifier "' + values['AWAKE_BUNDLE_ID'] + '" and anchor apple generic and certificate leaf[subject.OU] = "' + values['AWAKE_TEAM_ID'] + '"',
    }
    return '# Generated from config/Product.xcconfig; do not edit.\n' + ''.join(
        'typeset -g ' + key + '=' + shlex.quote(value) + '\n' for key, value in shell.items())

def render(text, values):
    replacements = {**values, 'INSTALLER_ARCHS': values['ARCHS'].replace(' ', ',')}
    for key, value in replacements.items():
        text = text.replace('@' + key + '@', html.escape(value, quote=True))
    if re.search(r'@[A-Z_]+@', text):
        raise ValueError('Unresolved product template token')
    return text

def runtime(directory, values):
    (directory / 'bin').mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'runtime/bin/lid-awake').read_text()
    for variable, key in [('PROGRAM_NAME', 'AWAKE_APP_NAME'), ('PROGRAM_BUNDLE_ID', 'AWAKE_BUNDLE_ID')]:
        marker = f'readonly {variable}="@{key}@"'
        if source.count(marker) != 1:
            raise ValueError('Runtime product marker is missing or duplicated: ' + key)
        source = source.replace(marker, f'readonly {variable}=' + shlex.quote(values[key]))
    target = directory / 'bin/lid-awake'
    target.write_text(source)
    target.chmod(0o755)
    for name in ['setup-runtime.sh', 'uninstall.sh']:
        shutil.copy2(ROOT / 'runtime' / name, directory / name)
    shutil.copy2(ROOT / 'LICENSE', directory / 'LICENSE')

def installer(directory, values):
    scripts = directory / 'scripts'
    resources = directory / 'resources'
    scripts.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    (scripts / 'product.zsh').write_text(shell_config(values))
    for name in ['preinstall', 'postinstall', 'pkg-common.zsh']:
        shutil.copy2(ROOT / 'installer' / name, scripts / name)
    (directory / 'Distribution.xml').write_text(render((ROOT / 'installer/Distribution.xml.in').read_text(), values))
    for template in (ROOT / 'installer/resources').glob('*.html.in'):
        (resources / template.stem).write_text(render(template.read_text(), values))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / 'config/Product.xcconfig')
    parser.add_argument('--shell-file', type=Path)
    parser.add_argument('--runtime-dir', type=Path)
    parser.add_argument('--installer-dir', type=Path)
    args = parser.parse_args()
    if not any([args.shell_file, args.runtime_dir, args.installer_dir]):
        parser.error('Specify an output')
    values = read_config(args.config)
    if args.shell_file:
        args.shell_file.write_text(shell_config(values))
    if args.runtime_dir:
        runtime(args.runtime_dir, values)
    if args.installer_dir:
        installer(args.installer_dir, values)

if __name__ == '__main__':
    main()
