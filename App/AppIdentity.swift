import Foundation

/// Values are expanded from Product.xcconfig into each target's Info.plist.
enum AppIdentity {
    private final class BundleToken: NSObject {}
    private static let bundle = Bundle(for: BundleToken.self)
    static let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? ProcessInfo.processInfo.processName
    static let bundleIdentifier = bundle.object(forInfoDictionaryKey: "AppProductBundleIdentifier") as? String
        ?? bundle.bundleIdentifier ?? ""
}
