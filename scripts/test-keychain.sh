#!/bin/bash
# Integration test against a disposable keychain; never uses the login keychain.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macrdp-keychain-test.XXXXXX")"
trap 'rm -rf -- "$TASK_DIR"' EXIT
cat > "$TASK_DIR/main.swift" <<'SWIFT'
import Foundation
import Security
SecKeychainSetUserInteractionAllowed(false)
let path = ProcessInfo.processInfo.environment["MACRDP_KEYCHAIN_TEST_DIR"]! + "/test.keychain"
var keychain: SecKeychain?
let secret = "temporary-keychain-test"
let created = secret.withCString { password in
    SecKeychainCreate(path, UInt32(secret.utf8.count), password, false, nil, &keychain)
}
guard created == errSecSuccess, let keychain else {
    fputs("temporary keychain create failed: \(created)\n", stderr); exit(1)
}
defer { SecKeychainDelete(keychain) }
let add: (CFDictionary) -> OSStatus = { attributes in
    var values = attributes as! [String: Any]
    values[kSecUseKeychain as String] = keychain
    return SecItemAdd(values as CFDictionary, nil)
}
let update: (CFDictionary, CFDictionary) -> OSStatus = { query, changes in
    var values = query as! [String: Any]
    values[kSecMatchSearchList as String] = [keychain]
    return SecItemUpdate(values as CFDictionary, changes)
}
for password in ["initial-test-value", "updated-test-value"] {
    print("testing native write: \(password == "initial-test-value" ? "add" : "update")")
    let status = PasswordKeychain.save(account: "macrdp-isolated-test", password: password, add: add, update: update)
    guard status == errSecSuccess else { fputs("native keychain store failed: \(status)\n", stderr); SecKeychainDelete(keychain); exit(1) }
    let reader = Process()
    reader.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    reader.arguments = ["find-generic-password", "-s", "macrdp", "-a", "macrdp-isolated-test", "-w", path]
    let output = Pipe()
    reader.standardOutput = output
    try reader.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    reader.waitUntilExit()
    guard reader.terminationStatus == 0, String(data: bytes, encoding: .utf8) == password + "\n" else {
        fputs("headless reader verification failed\n", stderr); SecKeychainDelete(keychain); exit(1)
    }
}
print("isolated keychain add/update and /usr/bin/security reads passed")
SWIFT
swiftc "$PROJECT_DIR/gui/Sources/ControllerCore/PasswordKeychain.swift" "$TASK_DIR/main.swift" \
    -framework Security -o "$TASK_DIR/test-keychain"
MACRDP_KEYCHAIN_TEST_DIR="$TASK_DIR" "$TASK_DIR/test-keychain"
