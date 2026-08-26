#!/bin/bash

# Test start.sh mode routing without building or launching macrdp. Every target
# launcher is replaced by a temporary stub that reports its own name + argv.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macrdp-launcher-test.XXXXXX")"

cleanup() {
  case "$TEMP_DIR" in
    */macrdp-launcher-test.*)
      rm -rf -- "$TEMP_DIR"
      ;;
  esac
}
trap cleanup EXIT

bash -n \
  "$PROJECT_DIR"/start*.sh \
  "$PROJECT_DIR/scripts/doctor.sh" \
  "$PROJECT_DIR/scripts/ensure-release.sh" \
  "$PROJECT_DIR/scripts/test-launchers.sh" \
  "$PROJECT_DIR/scripts/check-repo-hygiene.sh"

cp "$PROJECT_DIR/start.sh" "$TEMP_DIR/start.sh"
mkdir -p "$TEMP_DIR/scripts"

printf '%s\n' \
  '#!/bin/bash' \
  'printf "%s" "${0##*/}"' \
  'for arg in "$@"; do printf "|%s" "$arg"; done' \
  'printf "\n"' \
  > "$TEMP_DIR/stub-launcher.sh"
chmod +x "$TEMP_DIR/start.sh" "$TEMP_DIR/stub-launcher.sh"

for launcher in \
  start-ultimate.sh \
  start-lan.sh \
  start-native.sh \
  start-fast.sh \
  start-avc444.sh; do
  ln -s stub-launcher.sh "$TEMP_DIR/$launcher"
done
ln -s ../stub-launcher.sh "$TEMP_DIR/scripts/doctor.sh"

assert_route() {
  local expected="$1"
  shift
  local actual
  actual="$("$TEMP_DIR/start.sh" "$@")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'route mismatch: expected %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_route 'start-ultimate.sh'
assert_route 'start-ultimate.sh|--allow-ip|192.168.1.20' ultimate --allow-ip 192.168.1.20
assert_route 'start-ultimate.sh|--fps|30' quality --fps 30
assert_route 'start-lan.sh|--virtual-display' lan --virtual-display
assert_route 'start-lan.sh' max
assert_route 'start-native.sh|--width|2560' native --width 2560
assert_route 'start-fast.sh' fast
assert_route 'start-avc444.sh' avc444
assert_route 'doctor.sh' doctor
assert_route 'doctor.sh' diagnose
assert_route 'doctor.sh|--help' check --help
assert_route 'start-ultimate.sh|--allow-ip|192.168.1.20' --allow-ip 192.168.1.20

help_output="$("$TEMP_DIR/start.sh" --help)"
for mode in ultimate lan native fast avc444 doctor; do
  if [[ "$help_output" != *"$mode"* ]]; then
    printf 'help output is missing mode: %s\n' "$mode" >&2
    exit 1
  fi
done

printf 'launcher routing: all checks passed\n'
