import Foundation

struct TestApplicationBundle {
    let root: URL
    let app: URL

    init(identifier: String = AppIdentity.bundleIdentifier) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LidAwakeUninstall-\(UUID().uuidString)")
        app = root.appendingPathComponent("\(AppIdentity.name).app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/\(AppIdentity.name)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "CFBundleExecutable": AppIdentity.name]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("test fixture only".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
