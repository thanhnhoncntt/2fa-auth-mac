import XCTest

/// Every L("…") key in the sources has a Vietnamese translation, and every translation keeps the same placeholders.
final class LocalizationTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testEveryStringHasAVietnameseTranslationWithTheSamePlaceholders() throws {
        let strings = root.appendingPathComponent("Resources/vi.lproj/Localizable.strings")
        let vi = try XCTUnwrap(NSDictionary(contentsOf: strings) as? [String: String], "vi strings file parses")
        let sources = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"L\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        XCTAssertGreaterThan(keys.count, 80)
        let placeholders = { (s: String) in s.matches(of: #/%(ld|@|d)/#).map { String($0.output.0) } }
        for key in keys {
            guard let translation = vi[key] else { XCTFail("missing Vietnamese for: \(key)"); continue }
            XCTAssertEqual(placeholders(key), placeholders(translation), key)
        }
    }
}
