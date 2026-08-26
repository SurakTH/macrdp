#!/bin/bash

# Read-only launcher preflight. This never builds, signs, starts, stops, or
# changes macOS permissions; it only reports whether the next ./start.sh run
# has the prerequisites it needs.

set -u

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$PROJECT_DIR/target/release/macrdp"
ERRORS=0
WARNINGS=0
NEEDS_BUILD=0

ok() {
  printf '[OK]   %s\n' "$*"
}

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf '[WARN] %s\n' "$*"
}

fail() {
  ERRORS=$((ERRORS + 1))
  printf '[FAIL] %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage: ./start.sh doctor

Runs read-only checks for macOS, build tools, the optimized binary, code
signing, launcher permissions, the default RDP port, disk space, and LAN IP.
It does not build or start macrdp.
EOF
}

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

printf 'macrdp doctor (read-only)\n'
printf 'Project: %s\n\n' "$PROJECT_DIR"

if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" ]]; then
  fail "macrdp server requires macOS; detected $(uname -s 2>/dev/null || printf unknown)"
else
  macos_version="$(sw_vers -productVersion 2>/dev/null || printf unknown)"
  ok "macOS $macos_version ($(uname -m 2>/dev/null || printf unknown))"
fi

launcher_errors=0
for launcher in \
  start.sh \
  start-ultimate.sh \
  start-lan.sh \
  start-native.sh \
  start-fast.sh \
  start-avc444.sh; do
  if [[ ! -x "$PROJECT_DIR/$launcher" ]]; then
    launcher_errors=$((launcher_errors + 1))
    fail "$launcher is not executable (run: chmod +x $launcher)"
  fi
done
if (( launcher_errors == 0 )); then
  ok "launcher files are executable"
fi

release_reason=""
if [[ ! -x "$BINARY" ]]; then
  NEEDS_BUILD=1
  release_reason="optimized binary is missing"
else
  for manifest in \
    "$PROJECT_DIR/Cargo.toml" \
    "$PROJECT_DIR/Cargo.lock" \
    "$PROJECT_DIR/build.rs" \
    "$PROJECT_DIR/rust-toolchain.toml"; do
    if [[ -e "$manifest" && "$manifest" -nt "$BINARY" ]]; then
      NEEDS_BUILD=1
      release_reason="$(basename "$manifest") is newer than the binary"
      break
    fi
  done

  if (( ! NEEDS_BUILD )); then
    while IFS= read -r -d '' source; do
      if [[ "$source" -nt "$BINARY" ]]; then
        NEEDS_BUILD=1
        release_reason="source code is newer than the binary"
        break
      fi
    done < <(
      find "$PROJECT_DIR/src" "$PROJECT_DIR/vendor" \
        -type f \( -name '*.rs' -o -name '*.m' -o -name '*.c' -o -name '*.h' \) \
        -print0
    )
  fi
fi

if (( NEEDS_BUILD )); then
  warn "$release_reason; ./start.sh will build it automatically"
else
  ok "optimized binary is current"
fi

if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
  ok "$(cargo --version 2>/dev/null)"
  ok "$(rustc --version 2>/dev/null)"
elif (( NEEDS_BUILD )); then
  fail "Rust/Cargo is required for the automatic release build"
  info "Install it from https://rustup.rs and open a new Terminal"
else
  warn "Rust/Cargo is unavailable; the current binary can run but cannot rebuild"
fi

xcode_ready=0
if command -v xcode-select >/dev/null 2>&1 \
  && xcode-select -p >/dev/null 2>&1 \
  && command -v xcrun >/dev/null 2>&1 \
  && xcrun --find swiftc >/dev/null 2>&1 \
  && xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  xcode_ready=1
  ok "Xcode command-line build tools and macOS SDK are available"
fi
if (( ! xcode_ready )); then
  if (( NEEDS_BUILD )); then
    fail "Xcode command-line build tools or the macOS SDK are unavailable"
  else
    warn "Xcode build tools are unavailable; the current binary cannot rebuild"
  fi
  info "Install/select Xcode, or run: xcode-select --install"
fi

if [[ -x "$BINARY" ]]; then
  if command -v codesign >/dev/null 2>&1; then
    if codesign --verify --strict "$BINARY" >/dev/null 2>&1; then
      ok "release binary has a valid macOS code signature"
    else
      warn "release binary signature is missing or invalid"
      info "Rebuild with ./start.sh, or run: codesign -s - --force target/release/macrdp"
    fi
  else
    warn "codesign is unavailable; signature could not be verified"
  fi
fi

if command -v lsof >/dev/null 2>&1; then
  listener="$(lsof -nP -iTCP:3390 -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 { print $1 " (PID " $2 ")" }')"
  if [[ -n "$listener" ]]; then
    warn "default port 3390 is already listening: $listener"
    info "This is normal if macrdp is already running; otherwise stop that process or use --bind with another port"
  else
    ok "default RDP port 3390 is available"
  fi
else
  warn "lsof is unavailable; port 3390 could not be checked"
fi

available_kb="$(df -Pk "$PROJECT_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')"
if [[ "$available_kb" =~ ^[0-9]+$ ]]; then
  if (( available_kb < 5242880 )); then
    warn "less than 5 GiB is free; a clean Rust release build may need more space"
  else
    available_gb=$((available_kb / 1024 / 1024))
    ok "approximately ${available_gb} GiB of disk space is available"
  fi
fi

default_interface="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }')"
lan_ip=""
if [[ -n "$default_interface" ]] && command -v ipconfig >/dev/null 2>&1; then
  lan_ip="$(ipconfig getifaddr "$default_interface" 2>/dev/null || true)"
fi
if [[ -z "$lan_ip" ]] && command -v ifconfig >/dev/null 2>&1; then
  # `route`/`ipconfig` can be restricted by a sandbox even though interface
  # addresses remain readable. Prefer the first active, non-loopback IPv4.
  lan_ip="$(ifconfig 2>/dev/null | awk '
    /^[a-z0-9]+:/ { interface=$1; sub(":", "", interface) }
    /inet / && $2 !~ /^127\./ && interface != "bridge100" { print $2; exit }
  ')"
fi
if [[ -n "$lan_ip" ]]; then
  ok "LAN address: $lan_ip (connect to $lan_ip:3390)"
else
  warn "no active IPv4 LAN address was detected"
fi

info "Screen Recording and Accessibility are checked by macrdp at launch."
info "macOS does not provide a reliable read-only shell query for another binary's TCC grants."
info "If prompted, enable macrdp in System Settings > Privacy & Security, then restart it."

printf '\nRecommended commands:\n'
printf '  ./start.sh          best overall balance\n'
printf '  ./start.sh lan      maximum practical quality on a clean LAN\n'
printf '  ./start.sh native   sharpest text/UI at a stable 12 FPS\n'

printf '\nSummary: %d failure(s), %d warning(s)\n' "$ERRORS" "$WARNINGS"
if (( ERRORS > 0 )); then
  exit 1
fi

exit 0
