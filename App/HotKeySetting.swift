import SwiftUI

struct HotKeySetting: View {
    let key: HotKey?
    let onSave: (HotKey?) throws -> Void
    let onEditingChange: (Bool) -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HotKeyRecorder(title: key?.label ?? "クリックして設定", onSelect: save,
                               onRecordingChange: { recording in
                    if recording { error = nil }
                    onEditingChange(recording)
                })
                .frame(width: 130, height: 28)
                .accessibilityLabel("開始ショートカットを設定")
                .accessibilityValue(key?.label ?? "未設定")
                .accessibilityIdentifier("edit-hotkey")
                .help("クリックしてキーを入力し、離すと登録します。Escまたは欄外クリックでキャンセルします。")
                Button { save(nil) } label: {
                    Image(systemName: "xmark")
                }
                .disabled(key == nil)
                .accessibilityLabel("ショートカットの割り当てを解除")
                .accessibilityIdentifier("clear-hotkey")
                .help("割り当てを解除")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save(_ key: HotKey?) {
        do { try onSave(key); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
