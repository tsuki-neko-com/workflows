#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v actionlint >/dev/null 2>&1; then
  echo 'actionlint is required. Install it and shellcheck with: brew install actionlint shellcheck' >&2
  exit 1
fi

actionlint -color

shopt -s nullglob
for test_script in actions/*/test.sh; do
  bash "$test_script"
done

for script in scripts/*.sh; do
  bash -n "$script"
done

while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find actions -type f -name '*.sh' -print0)
