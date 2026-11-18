import Foundation
import Security

/// Keep the existing headless reader (/usr/bin/security) trusted while storing
/// password bytes through Security.framework, never through process arguments.
public enum PasswordKeychain {
    public static func save(
        account: String,
        password: String,
        add: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) },
        update: (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }
    ) -> OSStatus {
        var trusted: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath("/usr/bin/security", &trusted)
        guard status == errSecSuccess, let trusted else { return status }
        var writer: SecTrustedApplication?
        status = SecTrustedApplicationCreateFromPath(nil, &writer)
        guard status == errSecSuccess, let writer else { return status }
        var access: SecAccess?
        status = SecAccessCreate("macrdp account password" as CFString, [writer, trusted] as CFArray, &access)
        guard status == errSecSuccess, let access else { return status }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "macrdp",
            kSecAttrAccount as String: account
        ]
        var bytes = Data(password.utf8)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let changes: [String: Any] = [
            kSecValueData as String: bytes,
            kSecAttrAccess as String: access
        ]
        let attributes = query.merging(changes) { _, value in value }
        status = add(attributes as CFDictionary)
        if status == errSecDuplicateItem {
            // Update in place so a failure cannot delete the working credential.
            // Preserve the existing ACL. Replacing it on every password edit
            // requires additional user authorization and can break headless reads.
            status = update(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        }
        return status
    }
}
