import Foundation

/// One lookup path for SwiftUI, AppKit and errors. Bundle chooses the app's
/// preferred language; the development language is the fallback.
enum L10n {
    private final class ResourceBundleToken {}
    static let bundle = Bundle(for: ResourceBundleToken.self)

    static func text(_ key: String, _ arguments: String..., bundle: Bundle = bundle) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        // Static strings may contain a literal percent sign (battery limits).
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments)
    }
}
