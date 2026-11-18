import XCTest
import Security
@testable import ControllerCore

final class PasswordKeychainTests: XCTestCase {
    func testNativeWriteIncludesHeadlessReaderAccessAndPasswordData() {
        var called = false
        let status = PasswordKeychain.save(account: "test-account", password: "test-password", add: { attributes in
            let values = attributes as NSDictionary
            XCTAssertEqual(values[kSecAttrAccount] as? String, "test-account")
            XCTAssertEqual(values[kSecValueData] as? Data, Data("test-password".utf8))
            XCTAssertNotNil(values[kSecAttrAccess])
            called = true
            return errSecSuccess
        }, update: { _, _ in
            XCTFail("New item should not use update")
            return errSecInternalError
        })
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertTrue(called)
    }

    func testExistingCredentialUpdatesInPlaceAndPropagatesFailure() {
        var updated = false
        let status = PasswordKeychain.save(account: "test-account", password: "replacement", add: { _ in
            errSecDuplicateItem
        }, update: { query, changes in
            let query = query as NSDictionary
            let changes = changes as NSDictionary
            XCTAssertNil(query[kSecValueData])
            XCTAssertEqual(query[kSecAttrService] as? String, "macrdp")
            XCTAssertEqual(changes[kSecValueData] as? Data, Data("replacement".utf8))
            XCTAssertNil(changes[kSecAttrAccess], "Password update must preserve the existing reader ACL")
            updated = true
            return errSecAuthFailed
        })
        XCTAssertTrue(updated)
        XCTAssertEqual(status, errSecAuthFailed)
    }

    func testFailedAddDoesNotAttemptToReplaceAnExistingItem() {
        let status = PasswordKeychain.save(account: "test-account", password: "value", add: { _ in
            errSecInteractionNotAllowed
        }, update: { _, _ in
            XCTFail("Failed add must not delete or replace a credential")
            return errSecSuccess
        })
        XCTAssertEqual(status, errSecInteractionNotAllowed)
    }
}
