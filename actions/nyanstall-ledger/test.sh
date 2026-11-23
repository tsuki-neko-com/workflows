#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_DIR/args"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H) case "$2" in @*) cat "${2#@}" >> "$FAKE_DIR/headers";; esac; shift 2;;
    --data-binary) cat "${2#@}" > "$FAKE_DIR/body"; shift 2;;
    --output) printf '%s' "$FAKE_BODY" > "$2"; shift 2;;
    --write-out) shift 2;;
    *) shift;;
  esac
done
printf '%s' "$FAKE_STATUS"
CURL
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp" FAKE_STATUS=200 FAKE_BODY='{"ok":true}'
export GITHUB_OUTPUT="$tmp/output" LEDGER_PRODUCT=prod LEDGER_APP=app LEDGER_VERSION=1.2.3 LEDGER_CHANNEL=beta LEDGER_PR_NUMBER=42 LEDGER_BODY='{"example":1}' LEDGER_ACCESS_CLIENT_ID=secretid123 LEDGER_ACCESS_CLIENT_SECRET=secretkey456 LEDGER_INGEST_URL=https://example.test LEDGER_DRY_RUN=false
run() { : > "$GITHUB_OUTPUT"; rm -f "$tmp/args" "$tmp/headers"; "$BASH" "$here/ledger.sh" > "$tmp/stdout" 2> "$tmp/stderr"; }
check() {
  export LEDGER_COMMAND="$1"
  run
  grep -Fx -- "$2" "$tmp/args" >/dev/null
  grep -Fx -- "https://example.test$3" "$tmp/args" >/dev/null
  grep -Fx 'status=200' "$GITHUB_OUTPUT" >/dev/null
  grep -Fx 'response={"ok":true}' "$GITHUB_OUTPUT" >/dev/null
  if [ "$2" != GET ]; then grep -Fx '{"example":1}' "$tmp/body" >/dev/null; fi
}
check next-beta POST /v1/ingest/products/prod/beta-numbers
check create-version POST /v1/ingest/products/prod/versions
check get-version GET /v1/ingest/products/prod/versions/1.2.3
check update-target PATCH /v1/ingest/products/prod/versions/1.2.3/targets/app
check last-success GET '/v1/ingest/products/prod/last-success?app=app&channel=beta'
check ios-build-number POST /v1/ingest/products/prod/ios-build-numbers
check pr-betas GET /v1/ingest/products/prod/prs/42
check record-ios-release POST /v1/ingest/app/releases
if grep -E 'secretid123|secretkey456' "$tmp/args" "$tmp/stdout" "$tmp/stderr"; then exit 1; fi
grep -F secretid123 "$tmp/headers" >/dev/null
grep -F secretkey456 "$tmp/headers" >/dev/null
export LEDGER_COMMAND=update-target LEDGER_APP=''
if run; then exit 1; fi
grep -F '::error::' "$tmp/stderr" >/dev/null
export LEDGER_APP=app LEDGER_BODY='{invalid'
if run; then exit 1; fi
test ! -e "$tmp/args"
export LEDGER_BODY='{}' FAKE_STATUS=500
if run; then exit 1; fi
grep -F '::error::' "$tmp/stderr" >/dev/null
export LEDGER_COMMAND=get-version FAKE_STATUS=404
run
grep -Fx 'status=404' "$GITHUB_OUTPUT" >/dev/null
export LEDGER_COMMAND=next-beta LEDGER_DRY_RUN=true
run
test ! -e "$tmp/args"
grep -Fx 'status=dry-run' "$GITHUB_OUTPUT" >/dev/null
sed -n 's/^response=//p' "$GITHUB_OUTPUT" | jq -e '.method == "POST" and .url == "https://example.test/v1/ingest/products/prod/beta-numbers" and .body == {}' >/dev/null
printf 'ledger tests passed\n'
