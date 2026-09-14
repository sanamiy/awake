#!/bin/zsh
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h}"
source "$PROJECT_DIR/scripts/product-config.zsh"
readonly SOURCE_APP="$PROJECT_DIR/dist/$LA_APP_NAME.app"
: "${INSTALLER_SIGN_IDENTITY:?Developer ID Installer証明書をINSTALLER_SIGN_IDENTITYで指定してください}"
[[ "$INSTALLER_SIGN_IDENTITY" == 'Developer ID Installer:'* ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" == "$LA_BUNDLE_ID" ]] || exit 1
/usr/bin/codesign --verify --deep --strict \
  -R "$LA_SIGNING_REQUIREMENT" "$SOURCE_APP"
/usr/bin/codesign --verify --strict -R "$LA_RECOVERY_SIGNING_REQUIREMENT" \
  "$SOURCE_APP/Contents/Helpers/AwakeRecovery"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")
[[ -n "$version" && "$version" != *[^0-9A-Za-z._-]* ]] || exit 1
task_work=$(/usr/bin/mktemp -d "$PROJECT_DIR/dist/.pkg-build.XXXXXX")
trap '/bin/rm -rf "$task_work"' EXIT
/bin/mkdir -p "$task_work/root/Applications"
/usr/bin/ditto "$SOURCE_APP" "$task_work/root$LA_APP_PATH"
python3 "$PROJECT_DIR/scripts/configure.py" --installer-dir "$task_work/installer"
/usr/bin/pkgbuild --analyze --root "$task_work/root" "$task_work/components.plist"
# Never relocate to a development build or the mounted installer. Replace the
# whole bundle so files removed in a new release cannot linger in the old app.
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$task_work/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked false' "$task_work/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleHasStrictIdentifier true' "$task_work/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleOverwriteAction upgrade' "$task_work/components.plist"
/usr/bin/pkgbuild --root "$task_work/root" --install-location / \
  --identifier "$LA_PACKAGE_ID" --version "$version" --ownership recommended \
  --component-plist "$task_work/components.plist" --scripts "$task_work/installer/scripts" \
  "$task_work/component.pkg"
/usr/bin/productbuild --distribution "$task_work/installer/Distribution.xml" \
  --resources "$task_work/installer/resources" --package-path "$task_work" \
  --sign "$INSTALLER_SIGN_IDENTITY" --timestamp "$task_work/${LA_APP_NAME}-$version.pkg"
/usr/sbin/pkgutil --check-signature "$task_work/${LA_APP_NAME}-$version.pkg"
/bin/mv -f "$task_work/${LA_APP_NAME}-$version.pkg" "$PROJECT_DIR/dist/${LA_APP_NAME}-$version.pkg"
print -- "署名済みPKG（公証は別途必要）: $PROJECT_DIR/dist/${LA_APP_NAME}-$version.pkg"
