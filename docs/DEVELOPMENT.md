# 開発者向けガイド

利用方法は[README](../README.md)、期待する動作は[製品仕様](SPEC.md)、配布版のビルド・署名・公証は[SIGNING.md](SIGNING.md)、エラーの設計は[ERRORS.md](ERRORS.md)を参照してください。以下のコマンドはリポジトリのルートで実行します。

## 製品設定の変更

[config/Product.xcconfig](../config/Product.xcconfig)が、アプリ名・Bundle ID・インストーラーID・対応OS・CPU・署名者・公証プロファイルの共通設定です。表示名はアプリのInfo.plistから `AppIdentity` を通じてUIへ反映します。プロジェクト・モジュール名、CLI名、保存先の内部識別子は別の用途なので表示名から派生させません。

Xcodeは共通設定を直接参照します。[scripts/configure.py](../scripts/configure.py)は、同じ値からPKGのXML・案内・署名要件と、単体実行できる同梱CLIを生成します。Python 3は開発・ビルド時だけ必要で、利用者のMacでは使いません。

`runtime/bin/lid-awake` は製品名を埋め込む前のソースです。そのまま実行せず、ビルドしたアプリに同梱されたCLIか、インストール済みのCLIを使ってください。生成物の直接編集は不要です。対応CPUの設定変更だけで、そのCPUでの動作を保証するものではありません。

設定の既定値・入力範囲は [Preferences.swift](../App/Preferences.swift)、バージョンとビルド番号は [App/Info.plist](../App/Info.plist) にあります。設定は一つのCodableデータとしてUserDefaultsに保存し、欠落・デコード失敗・範囲外なら既定値を使います。旧形式の移行処理はありません。

開始時にはアプリが時間・残量をCLIへ渡し、CLIに既定値は持たせません。両境界の入力検証と範囲の一致は維持します。CLIの `_start`・`_monitor`・`_recover` は内部操作で、利用者向けの呼び出し口ではありません。

時間の保存値・CLI引数は1〜1440分、0は明示的な無制限です。無制限のdeadlineは0として時間判定だけを省略し、監視プロセスは維持します。設定画面は15・30・60・120・240・480・1440分・無制限の段階式スライダーで選択します。既存の任意の分数は変更せず表示し、スライダー位置だけ最も近い有限の段階に合わせます。

## 実装の入口

`App/` はアプリ本体、`runtime/` はアプリに同梱する処理、`installer/` はPKGの処理と素材、`scripts/` は開発用ツールです。テストは `Tests/App/` と `Tests/Scripts/` に分けています。

| 変更対象 | 主な実装 |
| --- | --- |
| 設定画面・ショートカット入力 | [ContentView](../App/ContentView.swift)、[SettingsHeader](../App/SettingsHeader.swift)、[HotKeySetting](../App/HotKeySetting.swift)、[HotKeyRecorder](../App/HotKeyRecorder.swift) |
| 操作の状態管理・監視 | [AppModel](../App/AppModel.swift)、[ScreenLockSession](../App/ScreenLockSession.swift)、[LidDisplaySleep](../App/LidDisplaySleep.swift) |
| 起動・終了・キー登録 | [AppEntry](../App/AppEntry.swift)、[AppLaunch](../App/AppLaunch.swift)、[AppDelegate](../App/AppDelegate.swift)、[LoginStartup](../App/LoginStartup.swift)、[GlobalHotKey](../App/GlobalHotKey.swift) |
| アプリとCLIの境界 | [RuntimeClient](../App/RuntimeClient.swift)、[CommandRunner](../App/CommandRunner.swift)、[AppFailure](../App/AppFailure.swift) |
| 電源制御・復旧 | [runtime/bin/lid-awake](../runtime/bin/lid-awake)、[AdministrativeAuthorization](../App/AdministrativeAuthorization.swift) |
| インストール・削除 | [installer](../installer)、[setup-runtime.sh](../runtime/setup-runtime.sh)、[uninstall.sh](../runtime/uninstall.sh)、[UninstallSystemActions](../App/UninstallSystemActions.swift)、[UninstallProgress](../App/UninstallProgress.swift) |

Swift側の対応テストは [Tests/App/](../Tests/App/)、CLI・PKG・生成設定のテストは [Tests/Scripts/](../Tests/Scripts/) にあります。

## アプリの多言語対応

表示文言は `App/ja.lproj/Localizable.strings` と `App/en.lproj/Localizable.strings` にまとめ、SwiftUI・AppKit・アプリのエラー案内で `L10n.text` を使います。日本語の原文をキーにし、差し込みには `%@` と文字列引数を使います。`Awake Mode`、ショートカットのキー表記、エラーコードなどの識別子は翻訳しません。

