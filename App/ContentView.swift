import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var confirmUninstall = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let failure = model.installationFailure {
                    Text(failure.localizedDescription)
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                preferences
                if model.isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("処理中")
                }
                messages
                if model.needsAccessibilityPermission && !model.isUninstallPending { screenLockSettings }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 380)
        .confirmationDialog("\(AppIdentity.name)をアンインストールしますか？", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("アンインストール", role: .destructive) { Task { await model.uninstall() } }
            Button("キャンセル", role: .cancel) { }
                .accessibilityIdentifier("cancel-uninstall")
        } message: {
            Text("自動起動・電源制御の設定を削除します。必要に応じて管理者認証を求めます。最後にFinderでアプリをゴミ箱へ移してください。")
        }
    }

    private var header: some View {
        SettingsHeader(icon: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage,
                       key: model.preferences.hotKey, onSave: model.setHotKey,
                       onEditingChange: model.setEditingHotKey)
            .disabled(model.isBusy || model.isUninstallPending)
    }

    private var preferences: some View {
        // These rows own their labels and columns; nesting them in a macOS Form clips the controls.
        VStack(alignment: .leading, spacing: 14) {
            NumericSettingRow(title: "スリープ防止の時間", unit: "分", value: $model.preferences.minutes,
                              range: Preferences.minutesRange, step: 15)
            NumericSettingRow(title: "バッテリー下限", unit: "%", value: $model.preferences.minimumBattery,
                              range: Preferences.batteryRange, step: 5)
                .help("バッテリー駆動中に適用します。電源接続中は下限以下でも継続します。")
        }
        .disabled(model.isBusy || model.isUninstallPending)
    }

    @ViewBuilder
    private var messages: some View {
        if model.isReadyForFinder {
            Text("設定の削除は完了しました。最後にFinderで\(AppIdentity.name)をゴミ箱へ移してください。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        } else if model.isUninstallPending {
            Text("アンインストールは未完了です。残りの削除処理を再試行してください。")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        if model.needsRecovery {
            Text("停止できませんでした。停止を再試行してから終了してください。必要に応じて管理者認証を求めます。")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("停止を再試行") { Task { await model.retryStop() } }
                .disabled(model.isBusy)
        }
        if let issue = model.loginItemIssue {
            Text(issue).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("ログイン項目の設定を開く") { model.openLoginItemSettings() }
        }
        if let failure = model.failure {
            Text(failure.localizedDescription).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        Button {
            if model.isReadyForFinder { Task { await model.revealInFinderAndQuit() } }
            else { confirmUninstall = true }
        } label: {
            Label(model.isReadyForFinder ? "Finderで表示して終了" :
                    (model.isUninstallPending ? "アンインストールを再試行" : "アンインストール"),
                  systemImage: model.isReadyForFinder ? "folder" : "trash")
        }
            .accessibilityIdentifier("uninstall")
            .font(.caption).disabled(model.isBusy)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var screenLockSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("画面ロックの許可").font(.headline)
            Text("初回はアクセシビリティで\(AppIdentity.name)を許可してください。許可後に開始ショートカットをもう一度押してください。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("アクセシビリティ設定を開く") {
                model.openAccessibilitySettings()
            }
            .accessibilityIdentifier("open-accessibility-settings")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct NumericSettingRow: View {
    let title: String
    let unit: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(unit, value: $value, format: .number.grouping(.never))
                .labelsHidden()
                .frame(width: 65).multilineTextAlignment(.trailing)
                .accessibilityLabel("\(title)（\(unit)）")
            Text(unit)
            Stepper(title, value: $value, in: range, step: step).labelsHidden().fixedSize()
        }
    }
}
