# 開発者向けガイド

利用方法は[README](../README.md)、期待する動作は[製品仕様](SPEC.md)、配布版のビルド・署名・公証は[SIGNING.md](SIGNING.md)、エラーの設計は[ERRORS.md](ERRORS.md)を参照してください。以下のコマンドはリポジトリのルートで実行します。

## 製品設定の変更

[config/Product.xcconfig](../config/Product.xcconfig)が、アプリ名・Bundle ID・インストーラーID・対応OS・CPU・署名者・公証プロファイルの共通設定です。表示名はアプリのInfo.plistから `AppIdentity` を通じてUIへ反映します。プロジェクト・モジュール名、CLI名、保存先の内部識別子は別の用途なので表示名から派生させません。

Xcodeは共通設定を直接参照します。[scripts/configure.py](../scripts/configure.py)は、同じ値からPKGのXML・案内・署名要件と、単体実行できる同梱CLIを生成します。Python 3は開発・ビルド時だけ必要で、利用者のMacでは使いません。

`runtime/bin/lid-awake` は製品名を埋め込む前のソースです。そのまま実行せず、ビルドしたアプリに同梱されたCLIか、インストール済みのCLIを使ってください。生成物の直接編集は不要です。対応CPUの設定変更だけで、そのCPUでの動作を保証するものではありません。

設定の既定値・入力範囲は [Preferences.swift](../App/Preferences.swift)、バージョンとビルド番号は [App/Info.plist](../App/Info.plist) にあります。設定は一つのCodableデータとしてUserDefaultsに保存し、欠落・デコード失敗・範囲外なら既定値を使います。旧形式の移行処理はありません。

開始時にはアプリが時間・残量をCLIへ渡し、CLIに既定値は持たせません。両境界の入力検証と範囲の一致は維持します。CLIの `_start`・`_monitor`・`_recover` は内部操作で、利用者向けの呼び出し口ではありません。

## 実装の入口

`App/` はアプリ本体、`runtime/` はアプリに同梱する処理、`installer/` はPKGの処理と素材、`scripts/` は開発用ツールです。テストは `Tests/App/` と `Tests/Scripts/` に分けています。

| 変更対象 | 主な実装 |
| --- | --- |
| 設定画面・ショートカット入力 | [ContentView](../App/ContentView.swift)、[SettingsHeader](../App/SettingsHeader.swift)、[HotKeySetting](../App/HotKeySetting.swift)、[HotKeyRecorder](../App/HotKeyRecorder.swift) |
| 操作の状態管理・監視 | [AppModel](../App/AppModel.swift)、[ScreenLockSession](../App/ScreenLockSession.swift)、[LidDisplaySleep](../App/LidDisplaySleep.swift) |
| 起動・終了・キー登録 | [LidAwakeApp](../App/LidAwakeApp.swift)、[LoginStartup](../App/LoginStartup.swift)、[GlobalHotKey](../App/GlobalHotKey.swift) |
| アプリとCLIの境界 | [RuntimeClient](../App/RuntimeClient.swift)、[CommandRunner](../App/CommandRunner.swift)、[AppFailure](../App/AppFailure.swift) |
| 電源制御・復旧 | [runtime/bin/lid-awake](../runtime/bin/lid-awake)、[AdministrativeAuthorization](../App/AdministrativeAuthorization.swift) |
| インストール・削除 | [installer](../installer)、[setup-runtime.sh](../runtime/setup-runtime.sh)、[uninstall.sh](../runtime/uninstall.sh)、[AppUninstaller](../App/AppUninstaller.swift) |

Swift側の対応テストは [Tests/App/](../Tests/App/)、CLI・PKG・生成設定のテストは [Tests/Scripts/](../Tests/Scripts/) にあります。

## 電源制御と権限

開始・停止の条件は[製品仕様](SPEC.md)で定義します。CLIは15秒間隔で時間・残量・電源状態を監視し、開始・時間の更新・停止・復旧・ランタイム更新・アンインストールを排他制御します。自動解除に失敗した場合も同じ間隔で再試行し、ログイン時は前回異常終了した自分のセッションだけを復旧します。

通常操作でパスワードなしに実行できる管理者コマンドは次の2つだけです。

