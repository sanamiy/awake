import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                header
                preferences
                noticeArea
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 380)
        .confirmationDialog(L10n.text("%@をアンインストールしますか？", AppIdentity.name), isPresented: $model.isUninstallConfirmationPresented, titleVisibility: .visible) {
            Button(L10n.text("アンインストール"), role: .destructive) { Task { await model.uninstall() } }
            Button(L10n.text("キャンセル"), role: .cancel) { }
                .accessibilityIdentifier("cancel-uninstall")
        } message: {
            Text(L10n.text("電源制御の設定とログイン時の自動起動を解除します。必要に応じて管理者認証を求めます。Finderでアプリをゴミ箱へ移してください。"))
        }
    }

    private var header: some View {
        SettingsHeader(icon: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
    }

    private var preferences: some View {
        // These rows own their labels and columns; nesting them in a macOS Form clips the controls.
        VStack(alignment: .leading, spacing: 14) {
            HotKeySetting(key: model.preferences.hotKey, onSave: model.setHotKey,
                          onEditingChange: model.setEditingHotKey)
                .frame(minHeight: 52, alignment: .top)
            DurationSetting(minutes: $model.preferences.minutes)
                .frame(minHeight: 52, alignment: .top)
            BatterySetting(value: $model.preferences.minimumBattery)
                .frame(minHeight: 52, alignment: .top)
                .help(L10n.text("バッテリー駆動中に適用します。電源接続中は下限以下でも継続します。"))
        }
        .disabled(model.isBusy || model.isUninstallPending)
    }

    @ViewBuilder
    private var messages: some View {
        if model.isReadyForFinder {
            Text(L10n.text("設定の削除が完了しました。Finderで%@をゴミ箱へ移してください。", AppIdentity.name))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("Finderで表示して終了")) { Task { await model.revealInFinderAndQuit() } }
                .disabled(model.isBusy)
        } else if model.isUninstallPending {
            Text(L10n.text("アンインストールは未完了です。残りの削除処理を再試行してください。"))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        if model.needsRecovery {
            Text(L10n.text("停止できませんでした。停止を再試行してから終了してください。必要に応じて管理者認証を求めます。"))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("停止を再試行")) { Task { await model.retryStop() } }
                .disabled(model.isBusy)
        }
        if let failure = model.visibleFailure {
            Text(failure.displayMessage).font(.callout)
                .foregroundStyle(failure.isInformational ? Color.secondary : Color.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let failure = model.installationFailure {
            Text(failure.localizedDescription)
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.needsAccessibilityPermission && !model.isUninstallPending { screenLockSettings }
        if let issue = model.loginItemIssue {
            Text(issue).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("ログイン項目の設定を開く")) { model.openLoginItemSettings() }
        }
    }

    private var noticeArea: some View {
        // Reserve one stable slot, even when empty. Long diagnostics remain scrollable
        // instead of moving the settings or hiding recovery/permission actions.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                messages
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 100)
        .accessibilityIdentifier("settings-notices")
    }

    private var screenLockSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("画面ロックの許可")).font(.headline)
            Text(L10n.text("初回はアクセシビリティで%@を許可してください。許可後に開始ショートカットをもう一度押してください。", AppIdentity.name))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("アクセシビリティ設定を開く")) {
                model.openAccessibilitySettings()
            }
            .accessibilityIdentifier("open-accessibility-settings")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BatterySetting: View {
    @Binding var value: Int

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(L10n.text("バッテリー下限"))
                .fixedSize().frame(height: 28)
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                       in: Double(Preferences.batteryRange.lowerBound)...Double(Preferences.batteryRange.upperBound), step: 5)
                    .frame(height: 28)
                    .accessibilityLabel(L10n.text("バッテリー下限"))
                    .accessibilityValue("\(value)%")
                HStack {
                    Text("\(Preferences.batteryRange.lowerBound)%")
                    Spacer()
                    Text("\(value)%").monospacedDigit().foregroundStyle(.primary)
                    Spacer()
                    Text("\(Preferences.batteryRange.upperBound)%")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 220)
        }
    }
}
