import AppKit

enum AdministrativeAuthorization {
    static func command(for action: String, username: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !username.isEmpty, username.unicodeScalars.allSatisfy(allowed.contains) else {
            throw AppFailure(code: .invalidInput, detail: "安全に扱えないユーザー名です。")
        }
        let target = "/etc/sudoers.d/lid-awake-\(username)"
        switch action {
        case "--authorize-restore":
            // Explicit emergency recovery only. Never grant permissions or enable sleep prevention.
            return "/usr/bin/pmset -a disablesleep 0"
        case "--authorize-remove":
            return "/bin/rm -f '\(target)'"
        default:
            throw AppFailure(code: .invalidInput, detail: "不明な認証操作です。")
        }
    }

    static func appleScript(for command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    @MainActor
    static func perform(_ action: String) throws {
        let command = try command(for: action, username: NSUserName())
        guard let script = NSAppleScript(source: appleScript(for: command)) else {
            throw AppFailure(code: .authorizationFailed)
        }
        var details: NSDictionary?
        script.executeAndReturnError(&details)
        if let details {
            if details[NSAppleScript.errorNumber] as? Int == -128 {
                throw AppFailure(code: .authorizationCancelled)
            }
            throw AppFailure(code: .authorizationFailed, detail: details[NSAppleScript.errorMessage] as? String)
        }
    }
}
