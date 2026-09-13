# 配布用署名と公証

[開発環境](DEVELOPMENT.md#開発テスト)に加え、有効なDeveloper ID Application証明書と対応する秘密鍵が必要です。PKGにはDeveloper ID Installer証明書とその秘密鍵も必要です。コマンドはリポジトリのルートで実行します。
Apple Development / Apple Distributionは、Mac App Store外への直接配布用証明書ではありません。
秘密鍵、パスワード、APIキーはリポジトリに保存しないでください。

別の署名者で配布する場合は、[製品設定](DEVELOPMENT.md#製品設定の変更)の署名情報と、使用する証明書・キーチェーンを変更してください。生成されるPKGもその署名者を検証します。

通常のリリース作成は [PKGを公証して配布する](#pkgを公証して配布する) の一括手順を使います。以下の署名・PKG生成は、工程を個別に実行するときの手順です。

## 署名だけ行う

`security find-identity -v -p codesigning`で証明書名を確認し、指定します。

```zsh
source ./scripts/product-config.zsh
export CODE_SIGN_IDENTITY="$LA_APPLICATION_IDENTITY"
./scripts/build.sh
```

`dist/Awake.app`が作成されます。Developer IDを指定すると、Hardened Runtimeに加え、Appleの安全なタイムスタンプを付けます。署名だけでは公証済みにはなりません。

## 初期設定付きPKGを作る

上の署名手順でアプリを作成してから実行します。このスクリプトは `dist/` の署名済みアプリを使い、アプリの再ビルドはしません。

```zsh
source ./scripts/product-config.zsh
export INSTALLER_SIGN_IDENTITY="$LA_INSTALLER_IDENTITY"
./scripts/package-pkg.sh
```

`dist/Awake-<バージョン>.pkg`が作成されます。アプリは`/Applications`に固定し、旧バージョンは丸ごと置き換えます。開発用のアプリやDMG内へインストール先を自動変更しません。インストール前にAwakeの終了とログインユーザーを確認し、同じユーザーの電源制御・復旧機能を設定します。

インストーラーの配置・権限・失敗時の扱いは [DEVELOPMENT.md](DEVELOPMENT.md#インストールと実行環境)、停止できない場合の操作は [TROUBLESHOOTING.md](TROUBLESHOOTING.md) を参照してください。

## PKGを公証して配布する

`scripts/release.sh` がビルドから署名・公証・最終検証までを一括実行します。これはApp Storeへの公開ではなく、Appleの公証サービスへの送信です。公証は機能の正しさを保証しないため、別途機能テストも必要です。

```zsh
./scripts/release.sh
```

共通設定に指定したDeveloper ID Application／Installer証明書と、公証用キーチェーンプロファイルを使用します。認証情報そのものや秘密鍵はリポジトリに保存しません。他のMacでは対応する証明書・秘密鍵・公証プロファイルを先にキーチェーンへ登録してください。

一時的に別の証明書やキーチェーンを使う場合は、`CODE_SIGN_IDENTITY`・`INSTALLER_SIGN_IDENTITY`・`NOTARY_PROFILE`・`DEVELOPER_DIR`で上書きできます。署名者のTeam IDは共通設定と一致させてください。

実行場所は問いません。リポジトリ外からはスクリプトの絶対パスで実行できます。`--help`はビルドや通信をせず使い方を表示します。途中の処理が失敗したら終了し、最後の検証まで成功した場合だけ「公証済みインストーラー」と出力します。

バージョン番号は`App/Info.plist`から取得し、自動では増やしません。機能テスト、インストール、GitHubへの公開も行いません。再実行すると同じバージョンの`dist`内の成果物は置き換わるため、配布済み版を保持する場合は先にバージョン番号を更新してください。

署名済みPKGをAppleに送信し、承認後にチケットをPKGへ添付してGatekeeperの判定を検証します。既に作成したPKGを再ビルドせず公証する場合は、`xcrun notarytool submit <PKGのパス> --keychain-profile <プロファイル名> --wait`を実行し、承認後に`xcrun stapler staple <PKGのパス>`、`xcrun stapler validate <PKGのパス>`、`spctl --assess --type install --verbose=2 <PKGのパス>`を実行します。公証済みとして渡すのは承認・添付・Gatekeeper検証のすべてが成功したファイルだけです。

参考: [Apple — macOS向け配布署名](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)

## GitHubで公開する

ソースコードは既存の[MITライセンス](../LICENSE)で管理しています。ビルドに必要な `App/AppIcon.icon` と各スクリプトを含め、生成されたXcodeプロジェクト・ビルド成果物・実機テストの生ログ・認証情報は公開対象から除外します。除外設定は `.gitignore` にあります。署名者のTeam IDや公証用キーチェーンプロファイルの名前は認証情報そのものではありません。秘密鍵や公証の認証情報は各開発者のキーチェーンで管理してください。

GitHubで配布する際は、公証済みPKGをReleasesに添付し、READMEにそのダウンロード先を追加します。ソースコード内にPKGをコミットする必要はありません。リリース説明には、その版で実機確認した環境と範囲を記載してください。模擬テストの成功や消灯要求の成功を、蓋閉じ中の実機動作や通信維持の確認と同一視しないでください。

## 配布経路

現行版はMac App Store向けの構成ではありません。App Sandboxを有効にしておらず、PKGによるsudoers・CLI・LaunchAgentの配置と管理者権限での電源制御に依存します。[Appleの審査ガイドライン](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)の2.4.5では、Sandbox、アプリ単体で完結する配置、root権限への昇格禁止などが求められています。また、公開仕様にないロック状態キーや電源制御への依存は、2.5.1の公開API要件に照らして見直しが必要です。公証の承認はApp Store審査の承認ではありません。
