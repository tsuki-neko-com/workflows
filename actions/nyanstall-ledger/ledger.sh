#!/usr/bin/env bash
set -euo pipefail

error() { printf '::error::%s\n' "$1" >&2; exit 1; }
require_path() {
  local value="$1" name="$2"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || error "Invalid or missing $name"
}
command=${LEDGER_COMMAND:-}
product=${LEDGER_PRODUCT:-}
app=${LEDGER_APP:-}
version=${LEDGER_VERSION:-}
channel=${LEDGER_CHANNEL:-}
pr=${LEDGER_PR_NUMBER:-}
base=${LEDGER_INGEST_URL:-https://ingest.nyanstall.tsuki-neko.com}
base=${base%/}
dry=${LEDGER_DRY_RUN:-false}
case "$dry" in true|false) ;; *) error 'Invalid dry-run';; esac
case "$command" in
  next-beta|create-version|get-version|update-target|last-success|ios-build-number|pr-betas) require_path "$product" product; prefix="/v1/ingest/products/$product";;
  record-ios-release) require_path "$app" app;;
  *) error 'Invalid or missing command';;
esac
body_required=false
case "$command" in
  next-beta) method=POST; path="$prefix/beta-numbers"; body_required=true;;
  create-version) method=POST; path="$prefix/versions"; body_required=true;;
  get-version) require_path "$version" version; method=GET; path="$prefix/versions/$version";;
  update-target) require_path "$version" version; require_path "$app" app; method=PATCH; path="$prefix/versions/$version/targets/$app"; body_required=true;;
  last-success) require_path "$app" app; require_path "$channel" channel; method=GET; path="$prefix/last-success?app=$app&channel=$channel";;
  ios-build-number) method=POST; path="$prefix/ios-build-numbers"; body_required=true;;
  pr-betas) require_path "$pr" pr-number; method=GET; path="$prefix/prs/$pr";;
  record-ios-release) method=POST; path="/v1/ingest/$app/releases"; body_required=true;;
esac
body=null
if [ "$body_required" = true ]; then
  [ -n "${LEDGER_BODY:-}" ] || error 'Missing body'
  body=$(printf '%s' "$LEDGER_BODY" | jq -c .) || error 'Invalid JSON body'
fi
url="$base$path"
if [ "$dry" = true ]; then
  response=$(jq -cn --arg method "$method" --arg url "$url" --argjson body "$body" '{method:$method,url:$url,body:$body}')
  printf 'status=dry-run\nresponse=%s\n' "$response" >> "$GITHUB_OUTPUT"
  exit 0
fi
[ -n "${LEDGER_ACCESS_CLIENT_ID:-}" ] || error 'Missing access-client-id'
[ -n "${LEDGER_ACCESS_CLIENT_SECRET:-}" ] || error 'Missing access-client-secret'
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'CF-Access-Client-Id: %s\nCF-Access-Client-Secret: %s\nContent-Type: application/json\n' "$LEDGER_ACCESS_CLIENT_ID" "$LEDGER_ACCESS_CLIENT_SECRET" > "$tmp/headers"
if [ "$body_required" = true ]; then
  printf '%s' "$body" > "$tmp/body"
  status=$(curl -sS -X "$method" -H "@$tmp/headers" --data-binary "@$tmp/body" --output "$tmp/response" --write-out '%{http_code}' "$url") || error 'Request failed'
else
  status=$(curl -sS -X "$method" -H "@$tmp/headers" --output "$tmp/response" --write-out '%{http_code}' "$url") || error 'Request failed'
fi
response=$(jq -c . "$tmp/response") || error 'Invalid JSON response'
printf 'status=%s\nresponse=%s\n' "$status" "$response" >> "$GITHUB_OUTPUT"
case "$status" in 2??) ;; 404) [ "$command" = get-version ] || error "HTTP $status";; *) error "HTTP $status";; esac
