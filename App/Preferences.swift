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

    var minutes = 120
    var minimumBattery = 30
    var hotKey: HotKey? = .standard

    static func load(from defaults: UserDefaults) -> Preferences {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Preferences.self, from: data),
              minutesRange.contains(value.minutes), batteryRange.contains(value.minimumBattery) else { return Preferences() }
        return value
    }

    func save(to defaults: UserDefaults) {
        guard Self.minutesRange.contains(minutes), Self.batteryRange.contains(minimumBattery),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func startArguments() throws -> [String] {
        guard Self.minutesRange.contains(minutes), Self.batteryRange.contains(minimumBattery) else {
            throw AppFailure(code: .invalidInput, detail: L10n.text("時間は1〜1440分、バッテリー下限は5〜95%です。"))
        }
        // Locking is handled by the native app after the runtime has finished.
        return ["_start", "--minutes", String(minutes), "--min-battery", String(minimumBattery)]
    }
}