言語の選択はFoundationのBundleに任せます。macOSの優先言語とアプリ別の言語指定に従い、開発言語の英語をフォールバックにします。独自の言語設定は保存しません。変更後はアプリの再起動が必要です。内部CLI・インストーラーの診断出力やOS由来のエラーは原文のまま保持します。READMEとPKGの案内文は、このアプリUIの翻訳とは別です。

文言を追加・変更する際は両言語のキーと引数を合わせて更新します。`LocalizationTests` が同梱リソース、キーの網羅、差し込み、言語選択を検証します。日本語に固定された表示テストは作らず、各言語でテストを実行してください。

```sh
xcodebuild -project LidAwake.xcodeproj -scheme LidAwake -destination 'platform=macOS' -derivedDataPath .build-tests -testLanguage en -testRegion US test
xcodebuild -project LidAwake.xcodeproj -scheme LidAwake -destination 'platform=macOS' -derivedDataPath .build-tests -testLanguage ja -testRegion JP test
```

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

同じ保存先の `uninstall-state` は削除画面の進行状況です。削除開始前に `cleaning`、ランタイムとログイン項目の解除後に `readyForFinder` を保存します。読めない・不正な内容は途中の状態として扱います。再起動後も開始と自動起動の再登録を抑止し、利用者がアプリを開いたときに削除画面を表示します。このファイル自体に常駐処理はなく、PKGのユーザー側セットアップが最後まで成功した時だけ削除します。同じバージョンの再インストールでも通常利用へ戻れます。

## インストールと実行環境

アプリは同梱CLIとインストール済みCLIの一致・実行権限、電源制御権限、復旧用LaunchAgentの設定内容・登録状態を確認し、不備があれば開始を中止してPKGによる修復を案内します。確認できなかった項目は診断情報として表示し、開始・停止などの操作エラーとは分けて保持します。

復旧用LaunchAgentは `~/.local/bin/AwakeRecovery` を起動します。これは `Recovery/main.c` から作る署名付きの小さな実行ファイルで、隣の `lid-awake` を `zsh -f -- … _recover` で実行するだけです。復旧の判断を複製せず、アプリ本体を移動・削除しても復旧用の2ファイルは独立して残ります。アプリへの同梱先は `Contents/Helpers/AwakeRecovery` です。セットアップで両方を配置し、アンインストールで両方を削除します。インストール診断では両方の内容・実行権限とplistの一致を確認します。

`AssociatedBundleIdentifiers` は製品設定のBundle IDから生成します。[Appleの仕様](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)では、従来形式のLaunchAgentをアプリ本体の名前・アイコンに関連付けるため、登録された実行ファイルとアプリ本体の署名Team IDが一致する必要があります。署名のないシェルスクリプトを直接登録しても、この関連付けは成立しません。配布ビルドでは復旧用実行ファイルも本体と同じDeveloper IDで署名します。

セットアップすると、アプリ内部で使用するCLIが `~/.local/bin/lid-awake` に入ります。通常の利用ではターミナル操作やPATH設定は不要です。