```text
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

この許可はアプリ専用ではなく、設定したユーザーのプロセス全体に適用されます。同じユーザーは上記2コマンドを直接実行できます。画面ロック・時間・残量の安全装置はアプリの通常操作に対するもので、同一ユーザーの悪意あるプロセスを隔離する境界ではありません。

アプリからは常にアプリ本体に同梱したCLIを実行します。ユーザー領域のCLIはログイン時の復旧・診断用です。アプリの子プロセスは必要な環境変数だけを受け取り、ランタイム・監視プロセス・インストーラーは `zsh -f` でユーザーのシェル初期化ファイルを読み込みません。root管理の `/etc/zshenv` と署名済みアプリ本体は信頼対象です。

## 権限と保存データの詳細

インストール時の管理者認証は、アプリの配置と上記の電源制御権限の設定に使います。アクセシビリティの許可は画面ロックのキー操作を送るために必要で、インストーラーからは自動付与しません。画面ロックにオートメーション許可は使わず、通常の利用でターミナルの設定は不要です。

スリープ防止の状態と復旧用ログは `~/Library/Application Support/LidAwake/` に保存します。利用者設定の保存方式は[製品設定の変更](#製品設定の変更)を参照してください。アンインストールではログとセッション情報を削除し、UserDefaultsの利用者設定と競合防止用の空の `operation.lock` は残します。

同じ保存先の `uninstall-state` は削除画面の進行状況です。削除開始前に `cleaning`、ランタイムとログイン項目の解除後に `readyForFinder` を保存します。読めない・不正な内容は途中の状態として扱います。再起動時は設定画面を開き、開始と自動起動の再登録を抑止します。このファイル自体に常駐処理はなく、PKGのユーザー側セットアップが最後まで成功した時だけ削除します。同じバージョンの再インストールでも通常利用へ戻れます。

## インストールと実行環境

アプリは同梱CLIとインストール済みCLIの一致・実行権限、電源制御権限、復旧用LaunchAgentの設定内容・登録状態を確認し、不備があれば開始を中止してPKGによる修復を案内します。確認できなかった項目は診断情報として表示し、開始・停止などの操作エラーとは分けて保持します。

復旧用LaunchAgentの `AssociatedBundleIdentifiers` は製品設定のBundle IDから生成し、システム設定がアプリ本体の名前とアイコンを参照できるようにします。関連付けの欠落・不一致もアプリのインストール診断で検出します。

セットアップすると、アプリ内部で使用するCLIが `~/.local/bin/lid-awake` に入ります。通常の利用ではターミナル操作やPATH設定は不要です。

root権限ではアプリ本体の配置、署名確認、専用sudoers設定の配置を行います。ユーザーのホームへの配置・復旧登録はそのユーザー権限で `setup-runtime.sh` を実行します。ログインユーザーの切り替え、署名不一致、設定失敗時は成功扱いにしません。インストール完了後の設定画面起動失敗だけは警告扱いにします。工程コードは [ERRORS.md](ERRORS.md#終了コード) を参照してください。

初期設定と修復はPKGだけが行います。`setup-runtime.sh` は権限の存在を確認し、同じユーザーのセッションを停止してからCLIと復旧用LaunchAgentを更新します。アプリは権限設定を作成しません。停止失敗でアプリを終了できない場合は、[復旧手順](TROUBLESHOOTING.md#スリープ防止を解除できない場合)を実行してからインストーラーを開き直してください。

起動中のアプリはDistributionの[`must-close`](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html)にBundle IDを指定し、Installer標準の終了確認を表示します。強制終了はしません。スクリプト側の起動チェックは、確認後の再起動やCLIインストールに対する安全策として残しています。展開済みPKGのDistributionも`zsh -f Tests/Scripts/test-pkg.zsh <Distributionのパス>`で検証できます。

`uninstall.sh` とCLIの `recover` は、生成時に設定されたアプリのインストール先へ認証を依頼します。アプリ内からは実行中のアプリのパスを渡します。

PKGが配置するアプリ本体はroot所有のままとし、設定削除後は `NSWorkspace.activateFileViewerSelecting` で本体をFinderに表示してアプリを終了します。アプリ自身によるゴミ箱移動処理はありません。電源権限の削除に使う管理者認証を、ファイル操作に引き継げるとは扱いません。処理途中の状態と失敗の扱いは [ERRORS.md](ERRORS.md) を参照してください。

開始キーの登録先はこのアプリ内に一本化しています。macOSの「アプリケーションショートカット」で開始操作を追加するためのメニュー項目は設けていません。

ショートカットの編集はキーを離して記録を終了した後に `GlobalHotKey.setKey` で確定します。編集中・画面ロック要求中・削除中の停止は理由ごとに保持し、すべて解除されるまで再登録しません。停止中のキー変更は拒否し、競合確認のための一時登録もしません。設定の変更に失敗した場合は元の割り当てを復元します。

初回起動時に、macOSの[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)でアプリの自動起動を登録します。これはCLIの復旧用LaunchAgentとは別の登録です。通常起動では設定画面を開き、ログイン時は背景で起動します。設定画面を閉じてもショートカットを受け付け、Dockとメニューバーにアイコンは表示しません。実装は [AppDelegate](../App/LidAwakeApp.swift) を参照してください。

## 開発・テスト

テストの入口は [scripts/test.sh](../scripts/test.sh) です。個人のユーザー名・ホームパス・機種・証明書には依存しません。必要な環境は次のとおりです。

| 対象 | 必要な環境 |
| --- | --- |
| `shell` | macOS標準コマンド・zshとPython 3。アプリのインストール、署名証明書、アクセシビリティ許可は不要 |
| `swift` | 製品設定の対応OS・CPUを満たすMac、対応SDKを含むXcode、XcodeGen、Python 3。AppKitの画面テストにはログイン済みのGUIセッションが必要 |
| `all`（省略時） | 上記両方 |

Swiftテストはアドホック署名でビルドします。配布用Team IDは設定の入力値として使うだけで、その署名者の秘密鍵や公証用キーチェーンは不要です。Intel Mac・Linux・Windowsでの全テスト実行は対象にしていません。

テスト対象は `App/` のSwiftソースを共有し、プロセスの入口 `AppEntry.swift` だけを除外します。テスト用Info.plistは本体と分離し、`AppDelegate` とアンインストールのOS操作にテスト用の依存を渡します。アンインストールはモデルの実際の入口からFinder表示要求・終了判定まで検証します。Finderでの表示・本体削除や設定画面のボタン操作は、実機で別途確認します。

テストの担当範囲を分け、同じ検証を別ファイルへ重ねないようにします。`HotKeyRecordingTests` は入力記録、`GlobalHotKeyTests` は登録・停止、`HotKeySettingTests` は画面との接続を担当します。`RuntimeClientTests` は呼び出し契約、`RuntimeSecurityTests` は無害な子プロセスの実行・隔離を確認します。インストール済みファイルの準備は `TestRuntimeFiles` を使い、実行用ランナーは必ず模擬実装を渡します。入力範囲はSwiftとCLIでそれぞれ境界値を実行し、ソースの比較式の書き方には依存させません。

```sh
./scripts/test.sh
./scripts/test.sh shell
./scripts/test.sh swift
```

Xcodeは `DEVELOPER_DIR`、未指定なら `xcode-select` の選択先を使います。Command Line Toolsだけが選択されている場合は、使用するXcodeの `Contents/Developer` を `DEVELOPER_DIR` に指定してください。テストスクリプトはシステムの選択先を変更しません。どのフォルダからでもスクリプトのパスを指定して実行できます。

テストは一時ディレクトリと模擬コマンドを使い、実際の電源設定を変更しません。利用者のHOMEや保存設定を上書きせず、ショートカットの登録・衝突もテスト内の登録処理で模擬します。個別のシェルテストを実行する場合も `/bin/zsh -f Tests/Scripts/test-名前.zsh` とし、ユーザーのシェル初期化設定を読み込ませないでください。OS管理の `/etc/zshenv` はzsh共通の実行環境として残ります。

これは自動テストの移植性の条件であり、別機種で蓋閉じ中の動作を確認したことにはなりません。実際のキー登録、蓋閉じ・音声・通信・ログイン時の動作は実機で別途確認します。配布用ビルド・署名・公証は [SIGNING.md](SIGNING.md) を参照してください。

## OS依存の動作

アプリはロック解除通知に加え、約1秒間隔で画面ロック状態を確認します。`CGSessionCopyCurrentDictionary`自体は公開APIですが、`CGSSessionScreenIsLocked`キーと `com.apple.screenIsUnlocked` 通知名は公開仕様ではありません。

`disablesleep` は現在のmacOSに実装されていますが、`pmset` の公開マニュアルには記載されていません。OS更新後には実機検証が必要です。

蓋閉じ時の消灯は、Awakeのロック中セッションと `SleepDisabled` が有効な場合だけ、`AppleClamshellState` を約1秒間隔で確認して実行します。`IODisplayWrangler` に `IORequestIdle` を送る方式で、外部ディスプレイも対象です。要求の成功と、実機での消灯完了は別に検証します。

画面ロック状態と電源状態の確認失敗は別に扱います。判断は [ERRORS.md](ERRORS.md#状態の区別)、診断・手動復旧は [TROUBLESHOOTING.md](TROUBLESHOOTING.md) を参照してください。
