import XCTest
@testable import ControllerCore

final class RDPConnectionFileTests: XCTestCase {
    func testShortcutContainsOnlyAddressAndUsesWindowsTextEncoding() throws {
        for endpoint in ["192.168.137.2:3390", "[fd00::42]:4400"] {
            let file = try XCTUnwrap(RDPConnectionFile.data(for: endpoint))
            XCTAssertEqual(Array(file.prefix(2)), [0xff, 0xfe])
            XCTAssertEqual(String(data: file.dropFirst(2), encoding: .utf16LittleEndian),
                           "full address:s:\(endpoint)\r\n")
        }
    }

    func testUnusableOrMultilineEndpointIsNotExported() {
        for endpoint in ["—", "<Mac LAN IP>:3390", "127.0.0.2:3390", "0.0.0.0:3390",
                         "[::1]:3390", "[::]:3390", "[fe80::1]:3390", "[::ffff:127.0.0.1]:3390",
                         "192.168.1.4:0", "192.168.1.4:99999", "192.168.1.4:3390\r\nusername:s:bad"] {
            XCTAssertNil(RDPConnectionFile.data(for: endpoint), endpoint)
        }
    }
}
