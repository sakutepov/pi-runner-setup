#!/bin/bash

# Shared helpers. Call init_config explicitly after sourcing this file.
die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
  done
}

require_linux() {
  [[ "$(uname -s)" == Linux ]] || die "Runner management requires Linux with systemd."
}

init_config() {
  [[ -n "${SCRIPT_DIR:-}" ]] || die "SCRIPT_DIR is not set."
  [[ -f "$SCRIPT_DIR/.env" && -r "$SCRIPT_DIR/.env" ]] || die "Create a readable $SCRIPT_DIR/.env from .env.example."
  # .env is a trusted Bash configuration file, not untrusted input.
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  [[ -n "${HOME:-}" && "$HOME" == /* && "$HOME" != / ]] || die "HOME must be an absolute user home directory."
  [[ -n "${GITHUB_PAT:-}" && "$GITHUB_PAT" != ghp_your_personal_access_token_here ]] || die "Set GITHUB_PAT to a token with repository administration access."

  # Used by entry-point scripts that source this file.
  # shellcheck disable=SC2034
  RUNNERS_DIR="$HOME/github-runners"
  REPOS_FILE="$SCRIPT_DIR/repos.txt"
  RUNNER_VERSION="${RUNNER_VERSION:-2.337.0}"
  ARCH="${ARCH:-arm64}"
  case "$ARCH" in
    amd64|x86_64) ARCH=x64 ;;
    aarch64) ARCH=arm64 ;;
  esac
  LABELS="${LABELS:-raspberry-pi}"
  RUNNER_SHA256="${RUNNER_SHA256:-}"
  # Checksums published by actions/runner for the pinned default release.
  # A custom version must provide its own checksum before installation.
  if [[ -z "$RUNNER_SHA256" && "$RUNNER_VERSION" == 2.337.0 ]]; then
    case "$ARCH" in
      arm64) RUNNER_SHA256=9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393 ;;
      x64) RUNNER_SHA256=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613 ;;
    esac
  fi
}

validate_repo() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] || return 1
  local repository_name="${1#*/}"
  [[ "$repository_name" != . && "$repository_name" != .. ]]
}

repo_to_name() {
  validate_repo "$1" || die "Invalid repository: $1 (expected owner/repo)."
  printf '%s\n' "${1/\//_}"
}

load_repos() {
  [[ -f "$REPOS_FILE" && -r "$REPOS_FILE" ]] || die "Repository list is missing or unreadable: $REPOS_FILE"
  REPOSITORIES=()
  local line repository line_number=0 duplicate
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" && "$line" != \#* ]] || continue
    validate_repo "$line" || die "Invalid repository at $REPOS_FILE:$line_number (expected owner/repo)."
    duplicate=false
    # The guarded expansion also works with nounset in Bash 3.2/4.3.
    for repository in ${REPOSITORIES[@]+"${REPOSITORIES[@]}"}; do
      if [[ "$repository" == "$line" ]]; then
        duplicate=true
        break
      fi
    done
    [[ "$duplicate" == true ]] || REPOSITORIES+=("$line")
  done < "$REPOS_FILE"
}

request_runner_token() {
  local repository="$1" endpoint="$2" response token
  validate_repo "$repository" || die "Invalid repository: $repository (expected owner/repo)."
  require_commands curl jq
  if ! response=$(curl --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 60 --request POST \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: Bearer $GITHUB_PAT" \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/$repository/actions/runners/$endpoint"); then
    printf 'Error: Could not request %s for %s.\n' "$endpoint" "$repository" >&2
    return 1
  fi
  if ! token=$(printf '%s' "$response" | jq -er '.token | select(type == "string" and length > 0 and . != "null" and test("^\\S+$"))' 2>/dev/null); then
    printf 'Error: GitHub returned an invalid %s for %s.\n' "$endpoint" "$repository" >&2
    return 1
  fi
  printf '%s\n' "$token"
}

get_runner_token() {
  request_runner_token "$1" registration-token
}

get_removal_token() {
  request_runner_token "$1" remove-token
}
