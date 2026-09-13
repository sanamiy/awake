#!/bin/zsh
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
source "$PROJECT_DIR/scripts/product-config.zsh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
command -v xcodegen >/dev/null || { print -u2 'xcodegenが必要です: brew install xcodegen'; exit 1; }
xcodegen generate
identity="${CODE_SIGN_IDENTITY:--}"
signing_options=()
if [[ "$identity" == 'Developer ID Application:'* ]]; then
  # Developer ID distribution needs Apple's secure timestamp, not a local signing time.
  signing_options+=("OTHER_CODE_SIGN_FLAGS=--timestamp" "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO")
fi
xcodebuild -project LidAwake.xcodeproj -scheme LidAwake -configuration Release \
  -derivedDataPath .build -destination 'generic/platform=macOS' \
  "CODE_SIGN_IDENTITY=$identity" CODE_SIGN_STYLE=Manual "${signing_options[@]}" build
mkdir -p dist
if [[ -e "dist/$LA_APP_NAME.app" ]]; then
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "dist/$LA_APP_NAME.app/Contents/Info.plist" | /usr/bin/grep -qxF "$LA_BUNDLE_ID" || exit 1
  /bin/rm -rf "$PROJECT_DIR/dist/$LA_APP_NAME.app"
fi
/usr/bin/ditto ".build/Build/Products/Release/$LA_APP_NAME.app" "dist/$LA_APP_NAME.app"
/usr/bin/codesign --verify --deep --strict "dist/$LA_APP_NAME.app"
print -- "ビルド完了: $PROJECT_DIR/dist/$LA_APP_NAME.app"
