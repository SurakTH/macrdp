import Security
import XCTest
@testable import ControllerCore

final class AccountPasswordTests: XCTestCase {
    func testInvalidOrUnavailablePasswordCannotReplaceSavedCredential() {
        for (verification, expected): (AccountPassword.Verification, AccountPassword.SaveResult) in [
            (.invalid, .invalid), (.unavailable, .verificationUnavailable)
        ] {
            XCTAssertEqual(AccountPassword.verifyAndSave(
                account: "test", password: "test only",
                verify: { _, _ in verification },
                save: { _, _ in XCTFail("Unverified password must not reach Keychain"); return errSecSuccess }
            ), expected)
        }
    }

    func testSuccessfulVerificationUsesNativeWriterAndReportsSaveFailure() {
        var steps = [String]()
        let result = AccountPassword.verifyAndSave(account: "test", password: "test only", verify: { account, password in
            XCTAssertEqual(account, "test")
            XCTAssertEqual(password, "test only")
            steps.append("verified")
            return .valid
        }, save: { account, password in
            XCTAssertEqual(account, "test")
            XCTAssertEqual(password, "test only")
            steps.append("save attempted")
            return errSecInteractionNotAllowed
        })
        XCTAssertEqual(steps, ["verified", "save attempted"])
        XCTAssertEqual(result, .keychainFailure)
    }
}
