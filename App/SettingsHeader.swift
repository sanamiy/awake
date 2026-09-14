import SwiftUI
import AppKit

struct SettingsHeader: View {
    let icon: NSImage

    var body: some View {
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
    }
}
