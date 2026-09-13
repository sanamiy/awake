import ServiceManagement
import AppKit
import Carbon

enum LoginStartup {
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Register once per launch only when absent; never fight macOS approval.
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
            return "ログイン時の自動起動には、システム設定のログイン項目で\(AppIdentity.name)を許可してください。"
        case .notRegistered:
            return previousIssue ?? "ログイン時の自動起動が登録されていません。\(AppIdentity.name)を終了して開き直してください。"
        case .notFound:
            return previousIssue ?? "ログイン時の自動起動の登録を確認できません。\(AppIdentity.name)を終了して開き直してください。"
        @unknown default:
            return "ログイン時の自動起動の状態を確認できません。システム設定のログイン項目を確認してください。"
        }
    }
}
