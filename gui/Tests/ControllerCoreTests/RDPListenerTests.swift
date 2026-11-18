import XCTest
@testable import ControllerCore

final class RDPListenerTests: XCTestCase {
    func testOnlyTheRequestedProcessListeningOnTheConfiguredPortCounts() {
        let output = """
        p14
        f4
        n*:3390
        p18
        f5
        n[::1]:4400
        f6
        n127.0.0.1:3390->127.0.0.1:51432
        """
        XCTAssertTrue(RDPListener.isOwned(by: 14, port: 3390, in: output))
        XCTAssertTrue(RDPListener.isOwned(by: 18, port: 4400, in: output))
        XCTAssertFalse(RDPListener.isOwned(by: 18, port: 3390, in: output))
        XCTAssertFalse(RDPListener.isOwned(by: 14, port: 4400, in: output))
    }

    func testConfiguredPortSupportsIPv4AndIPv6AndRejectsInvalidValues() {
        XCTAssertEqual(RDPListener.port(fromBind: "0.0.0.0:3390"), 3390)
        XCTAssertEqual(RDPListener.port(fromBind: "[::1]:4400"), 4400)
        for bind in ["", "3390", "127.0.0.1:0", "[::1]:65536", "127.0.0.1:nope"] {
            XCTAssertNil(RDPListener.port(fromBind: bind))
        }
    }
}