root権限ではアプリ本体の配置、署名確認、専用sudoers設定の配置を行います。ユーザーのホームへの配置・復旧登録はそのユーザー権限で `setup-runtime.sh` を実行します。ログインユーザーの切り替え、署名不一致、設定失敗時は成功扱いにしません。インストール完了後の設定画面起動失敗だけは警告扱いにします。工程コードは [ERRORS.md](ERRORS.md#終了コード) を参照してください。

初期設定と修復はPKGだけが行います。`setup-runtime.sh` は権限の存在を確認し、同じユーザーのセッションを停止してからCLIと復旧用LaunchAgentを更新します。アプリは権限設定を作成しません。停止失敗でアプリを終了できない場合は、[復旧手順](TROUBLESHOOTING.md#スリープ防止を解除できない場合)を実行してからインストーラーを開き直してください。

起動中のアプリはDistributionの[`must-close`](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html)にBundle IDを指定し、Installer標準の終了確認を表示します。強制終了はしません。スクリプト側の起動チェックは、確認後の再起動やCLIインストールに対する安全策として残しています。展開済みPKGのDistributionも`zsh -f Tests/Scripts/test-pkg.zsh <Distributionのパス>`で検証できます。

`uninstall.sh` とCLIの `recover` は、生成時に設定されたアプリのインストール先へ認証を依頼します。アプリ内からは実行中のアプリのパスを渡します。

PKGが配置するアプリ本体はroot所有のままとし、設定削除後は `NSWorkspace.activateFileViewerSelecting` で本体をFinderに表示してアプリを終了します。アプリ自身によるゴミ箱移動処理はありません。電源権限の削除に使う管理者認証を、ファイル操作に引き継げるとは扱いません。処理途中の状態と失敗の扱いは [ERRORS.md](ERRORS.md) を参照してください。

アプリの「Awake Modeに入る」メニューと開始ショートカットは、同じ `AppModel.perform(.start)` を呼びます。メニューには独自のキー割り当てを付けず、グローバルキー登録は引き続きアプリ内の設定で管理します。メニューの開始操作は処理中・アンインストール中には無効にします。

ショートカットの編集はキーを離して記録を終了した後に `GlobalHotKey.setKey` で確定します。編集中・画面ロック要求中・削除中の停止は理由ごとに保持し、すべて解除されるまで再登録しません。停止中のキー変更は拒否し、競合確認のための一時登録もしません。設定の変更に失敗した場合は元の割り当てを復元します。

## ログイン時の起動

[SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp) でAwake本体をログイン項目に登録します。「ログイン時に開く」はプロセスの自動起動を設定するもので、設定画面の表示指定ではありません。起動専用ヘルパーや同梱LaunchAgent、バックグラウンド起動用の独自引数は使いません。復旧用の `AwakeRecovery` は電源復旧のために残します。

`AppEntry` がモデルを作成し、`applicationWillFinishLaunching` でキー登録と画面ロック監視を開始します。同じタイミングでopen/reopenイベントのハンドラーを登録します。[Appleの案内](https://developer.apple.com/documentation/appkit/nsapplication)に従い、最初のイベントが届く前にハンドラーを用意します。`applicationDidFinishLaunching` はログイン項目の登録確認だけを行い、設定画面を開きません。

`AppLaunch` は起動引数と画面表示の判定、`LoginStartup` はログイン項目の登録方針と状態案内を担当します。画面の表示は実際に届いた `kAEOpenApplication`・`kAEReopenApplication` で判断します。`keyAEPropData` があるログイン・サービス起動イベントは非表示にし、未知の起動情報も保守的に非表示とします。起動情報が付いていない通常のopen/reopenと設定メニューだけが設定画面を開きます。`currentAppleEvent == nil` を手動起動とは解釈せず、起動完了後に届くイベントにも同じ判定を適用します。

設定画面は遅延生成し、AppKitの未命名ウインドウ生成とウインドウ復元を抑止します。`LSUIElement` と `.accessory` によってログイン時と画面を閉じた後はDockにアイコンを出しません。手動で設定画面を開いた間だけ `.regular` に切り替えます。エラーで設定画面を自動表示せず、必要な復旧は非表示のまま再試行します。

ログイン項目が未登録・登録確認不能の場合は一度だけ登録を試し、有効・承認待ちなら再登録しません。アンインストール中は登録しません。終了時には再起動を要求せず、独自の多重起動制御・常駐監視プロセスも設けません。自動起動の承認・無効化はmacOSのログイン項目設定に従います。

通常終了はAppKitの [`terminateLater`](https://developer.apple.com/documentation/appkit/nsapplication/terminatereply/terminatelater) で停止結果を待ちます。この間は専用のmodal run loopになるため、MainActorのTaskで停止を予約するだけでは進行しない場合があります。`prepareToTerminate` はランタイムの停止を独立したTaskで実行し、`RunLoop.main.perform(inModes:)` で終了待ちにも結果を届けます。状態管理は引き続きMainActor上で行います。最初に終了をキャンセルして後で再要求する方式は使いません。停止失敗や別操作の実行中には、ログアウト・再起動の要求も取り消される場合があります。

自動起動はOSの起動順序・完了時刻を保証しません。本体のプロセスとイベントループが動く前、ログイン前、アプリ終了後のキー入力は受け付けません。承認待ち・登録競合・ショートカット未設定でも使用できません。実ログインでの非表示・キー受付は、模擬イベントのテストとは別に確認します。

起動診断は製品Bundle IDのUnified Logging、category `startup` に記録します。キー割り当ての有無・登録成否・初期化完了・openイベントに対する表示判断だけを残し、キー内容・入力文字列・イベント全体は記録しません。

## 開発・テスト

テストの入口は [scripts/test.sh](../scripts/test.sh) です。個人のユーザー名・ホームパス・機種・証明書には依存しません。必要な環境は次のとおりです。

| 対象 | 必要な環境 |
| --- | --- |
| `shell` | macOS標準コマンド・zshとPython 3、復旧用実行ファイルのテストにXcodeまたはCommand Line ToolsのCコンパイラ。アプリのインストール、署名証明書、アクセシビリティ許可は不要 |
| `swift` | 製品設定の対応OS・CPUを満たすMac、対応SDKを含むXcode、XcodeGen、Python 3。AppKitの画面テストにはログイン済みのGUIセッションが必要 |
| `all`（省略時） | 上記両方 |

Swiftテストはアドホック署名でビルドします。配布用Team IDは設定の入力値として使うだけで、その署名者の秘密鍵や公証用キーチェーンは不要です。Intel Mac・Linux・Windowsでの全テスト実行は対象にしていません。

テスト対象は `App/` のSwiftソースを共有し、プロセスの入口 `AppEntry.swift` だけを除外します。テスト用Info.plistは本体と分離し、`AppDelegate` とアンインストールのOS操作にテスト用の依存を渡します。アンインストールはモデルの実際の入口からFinder表示要求・終了判定まで検証します。Finderでの表示・本体削除や設定画面のボタン操作は、実機で別途確認します。

テストの担当範囲を分け、同じ検証を別ファイルへ重ねないようにします。`HotKeyRecordingTests` は入力記録、`GlobalHotKeyTests` は登録・停止、`HotKeySettingTests` は画面との接続を担当します。`AppDelegateTests` は起動イベント・ウインドウ・終了、`AppModelTests` は操作の状態遷移、`SettingsViewTests` と `SettingsHeaderTests` は表示・配置を担当します。共通の準備はテストメソッドを持たない `AppModelTestCase` と `HotKeySettingTestCase` を使い、検証を継承で重複実行しません。`RuntimeClientTests` は呼び出し契約、`RuntimeSecurityTests` は無害な子プロセスの実行・隔離を確認します。インストール済みファイルの準備は `TestRuntimeFiles` を使い、実行用ランナーは必ず模擬実装を渡します。入力範囲はSwiftとCLIでそれぞれ境界値を実行し、ソースの比較式の書き方には依存させません。

```sh
./scripts/test.sh
./scripts/test.sh shell
./scripts/test.sh swift
```

Xcodeは `DEVELOPER_DIR`、未指定なら `xcode-select` の選択先を使います。Command Line Toolsだけが選択されている場合は、使用するXcodeの `Contents/Developer` を `DEVELOPER_DIR` に指定してください。テストスクリプトはシステムの選択先を変更しません。どのフォルダからでもスクリプトのパスを指定して実行できます。

テストは一時ディレクトリと模擬コマンドを使い、実際の電源設定を変更しません。利用者のHOMEや保存設定を上書きせず、ショートカットの登録・衝突もテスト内の登録処理で模擬します。個別のシェルテストを実行する場合も `/bin/zsh -f Tests/Scripts/test-名前.zsh` とし、ユーザーのシェル初期化設定を読み込ませないでください。OS管理の `/etc/zshenv` はzsh共通の実行環境として残ります。

`swift` / `all` はXCTest後に `Tests/Integration/test-termination.zsh` も実行します。本体のソースと模擬ランタイムから独立した検証プロセスを作り、実際の `NSApplication.run()` / `terminate()` を通して終了成功と、停止失敗後の終了取り消し・再試行を確認します。実行ループの停止はプロセス内のタイムアウトで失敗として検出します。ログアウトや再起動自体を行うテストではありません。

これは自動テストの移植性の条件であり、別機種で蓋閉じ中の動作を確認したことにはなりません。実際のキー登録、蓋閉じ・音声・通信・ログイン時の動作は実機で別途確認します。配布用ビルド・署名・公証は [SIGNING.md](SIGNING.md) を参照してください。

## OS依存の動作

アプリはロック解除通知に加え、約1秒間隔で画面ロック状態を確認します。`CGSessionCopyCurrentDictionary`自体は公開APIですが、`CGSSessionScreenIsLocked`キーと `com.apple.screenIsUnlocked` 通知名は公開仕様ではありません。

`disablesleep` は現在のmacOSに実装されていますが、`pmset` の公開マニュアルには記載されていません。OS更新後には実機検証が必要です。

蓋閉じ時の消灯は、Awakeのロック中セッションと `SleepDisabled` が有効な場合だけ、`AppleClamshellState` を約1秒間隔で確認して実行します。`IODisplayWrangler` に `IORequestIdle` を送る方式で、外部ディスプレイも対象です。要求の成功と、実機での消灯完了は別に検証します。

画面ロック状態と電源状態の確認失敗は別に扱います。判断は [ERRORS.md](ERRORS.md#状態の区別)、診断・手動復旧は [TROUBLESHOOTING.md](TROUBLESHOOTING.md) を参照してください。
