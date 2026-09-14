import Foundation

struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    // Carbon commandKey + controlKey; ANSI W.
    static let standard = HotKey(keyCode: 13, modifiers: 256 + 4096, label: "⌃⌘W")
}

struct Preferences: Codable, Equatable {
    static let storageKey = "preferences"
    static let minutesRange = 1...1440
    static let batteryRange = 5...95

    static let defaultMinutes = 120
    // Zero disables only the time cutoff; battery and lock safeguards remain active.
    var minutes = defaultMinutes
    var unlimitedDuration: Bool {
        get { minutes == 0 }
        set { minutes = newValue ? 0 : Self.defaultMinutes }
    }
    var minimumBattery = 30
    var hotKey: HotKey? = .standard

    private var hasValidLimits: Bool {
        (unlimitedDuration || Self.minutesRange.contains(minutes)) && Self.batteryRange.contains(minimumBattery)
    }

    static func load(from defaults: UserDefaults) -> Preferences {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Preferences.self, from: data),
              value.hasValidLimits else { return Preferences() }
        return value
    }

    func save(to defaults: UserDefaults) {
        guard hasValidLimits,
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func startArguments() throws -> [String] {
        guard hasValidLimits else {
            throw AppFailure(code: .invalidInput, detail: L10n.text("時間は1〜1440分、バッテリー下限は5〜95%です。"))
        }
        // Locking is handled by the native app after the runtime has finished.
        return ["_start", "--minutes", String(minutes), "--min-battery", String(minimumBattery)]
    }
}
