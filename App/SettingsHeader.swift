import SwiftUI
import AppKit

struct SettingsHeader: View {
    let icon: NSImage
    let key: HotKey?
    let onSave: (HotKey?) throws -> Void
    let onEditingChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: icon)
                    .resizable().scaledToFit()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Awake Mode")
                        .font(.headline.weight(.regular))
                    Text(L10n.text("画面をロックし、蓋を閉じてもスリープを防止。ロック解除でAwake Modeも終了します。"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top) {
                Text(L10n.text("開始ショートカット"))
                    .padding(.top, 6)
                Spacer(minLength: 12)
                HotKeySetting(key: key, onSave: onSave, onEditingChange: onEditingChange)
                    .frame(width: 170, alignment: .trailing)
            }
        }
    }
}
