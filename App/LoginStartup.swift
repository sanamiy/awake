import ServiceManagement

enum LoginStartup {
    /// Register once when absent; leave approval decisions to macOS.
    static func registerIfNeeded(status: () -> SMAppService.Status, register: () throws -> Void) -> String? {
        do {
            switch status() {
            case .notRegistered, .notFound: try register()
            default: break
            }
            return issue(for: status())
        } catch {
            return AppFailure(code: .loginStartup, detail: error.localizedDescription).localizedDescription
        }
    }

    static func issue(for status: SMAppService.Status, previousIssue: String? = nil) -> String? {
        switch status {
        case .enabled: return nil
        case .requiresApproval:
            return L10n.text("ログイン時の自動起動には、システム設定のログイン項目で%@を許可してください。", AppIdentity.name)
        case .notRegistered:
            return previousIssue ?? L10n.text("ログイン時の自動起動が登録されていません。%@を終了して開き直してください。", AppIdentity.name)
        case .notFound:
            return previousIssue ?? L10n.text("ログイン時の自動起動の登録を確認できません。%@を終了して開き直してください。", AppIdentity.name)
        @unknown default:
            return L10n.text("ログイン時の自動起動の状態を確認できません。システム設定のログイン項目を確認してください。")
        }
    }
}
