#!/bin/bash

# Fast public-repository guard: catch accidentally tracked local artifacts,
# credentials, machine-specific Markdown paths, and broken tracked symlinks.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

FAILURES=0

report_failure() {
  FAILURES=$((FAILURES + 1))
  printf 'repo hygiene: %s\n' "$*" >&2
}

while IFS= read -r path; do
  case "$path" in
    .env.example|*/.env.example)
      ;;
    .env|*/.env|.env.*|*/.env.*|config.env|*/config.env|*.pem|*.key|*.crt|*.cer|*.p12|*.pfx|*.log|*.log.*|target/*|*/target/*|.DS_Store|*/.DS_Store)
      report_failure "forbidden local/generated file is tracked: $path"
      ;;
  esac
done < <(git ls-files)

for ignored_path in \
  target/release/macrdp \
  vendor/example/target/debug/example \
  dev-certs/server.pem \
  packaging/config.env \
  .env \
  .env.local \
  session.log \
  dist/release.zip \
  artifacts/result.bin \
  out/result.bin; do
  if ! git check-ignore -q --no-index "$ignored_path"; then
    report_failure ".gitignore does not cover: $ignored_path"
  fi
done

for visible_example in packaging/config.env.example .env.example; do
  if git check-ignore -q --no-index "$visible_example"; then
    report_failure "example configuration would be ignored: $visible_example"
  fi
done

secret_files="$(git grep -Il -E -e '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}' -- . ':!scripts/check-repo-hygiene.sh' || true)"
if [[ -n "$secret_files" ]]; then
  report_failure "possible credential/private key found in tracked file(s):"
  printf '%s\n' "$secret_files" >&2
fi

local_path_files="$(git grep -Il -E 'file:///Users/|/Users/[^/<[:space:]]+/' -- '*.md' ':!scripts/check-repo-hygiene.sh' || true)"
if [[ -n "$local_path_files" ]]; then
  report_failure "machine-specific absolute path found in Markdown file(s):"
  printf '%s\n' "$local_path_files" >&2
fi

while IFS= read -r symlink; do
  if [[ ! -e "$symlink" ]]; then
    report_failure "tracked symlink is broken: $symlink -> $(readlink "$symlink" 2>/dev/null || true)"
  fi
done < <(git ls-files -s | awk '$1 == "120000" { print $4 }')

if (( FAILURES > 0 )); then
  printf 'repo hygiene: %d check(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'repo hygiene: all checks passed\n'
