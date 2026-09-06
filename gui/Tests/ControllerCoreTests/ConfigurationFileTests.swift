import XCTest
@testable import ControllerCore

final class ConfigurationFileTests: XCTestCase {
    func testMergePreservesCommentsAndUneditedValuesAndRemovesDuplicateEditedKeys() throws {
        let text = "# personal settings\nFPS=30\nOTHER=latest\nFPS=12\n\n"
        let output = try ConfigurationFile.merging(changes: ["FPS": "60", "BITRATE": "25"], into: text)
        XCTAssertEqual(output, "# personal settings\nFPS=60\nOTHER=latest\nBITRATE=25\n")
    }

    func testRejectsMultilineValue() {
        XCTAssertThrowsError(try ConfigurationFile.merging(changes: ["ALLOW_IP": "::1\nBIND=0.0.0.0:3390"], into: ""))
    }

    func testRealFileMergeUsesLatestContents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.env")
        try "FPS=30\nEXTRA_FLAGS=--stretch\n".write(to: url, atomically: true, encoding: .utf8)
        try ConfigurationFile.save(changes: ["FPS": "60", "ALLOW_IP": "::1"], to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "FPS=60\nEXTRA_FLAGS=--stretch\nALLOW_IP=::1\n")
    }

    func testReadFailureIsReportedInsteadOfReplacingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try ConfigurationFile.save(changes: ["FPS": "60"], to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
