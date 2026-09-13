#!/usr/bin/env python3
"""Check generated product artifacts; user documentation is not inspected."""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('product_configure', ROOT / 'scripts/configure.py')
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)

class ProductConfigurationTests(unittest.TestCase):
    def test_alternate_product_reaches_installer_and_standalone_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            values = configure.read_config(ROOT / 'config/Product.xcconfig')
            values.update(AWAKE_APP_NAME='Test Product', AWAKE_BUNDLE_ID='example.test.app',
                          AWAKE_PACKAGE_ID='example.test.pkg', AWAKE_TEAM_ID='A1B2C3D4E5',
                          AWAKE_SIGNING_NAME='Example Labs', AWAKE_NOTARY_PROFILE='example-notary',
                          MACOSX_DEPLOYMENT_TARGET='27.1', ARCHS='arm64 x86_64')
            config = root / 'Product.xcconfig'
            config.write_text(''.join(f'{key} = {value}\n' for key, value in values.items()))
            subprocess.run([sys.executable, str(ROOT / 'scripts/configure.py'), '--config', str(config),
                            '--runtime-dir', str(root / 'runtime'), '--installer-dir', str(root / 'installer')], check=True)
            distribution = ET.parse(root / 'installer/Distribution.xml').getroot()
            self.assertEqual(distribution.findtext('title'), 'Test Product')
            self.assertEqual(distribution.find('options').get('hostArchitectures'), 'arm64,x86_64')
            self.assertEqual(distribution.find('allowed-os-versions/os-version').get('min'), '27.1')
            self.assertEqual(distribution.find('pkg-ref/must-close/app').get('id'), 'example.test.app')
            refs = distribution.findall('pkg-ref')
            self.assertTrue(all(ref.get('id') == 'example.test.pkg' for ref in refs))
            self.assertIn('component.pkg', [ref.text for ref in refs])
            # Source definitions only, with no CLI action or privileged operation.
            result = subprocess.run(['/bin/zsh', '-f', '-c',
                'source "$1"; source "$2"; print -r -- "$PROGRAM_NAME" "$DEFAULT_AUTHORIZER" "$LA_EXECUTABLE" "$LA_SIGNING_REQUIREMENT" "$LA_INSTALLER_IDENTITY"; [[ "$PROGRAM_BUNDLE_ID" == "$LA_BUNDLE_ID" ]]',
                'fixture', str(root / 'installer/scripts/product.zsh'), str(root / 'runtime/bin/lid-awake')],
                check=True, capture_output=True, text=True).stdout
            self.assertIn('/Applications/Test Product.app/Contents/MacOS/Test Product', result)
            self.assertIn('identifier "example.test.app"', result)
            self.assertIn('certificate leaf[subject.OU] = "A1B2C3D4E5"', result)
            self.assertIn('Developer ID Installer: Example Labs (A1B2C3D4E5)', result)
            for name in ['setup-runtime.sh', 'uninstall.sh', 'bin/lid-awake']:
                subprocess.run(['/bin/zsh', '-n', str(root / 'runtime' / name)], check=True)
            for path in (root / 'installer').rglob('*'):
                if path.is_file():
                    self.assertNotRegex(path.read_text(), r'@[A-Z_]+@')

    def test_invalid_path_shell_expression_and_missing_keys_are_rejected(self):
        original = (ROOT / 'config/Product.xcconfig').read_text()
        product_name = configure.read_config(ROOT / 'config/Product.xcconfig')['AWAKE_APP_NAME']
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / 'Product.xcconfig'
            for name in ['../Other', '$(touch /tmp/should-not-exist)', 'App; false']:
                config.write_text(original.replace('AWAKE_APP_NAME = ' + product_name, 'AWAKE_APP_NAME = ' + name))
                with self.assertRaises(ValueError):
                    configure.read_config(config)
            config.write_text('\n'.join(line for line in original.splitlines() if not line.startswith('AWAKE_TEAM_ID')))
            with self.assertRaises(ValueError):
                configure.read_config(config)

    def test_current_runtime_and_installer_paths_agree(self):
        values = configure.read_config(ROOT / 'config/Product.xcconfig')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            configure.runtime(root / 'runtime', values)
            (root / 'product.zsh').write_text(configure.shell_config(values))
            subprocess.run(['/bin/zsh', '-f', '-c',
                'source "$1"; source "$2"; [[ "$DEFAULT_AUTHORIZER" == "$LA_EXECUTABLE" && "$PROGRAM_NAME" == "$LA_APP_NAME" && "$PROGRAM_BUNDLE_ID" == "$LA_BUNDLE_ID" ]]',
                'fixture', str(root / 'product.zsh'), str(root / 'runtime/bin/lid-awake')], check=True)

if __name__ == '__main__':
    unittest.main()
