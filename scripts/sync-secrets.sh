#!/usr/bin/env bash
set -euo pipefail

# Synchronize Cloudflare credentials to GitHub repository secrets.
# Credentials are read from ~/.config/tsuki-neko/cloudflare.env by default.
# Set TSUKI_NEKO_ENV_FILE to use a different credential file.
# Run with --dry-run to inspect targets without changing secrets.
# Use --help for all command-line options.

DEFAULT_ORG="tsuki-neko-com"
DEFAULT_ENV_FILE="${HOME}/.config/tsuki-neko/cloudflare.env"
CALLER_PATH=".github/workflows/ci.yml"
CALLER_MARKER="tsuki-neko-com/workflows/.github/workflows/workers.yml@"
SECRET_KEYS=(CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID)

DRY_RUN=0
FORCE=0
ORG="$DEFAULT_ORG"
REPOS=()
ENV_FILE="${TSUKI_NEKO_ENV_FILE:-$DEFAULT_ENV_FILE}"
declare -A SECRET_VALUES=()

log() {
  printf '%s\n' "$*"
}

err() {
  printf 'error: %s\n' "$*" >&2
}

die() {
  err "$@"
  exit 1
}

usage() {
  printf '%s\n' \
    'usage: sync-secrets.sh [--dry-run] [--force] [--org <org>] [--help] [repo ...]'
}

while (($# > 0)); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --org)
      if (($# < 2)) || [[ "$2" == -* ]]; then
        die "--org requires an organization name"
      fi
      ORG="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      REPOS+=("${1##*/}")
      shift
      ;;
  esac
done

if ((FORCE == 1 && ${#REPOS[@]} == 0)); then
  die "--force requires at least one repository name"
fi

load_env_file() {
  local mode line key value

  if [[ ! -f "$ENV_FILE" ]]; then
    err "credential file not found: ${ENV_FILE}"
    err 'expected format: CLOUDFLARE_API_TOKEN=... and CLOUDFLARE_ACCOUNT_ID=...'
    err "create the file, then run: chmod 600 ${ENV_FILE}"
    exit 1
  fi

  if ! mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null)"; then
    if ! mode="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null)"; then
      die "could not determine permissions for credential file ${ENV_FILE}"
    fi
  fi
  if [[ "$mode" != "600" ]]; then
    die "credential file ${ENV_FILE} has mode ${mode}; expected 600. run: chmod 600 ${ENV_FILE}"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*(CLOUDFLARE_API_TOKEN|CLOUDFLARE_ACCOUNT_ID)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      if ((${#value} >= 2)); then
        if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]] ||
          [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
          value="${value:1:${#value}-2}"
        fi
      fi
      SECRET_VALUES["$key"]="$value"
    fi
  done <"$ENV_FILE"

  for key in "${SECRET_KEYS[@]}"; do
    if [[ ! -v "SECRET_VALUES[$key]" ]]; then
      die "missing key ${key} in ${ENV_FILE}"
    fi
    if [[ -z "${SECRET_VALUES[$key]}" ]]; then
      die "empty value for ${key} in ${ENV_FILE}"
    fi
  done
}

check_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    die "gh CLI not found. install GitHub CLI first."
  fi
  if ! gh auth status >/dev/null 2>&1; then
    die "gh is not authenticated. run: gh auth login"
  fi
}

resolve_repos() {
  local repo_output repo

  if ((${#REPOS[@]} == 0)); then
    if ! repo_output="$(
      gh repo list "$ORG" --limit 200 --json name,isArchived \
        --jq '.[] | select(.isArchived | not) | .name'
    )"; then
      die "failed to list repositories in org ${ORG}"
    fi
    while IFS= read -r repo; do
      [[ -n "$repo" ]] && REPOS+=("$repo")
    done <<<"$repo_output"
    if ((${#REPOS[@]} == 0)); then
      die "no repositories found in org ${ORG}"
    fi
  fi
}

has_caller() {
  local repo="$1"

  gh api -H "Accept: application/vnd.github.raw" \
    "repos/${ORG}/${repo}/contents/${CALLER_PATH}" 2>/dev/null \
    | grep -qF "$CALLER_MARKER"
}

sync_repos() {
  local repo key value repo_failed
  local ok_count=0
  local skip_count=0
  local fail_count=0

  for repo in "${REPOS[@]}"; do
    if ((FORCE == 0)); then
      if ! has_caller "$repo"; then
        log "[skip] ${repo}: no caller for ${CALLER_MARKER%@} in ${CALLER_PATH}"
        ((skip_count += 1))
        continue
      fi
    fi

    if ((DRY_RUN == 1)); then
      log "[dry-run] ${repo}: would set CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID"
      ((ok_count += 1))
      continue
    fi

    repo_failed=0
    for key in "${SECRET_KEYS[@]}"; do
      value="${SECRET_VALUES[$key]}"
      if ! printf '%s' "$value" | gh secret set "$key" --repo "${ORG}/${repo}" >/dev/null; then
        log "[fail] ${repo}: failed to set ${key}"
        ((fail_count += 1))
        repo_failed=1
        break
      fi
    done
    if ((repo_failed == 0)); then
      log "[ok] ${repo}: set CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID"
      ((ok_count += 1))
    fi
  done

  if ((DRY_RUN == 1)); then
    log "summary: ok=${ok_count} skip=${skip_count} fail=${fail_count} (dry-run: no secrets were written)"
  else
    log "summary: ok=${ok_count} skip=${skip_count} fail=${fail_count}"
  fi

  if ((fail_count > 0)); then
    return 1
  fi
}

load_env_file
check_gh
resolve_repos
sync_repos
