import XCTest
@testable import ControllerCore

final class CredentialStatusTests: XCTestCase {
    func testSharedLogOnlyReportsCurrentProcessAndLatestTransition() {
        let waiting = "WARN Waiting for a valid Keychain password credential_process=32 credential_status=\"waiting\" reason=Rejected"
        let foreign = "INFO credential_process=320 credential_status=recovered"
        let recovered = "INFO credential_process=32 credential_status=\"recovered\""
        XCTAssertEqual(CredentialStatus.latest(for: 32, in: [waiting, foreign]), .waiting)
        XCTAssertEqual(CredentialStatus.latest(for: 32, in: [waiting, recovered, foreign]), .recovered)
        XCTAssertNil(CredentialStatus.latest(for: 12, in: [waiting, recovered, foreign]))
        XCTAssertNil(CredentialStatus.latest(for: 32, in: [foreign, "WARN Waiting for a valid Keychain password"]))
    }
}
