#!/bin/bash
# Exercise rebuild decisions and failures without compiling or signing a real app.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macrdp-release-test.XXXXXX")"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
source "$PROJECT_DIR/scripts/ensure-release.sh"

FIXTURE="$TEMP_DIR/project with spaces"
mkdir -p "$TEMP_DIR/bin" "$FIXTURE/src" "$FIXTURE/vendor/example" "$FIXTURE/target/release"
export CALL_LOG="$TEMP_DIR/calls"
export PATH="$TEMP_DIR/bin:$PATH"
export MACRDP_SKIP_AUTO_BUILD=0
export BUILD_FAIL=0 SIGN_FAIL=0

cat > "$TEMP_DIR/bin/cargo" <<'EOF'
#!/bin/bash
echo build >> "$CALL_LOG"
if [[ "$BUILD_FAIL" == 1 ]]; then exit 1; fi
touch target/release/macrdp
chmod +x target/release/macrdp
EOF
cat > "$TEMP_DIR/bin/codesign" <<'EOF'
#!/bin/bash
echo sign >> "$CALL_LOG"
if [[ "$SIGN_FAIL" == 1 ]]; then exit 1; fi
EOF
chmod +x "$TEMP_DIR/bin/cargo" "$TEMP_DIR/bin/codesign"

reset_fixture() {
  rm -f "$FIXTURE/vendor/example/Cargo.toml" "$FIXTURE/vendor/example/Cargo.lock"
  touch "$FIXTURE/src/main.rs" "$FIXTURE/Cargo.toml" "$FIXTURE/target/release/macrdp"
  chmod +x "$FIXTURE/target/release/macrdp"
  touch -t 202001010000 "$FIXTURE/src/main.rs" "$FIXTURE/Cargo.toml"
  touch -t 202101010000 "$FIXTURE/target/release/macrdp"
  : > "$CALL_LOG"
  BUILD_FAIL=0 SIGN_FAIL=0 MACRDP_SKIP_AUTO_BUILD=0
}

assert_calls() {
  local actual
  actual="$(cat "$CALL_LOG")"
  if [[ "$actual" != "$1" ]]; then
    printf 'expected calls %q, got %q\n' "$1" "$actual" >&2
    exit 1
  fi
}

reset_fixture
ensure_macrdp_release "$FIXTURE"
assert_calls ''

reset_fixture
rm "$FIXTURE/target/release/macrdp"
ensure_macrdp_release "$FIXTURE"
assert_calls $'build\nsign'

for changed in src/main.rs Cargo.toml vendor/example/Cargo.toml vendor/example/Cargo.lock; do
  reset_fixture
  touch -t 202201010000 "$FIXTURE/$changed"
  ensure_macrdp_release "$FIXTURE"
  assert_calls $'build\nsign'
done

# Calling from a conditional disables Bash errexit inside the helper. Failures
# must still propagate, even if an older executable remains on disk.
reset_fixture
touch -t 202201010000 "$FIXTURE/src/main.rs"
BUILD_FAIL=1
if ensure_macrdp_release "$FIXTURE"; then
  echo 'failed build was reported as successful' >&2
  exit 1
fi
assert_calls build

reset_fixture
touch -t 202201010000 "$FIXTURE/src/main.rs"
SIGN_FAIL=1
if ensure_macrdp_release "$FIXTURE"; then
  echo 'failed signing was reported as successful' >&2
  exit 1
fi
assert_calls $'build\nsign'

reset_fixture
MACRDP_SKIP_AUTO_BUILD=1
touch -t 202201010000 "$FIXTURE/src/main.rs"
ensure_macrdp_release "$FIXTURE"
assert_calls ''
rm "$FIXTURE/target/release/macrdp"
if ensure_macrdp_release "$FIXTURE"; then
  echo 'skip-build accepted a missing executable' >&2
  exit 1
fi
assert_calls ''

printf 'release helper: all checks passed\n'
