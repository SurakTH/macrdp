#!/bin/bash

# Shared launcher helper. Build only when the release binary is missing or
# older than Rust/native sources or Cargo configuration. This keeps the simple
# `./start.sh` workflow while avoiding a cargo invocation on every launch.
ensure_macrdp_release() {
  local project_dir="$1"
  local binary="$project_dir/target/release/macrdp"
  local rebuild=0
  local reason=""

  if [[ "${MACRDP_SKIP_AUTO_BUILD:-0}" == "1" ]]; then
    if [[ ! -x "$binary" ]]; then
      echo "macrdp: release binary is missing and MACRDP_SKIP_AUTO_BUILD=1" >&2
      return 1
    fi
    return 0
  fi

  if [[ ! -x "$binary" ]]; then
    rebuild=1
    reason="release binary is missing"
  else
    local manifest
    for manifest in \
      "$project_dir/Cargo.toml" \
      "$project_dir/Cargo.lock" \
      "$project_dir/build.rs" \
      "$project_dir/rust-toolchain.toml"; do
      if [[ -e "$manifest" && "$manifest" -nt "$binary" ]]; then
        rebuild=1
        reason="$(basename "$manifest") changed"
        break
      fi
    done

    if (( ! rebuild )); then
      local source
      while IFS= read -r -d '' source; do
        if [[ "$source" -nt "$binary" ]]; then
          rebuild=1
          reason="source code changed"
          break
        fi
      done < <(
        find "$project_dir/src" "$project_dir/vendor" \
          -type f \( -name '*.rs' -o -name '*.m' -o -name '*.c' -o -name '*.h' \) \
          -print0
      )
    fi
  fi

  if (( rebuild )); then
    if ! command -v cargo >/dev/null 2>&1; then
      echo "macrdp: Rust/Cargo is required to rebuild ($reason)" >&2
      return 1
    fi
    echo "macrdp: $reason; building optimized release..."
    (cd "$project_dir" && cargo build --release)
    if command -v codesign >/dev/null 2>&1; then
      # Normalize Cargo's linker signature so macOS TCC permissions remain
      # associated with a stable executable identity across rebuilds.
      codesign -s - --force "$binary"
    fi
  fi

  if [[ ! -x "$binary" ]]; then
    echo "macrdp: build completed but $binary was not created" >&2
    return 1
  fi
}
