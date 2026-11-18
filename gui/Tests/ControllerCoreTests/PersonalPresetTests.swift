import XCTest
@testable import ControllerCore

final class PersonalPresetTests: XCTestCase {
    func testAtomicRoundTripExcludesNetworkAndSecretsAndRestrictsPermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PersonalPresetStore(url: folder.appendingPathComponent("presets.json"))
        let preset = PersonalPreset(name: "1440p · 10 ms", settings: [
            "CAPTURE_SIZE": "2560x1440", "FLUSH_INTERVAL_MS": "10",
            "BIND": "0.0.0.0:3390", "PASSWORD": "must-not-save", "EXTRA_FLAGS": "--bind 0.0.0.0:1"])
        try store.save([preset])
        XCTAssertEqual(try store.load(), [preset])
        XCTAssertNil(preset.settings["BIND"])
        XCTAssertNil(preset.settings["PASSWORD"])
        XCTAssertNil(preset.settings["EXTRA_FLAGS"])
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let original = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.save([preset, PersonalPreset(name: "1440P · 10 MS", settings: [:])]))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }

    func testInvalidAndFutureDocumentsAreNotAccepted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PersonalPresetStore(url: url)
        XCTAssertEqual(try store.load(), [])
        try Data("{\"version\":2,\"presets\":[]}".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
    }
}
