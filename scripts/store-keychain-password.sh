#!/bin/bash
# Password arrives on stdin; argv contains only the account name.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macrdp-keychain.XXXXXX")"
trap 'rm -rf -- "$TASK_DIR"' EXIT
cat > "$TASK_DIR/main.swift" <<'SWIFT'
import Foundation
import Security
let input = FileHandle.standardInput.readDataToEndOfFile()
guard CommandLine.arguments.count == 2,
      let password = String(data: input, encoding: .utf8), !password.isEmpty else {
    exit(2)
}
let status = PasswordKeychain.save(account: CommandLine.arguments[1], password: password)
if status != errSecSuccess {
    fputs("Keychain write failed (status \(status))\n", stderr)
    exit(1)
}
SWIFT
swiftc "$PROJECT_DIR/gui/Sources/ControllerCore/PasswordKeychain.swift" "$TASK_DIR/main.swift" \
    -framework Security -o "$TASK_DIR/store-password"
"$TASK_DIR/store-password" "$1"
