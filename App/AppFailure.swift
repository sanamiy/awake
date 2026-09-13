import Foundation

/// Stable identifiers, independent of localized wording and OS error messages.
enum FailureCode: String {
    case invalidInput = "LA1001", busy = "LA1002", installation = "LA2001"
    case runtimeUnavailable = "LA2002", powerRestore = "LA3001", powerUnknown = "LA3002"
    case authorizationCancelled = "LA3003", authorizationFailed = "LA3004"
    case foreignSession = "LA3005", batteryLow = "LA3006", powerStart = "LA3007"
    case runtimeRemoval = "LA4001", loginRemoval = "LA4002", uninstallPending = "LA4003", invalidTarget = "LA4004"
    case shortcut = "LA5001", screenLock = "LA5002", screenPermission = "LA5003", loginStartup = "LA5004", displaySleep = "LA5005", unexpected = "LA9000"

    var message: String {
        switch self {
        case .invalidInput: return "入力値を確認してください。"
        case .busy: return "別の操作が実行中です。完了してから再試行してください。"
        case .installation: return "インストール内容を確認できません。\(AppIdentity.name)を終了し、利用するユーザーでログインした状態で\(AppIdentity.name)のPKGインストーラーを再実行してください。停止に失敗して終了できない場合は、先に「停止を再試行」を実行してください。"
        case .runtimeUnavailable: return "内部CLIを実行できません。PKGによる修復が必要です。停止・終了もできない場合は、READMEの「解除できない場合」の手順を確認してください。"
        case .powerRestore: return "スリープ防止を解除できませんでした。停止を再試行してください。"
        case .powerUnknown: return "電源状態を確認できません。安全を確認できるまで終了しません。"
        case .authorizationCancelled: return "管理者認証をキャンセルしました。"
        case .authorizationFailed: return "管理者認証による操作に失敗しました。"
        case .foreignSession: return "\(AppIdentity.name)のセッションではないため、電源設定を変更しません。別のスリープ制御ツールで解除してから再試行してください。"
        case .batteryLow: return "バッテリー残量が設定した下限以下のため開始しません。"
        case .powerStart: return "スリープ防止を開始できませんでした。"
        case .runtimeRemoval: return "電源制御の設定を削除できませんでした。アンインストールを再試行してください。"
        case .loginRemoval: return "電源制御の設定は削除しましたが、ログイン時の起動を解除できませんでした。アンインストールを再試行してください。"
        case .uninstallPending: return "アンインストール中のため開始できません。画面の案内に従って削除を完了してください。"
        case .invalidTarget: return "アンインストール対象の\(AppIdentity.name)アプリを確認できませんでした。"
        case .shortcut: return "ショートカットを登録できませんでした。別のキーを選んでください。"
        case .screenLock: return "画面ロックを確認できませんでした。"
        case .screenPermission: return "画面ロックにはアクセシビリティの許可が必要です。システム設定で\(AppIdentity.name)を許可してください。"
        case .loginStartup: return "ログイン時の自動起動を登録できませんでした。\(AppIdentity.name)を終了して開き直してください。"
        case .displaySleep: return "蓋を閉じた後の画面消灯を要求できませんでした。"
        case .unexpected: return "処理に失敗しました。"
        }
    }

    /// Shared CLI exit-status contract; arbitrary process exits are NOT trusted codes.
    static func runtimeExit(_ status: Int32) -> Self {
        switch status {
        case 64: return .invalidInput
        case 73: return .busy
        case 78: return .installation
        case 80: return .powerRestore
        case 81: return .powerUnknown
        case 82: return .authorizationCancelled
        case 83: return .runtimeRemoval
        case 84: return .authorizationFailed
        case 85: return .foreignSession
        case 86: return .batteryLow
        case 87: return .powerStart
        case 126, 127: return .runtimeUnavailable
        default: return .unexpected
        }
    }
}

struct AppFailure: LocalizedError {
    let code: FailureCode
    var detail: String? = nil
    var suggestsPowerRecovery: Bool {
        [.powerRestore, .powerUnknown, .runtimeUnavailable].contains(code)
    }
    var errorDescription: String? {
        let message = "[\(code.rawValue)] \(code.message)"
        guard let detail, !detail.isEmpty else { return message }
        return "\(message)\n\(detail)"
    }
    static func normalize(_ error: Error, fallback: FailureCode = .unexpected) -> AppFailure {
        if let failure = error as? AppFailure { return failure }
        return AppFailure(code: fallback, detail: error.localizedDescription)
    }
}
