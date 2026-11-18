import Foundation
import OpenDirectory
import Security

public enum AccountPassword {
    public enum Verification {
        case valid, invalid, unavailable
    }

    public enum SaveResult: Equatable {
        case saved, invalid, verificationUnavailable, keychainFailure
    }

    /// Verify through the local account service without spawning a process or
    /// sending the password through command-line arguments.
    public static func verify(account: String, password: String) -> Verification {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: account, attributes: nil)
            try record.verifyPassword(password)
            return .valid
        } catch let error as NSError where error.domain == ODFrameworkErrorDomain
            && error.code == Int(kODErrorCredentialsInvalid.rawValue) {
            return .invalid
        } catch {
            return .unavailable
        }
    }

    public static func verifyAndSave(
        account: String,
        password: String,
        verify: (String, String) -> Verification = { AccountPassword.verify(account: $0, password: $1) },
        save: (String, String) -> OSStatus = { PasswordKeychain.save(account: $0, password: $1) }
    ) -> SaveResult {
        guard !password.isEmpty else { return .invalid }
        switch verify(account, password) {
        case .invalid: return .invalid
        case .unavailable: return .verificationUnavailable
        case .valid:
            return save(account, password) == errSecSuccess ? .saved : .keychainFailure
        }
    }
}
