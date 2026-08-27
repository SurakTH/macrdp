import XCTest
@testable import ControllerCore

final class LaunchAgentSpecTests: XCTestCase {
    private let expectedBinary = "/Applications/macrdp.app/Contents/MacOS/macrdp"

    private var spec: LaunchAgentSpec {
        LaunchAgentSpec(
            label: "io.github.surakth.macrdp",
            serverBinaryPath: expectedBinary,
            configPath: "/Users/test/Library/Application Support/macrdp/config.env",
            stderrPath: "/Users/test/Library/Logs/macrdp.err.log"
        )
    }

    func testCurrentAgentMatches() {
        XCTAssertTrue(spec.matches(spec.propertyList) { $0 == self.expectedBinary })
    }

    func testMovedServerRequiresRepairEvenWhenOldBinaryStillExists() {
        var plist = spec.propertyList
        plist["ProgramArguments"] = [
            "/Users/test/Applications/macrdp.app/Contents/MacOS/macrdp",
            "--config",
            "/Users/test/Library/Application Support/macrdp/config.env",
        ]

        XCTAssertFalse(spec.matches(plist) { _ in true })
    }

    func testMissingExpectedBinaryRequiresRepair() {
        XCTAssertFalse(spec.matches(spec.propertyList) { _ in false })
    }

    func testChangedConfigPathRequiresRepair() {
        var plist = spec.propertyList
        plist["ProgramArguments"] = [expectedBinary, "--config", "/tmp/config.env"]

        XCTAssertFalse(spec.matches(plist) { _ in true })
    }

    func testProgramPathExtractsLegacyTargetForDiagnostics() {
        let old = "/Users/test/Applications/macrdp.app/Contents/MacOS/macrdp"
        var plist = spec.propertyList
        plist["ProgramArguments"] = [old, "--config", "/tmp/config.env"]

        XCTAssertEqual(LaunchAgentSpec.programPath(in: plist), old)
    }

    func testLoadedJobWithStaleCachedPathRequiresRepair() {
        let old = "/Users/test/Applications/macrdp.app/Contents/MacOS/macrdp"

        XCTAssertTrue(spec.requiresRepair(
            plist: spec.propertyList,
            loadedProgramPath: old,
            isLoaded: true,
            fileExists: { $0 == self.expectedBinary }
        ))
    }

    func testUnloadedCurrentAgentDoesNotRequireRepair() {
        XCTAssertFalse(spec.requiresRepair(
            plist: spec.propertyList,
            loadedProgramPath: nil,
            isLoaded: false,
            fileExists: { $0 == self.expectedBinary }
        ))
    }
}
