import XCTest

final class LocalizationTests: XCTestCase {
    private func languageBundle(_ language: String) throws -> Bundle {
        let url = try XCTUnwrap(L10n.bundle.url(forResource: language, withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }

    private func catalog(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(try languageBundle(language).url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testBothCatalogsHaveMatchingKeysAndPlaceholders() throws {
        let japanese = try catalog("ja")
        let english = try catalog("en")
        XCTAssertFalse(japanese.isEmpty)
        XCTAssertEqual(Set(japanese.keys), Set(english.keys))
        for (key, value) in japanese {
            let translated = try XCTUnwrap(english[key])
            XCTAssertFalse(translated.isEmpty, key)
            XCTAssertEqual(value.components(separatedBy: "%@").count,
                           translated.components(separatedBy: "%@").count, key)
            XCTAssertNil(translated.range(of: "[ぁ-んァ-ヶ一-龠]", options: .regularExpression), key)
        }
    }

    func testBundleLanguageSelectionAndEnglishFallback() {
        let languages = L10n.bundle.localizations
        XCTAssertEqual(L10n.bundle.developmentLocalization, "en")
        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(languages.contains("ja"))
        for (preferences, expected) in [(["en-US", "ja"], "en"), (["ja-JP", "en"], "ja"), (["fr", "en"], "en")] {
            XCTAssertEqual(Bundle.preferredLocalizations(from: languages, forPreferences: preferences).first, expected)
        }
    }

    func testLocalizedLookupAndFormatting() throws {
        let english = try languageBundle("en")
        let japanese = try languageBundle("ja")
        XCTAssertEqual(L10n.text("キャンセル", bundle: english), "Cancel")
        XCTAssertEqual(L10n.text("キャンセル", bundle: japanese), "キャンセル")
        XCTAssertEqual(L10n.text("%@をアンインストールしますか？", "Awake", bundle: english), "Uninstall Awake?")
        XCTAssertEqual(L10n.text("%@をアンインストールしますか？", "Awake", bundle: japanese), "Awakeをアンインストールしますか？")
        XCTAssertEqual(L10n.text("終了値: %@\n%@", "80", "50% remaining", bundle: english), "Exit code: 80\n50% remaining")
        XCTAssertTrue(L10n.text("時間は1〜1440分、バッテリー下限は5〜95%です。", bundle: english).contains("95%"))
    }

    func testEveryLocalizedCallHasACatalogEntry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("App"), includingPropertiesForKeys: nil)
        let keys = Set(try catalog("ja").keys)
        let pattern = #"L10n\.text\("((?:[^"\\]|\\.)*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file)
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                let raw = (source as NSString).substring(with: match.range(at: 1))
                let key = raw.replacingOccurrences(of: "\\n", with: "\n")
                XCTAssertTrue(keys.contains(key), "Missing key in \(file.lastPathComponent): \(key)")
            }
        }
    }
}
