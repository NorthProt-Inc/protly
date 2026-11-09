import Foundation
import XCTest

/// The test vectors the extension's tests read too (tests/fixtures at the repo root), so both parsers answer the same
/// cases. Read through #filePath, guarded as KeyboardSourceRulesTests reads the keyboard sources: a copy of the
/// package outside ios-app/ has no repo next to it and skips; inside ios-app a missing fixture fails.
enum SharedFixtures {
    static func cases(_ name: String, file: StaticString = #filePath) throws -> [[String: Any]] {
        let iosApp = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = iosApp.deletingLastPathComponent().appendingPathComponent("tests/fixtures/\(name)")
        guard let data = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: iosApp.appendingPathComponent("Package.swift").path) {
                XCTFail("tests/fixtures/\(name) not found")
                return []
            }
            throw XCTSkip("tests/fixtures/\(name) not found next to ios-app")
        }
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty, name)
        return cases
    }
}
