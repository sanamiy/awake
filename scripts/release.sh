#!/bin/zsh
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
source "$PROJECT_DIR/scripts/product-config.zsh"

if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
  print -r -- '使い方: ./scripts/release.sh

ビルド → アプリ署名 → PKG作成・署名 → Apple公証 → チケット添付 → Gatekeeper検証
出力: dist/<アプリ名>-<App/Info.plistのバージョン>.pkg

config/Product.xcconfigに指定したDeveloper ID署名者と公証用キーチェーンを使用します。
認証情報・証明書の秘密鍵はキーチェーンに事前登録してください。
CODE_SIGN_IDENTITY / INSTALLER_SIGN_IDENTITY / NOTARY_PROFILE / DEVELOPER_DIRで上書きできます。
配布先の変更はconfig/Product.xcconfigにまとめて設定します（docs/SIGNING.md参照）。

機能テスト、バージョン更新、インストール、GitHubへの公開は行いません。
同じバージョンのdist内の成果物は置き換えます。'
  exit 0
fi
(( $# == 0 )) || { print -u2 '引数が不正です。--helpで使い方を確認してください。'; exit 2; }

# These are public signing identities and a Keychain reference, not credentials.
export CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-${LA_APPLICATION_IDENTITY}}"
export INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-${LA_INSTALLER_IDENTITY}}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-$LA_NOTARY_PROFILE}"
[[ "$CODE_SIGN_IDENTITY" == 'Developer ID Application:'* ]] || {
  print -u2 'Apple Development / Apple DistributionではなくDeveloper ID Applicationが必要です。'; exit 1
}
[[ "$INSTALLER_SIGN_IDENTITY" == 'Developer ID Installer:'* ]] || {
  print -u2 'PKG署名にはDeveloper ID Installerが必要です。'; exit 1
}
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
/bin/zsh scripts/build.sh
/bin/zsh scripts/package-pkg.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "dist/$LA_APP_NAME.app/Contents/Info.plist")
readonly PKG="$PROJECT_DIR/dist/${LA_APP_NAME}-$version.pkg"
# Notarize the outermost container, including its signed app, only once.
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
/usr/sbin/spctl --assess --type install --verbose=2 "$PKG"
print -- "公証済みインストーラー: $PKG"
