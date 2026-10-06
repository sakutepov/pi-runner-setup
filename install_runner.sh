#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

[[ $# -ge 1 && $# -le 3 ]] || die "Usage: $0 owner/repo [registration-token] [runner-name]"
REPO=$1
TOKEN=${2:-}
validate_repo "$REPO" || die "Invalid repository: $REPO"
EXPECTED_NAME=$(repo_to_name "$REPO")
NAME=${3:-$EXPECTED_NAME}
[[ "$NAME" == "$EXPECTED_NAME" ]] || die "Runner name must be $EXPECTED_NAME for $REPO"

require_linux
require_commands id systemctl sudo jq mktemp install cp chmod rm mkdir mv
[[ $(id -u) != 0 ]] || die "Run this script as the runner user, without sudo."
init_config

DIR="$RUNNERS_DIR/$NAME"
SERVICE_NAME="github-runner@$NAME.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
RUNNER_USER=$(id -un)
[[ "$RUNNER_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] || die "Unsupported runner user name"
[[ "$DIR" != *$'\n'* && "$DIR" != *$'\r'* ]] || die "Runner directory cannot contain a newline"
[[ "$DIR" != *'$'* ]] || die "Runner directory cannot contain a dollar sign (systemd expands it in ExecStart)"
[[ ! -L "$RUNNERS_DIR" && ! -L "$DIR" ]] || die "Runner directories must not be symbolic links"
[[ ! -e "$RUNNERS_DIR" || ( -d "$RUNNERS_DIR" && -O "$RUNNERS_DIR" ) ]] || die "Runner storage is not owned by the current user"
[[ ! -e "$DIR" || ( -d "$DIR" && -O "$DIR" ) ]] || die "Runner directory is not owned by the current user"
[[ ! -L "$DIR/.runner" && ! -L "$DIR/config.sh" && ! -L "$DIR/runsvc.sh" ]] || die "Runner configuration and entry points must not be symbolic links"
if [[ -d "$DIR" && ! -e "$DIR/.runner" && ! -e "$DIR/.pi-runner-repo" ]]; then
  die "Refusing to overwrite an unmanaged directory: $DIR"
fi
[[ ! -L "$SERVICE_FILE" ]] || die "Refusing to replace a symbolic-link service: $SERVICE_FILE"

# Check the loaded unit before touching runner files or replacing a system-wide unit.
UNIT_PROPERTIES=''
UNIT_STATUS=0
UNIT_PROPERTIES=$(systemctl show "$SERVICE_NAME" --property=LoadState --property=User \
  --property=WorkingDirectory --property=FragmentPath --no-pager) || UNIT_STATUS=$?
LOAD_STATE=''
UNIT_USER=''
UNIT_DIR=''
UNIT_PATH=''
while IFS='=' read -r property value; do
  case "$property" in
    LoadState) LOAD_STATE=$value ;;
    User) UNIT_USER=$value ;;
    WorkingDirectory) UNIT_DIR=$value ;;
    FragmentPath) UNIT_PATH=$value ;;
  esac
done <<< "$UNIT_PROPERTIES"
[[ "$LOAD_STATE" == not-found || $UNIT_STATUS -eq 0 ]] || die "Cannot inspect $SERVICE_NAME"
if [[ "$LOAD_STATE" == not-found ]]; then
  # A unit present on disk but not loaded cannot safely be attributed to this user.
  [[ ! -e "$SERVICE_FILE" ]] || die "Service exists on disk but is not loaded; inspect it before retrying: $SERVICE_FILE"
else
  [[ "$LOAD_STATE" == loaded ]] || die "Cannot establish ownership of $SERVICE_NAME"
  [[ "$UNIT_USER" == "$RUNNER_USER" && "$UNIT_DIR" == "$DIR" && "$UNIT_PATH" == "$SERVICE_FILE" ]] || \
    die "Refusing to replace a service belonging to another user or runner: $SERVICE_NAME"
fi

if [[ -f "$DIR/.runner" ]]; then
  [[ -r "$DIR/.runner" && -O "$DIR/.runner" ]] || die "Runner configuration must be readable and owned by the current user: $DIR"
  [[ -x "$DIR/config.sh" && -O "$DIR/config.sh" ]] || die "Configured runner requires executable config.sh owned by the current user: $DIR"
  RUNNER_URL=$(jq -er '.gitHubUrl // .githubUrl // empty' "$DIR/.runner") || die "Cannot read configured runner repository: $DIR"
  [[ "${RUNNER_URL%/}" == "https://github.com/$REPO" ]] || die "Configured runner belongs to another repository: $DIR"
  echo "Runner for $REPO is already configured."
else
  [[ ! -e "$DIR/.runner" ]] || die "Runner configuration is not a regular file: $DIR/.runner"
  [[ "$TOKEN" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ && "$TOKEN" != null ]] || die "A valid registration token is required for $REPO"
  case "$ARCH" in
    x64|arm64) ;;
    *) die "Unsupported runner architecture: $ARCH" ;;
  esac
  [[ "$RUNNER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid runner version: $RUNNER_VERSION"
  [[ "${RUNNER_SHA256:-}" =~ ^[[:xdigit:]]{64}$ ]] || die "Set RUNNER_SHA256 to the official SHA-256 digest for $RUNNER_VERSION/$ARCH"
  require_commands curl tar tr
  if command -v sha256sum >/dev/null 2>&1; then
    HASH_COMMAND=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    HASH_COMMAND=(shasum -a 256)
  else
    die "Missing command: sha256sum or shasum"
  fi
fi

if [[ -e "$DIR/.pi-runner-repo" || -L "$DIR/.pi-runner-repo" ]]; then
  [[ -f "$DIR/.pi-runner-repo" && ! -L "$DIR/.pi-runner-repo" && -r "$DIR/.pi-runner-repo" && -O "$DIR/.pi-runner-repo" ]] || die "Invalid runner repository metadata: $DIR"
  [[ $(<"$DIR/.pi-runner-repo") == "$REPO" ]] || die "Runner repository metadata disagrees with $REPO: $DIR"
fi

umask 077
mkdir -p -- "$DIR"
ARCHIVE_FILE=''
UNIT_TEMP=''
REPO_TEMP=''
cleanup() {
  local temporary
  for temporary in "$ARCHIVE_FILE" "$UNIT_TEMP" "$REPO_TEMP"; do
    [[ -z "$temporary" ]] || rm -f -- "$temporary"
  done
}
trap cleanup EXIT

# Record identity before configuration so an interrupted installation is recoverable.
REPO_TEMP=$(mktemp "$DIR/.pi-runner-repo.XXXXXX")
printf '%s\n' "$REPO" > "$REPO_TEMP"
mv -- "$REPO_TEMP" "$DIR/.pi-runner-repo"
REPO_TEMP=''

if [[ ! -f "$DIR/.runner" ]]; then
  ARCHIVE_FILE=$(mktemp "$DIR/.runner-download.XXXXXX")
  DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-$ARCH-$RUNNER_VERSION.tar.gz"
  curl --fail --show-error --silent --location --retry 3 --connect-timeout 10 \
    --max-time 300 --output "$ARCHIVE_FILE" "$DOWNLOAD_URL"
  HASH_OUTPUT=$("${HASH_COMMAND[@]}" "$ARCHIVE_FILE")
  ACTUAL_SHA256=${HASH_OUTPUT%%[[:space:]]*}
  EXPECTED_SHA256=$(printf '%s' "$RUNNER_SHA256" | tr '[:upper:]' '[:lower:]')
  [[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || die "Runner archive SHA-256 verification failed"
  tar -xzf "$ARCHIVE_FILE" -C "$DIR"
  rm -f -- "$ARCHIVE_FILE"
  ARCHIVE_FILE=''
  [[ -x "$DIR/config.sh" ]] || die "Runner archive is missing executable config.sh"
  (cd -- "$DIR" && ./config.sh --url "https://github.com/$REPO" --token "$TOKEN" \
    --unattended --name "$NAME" --labels "$LABELS")
  [[ -f "$DIR/.runner" ]] || die "Runner configuration did not produce .runner"
fi

# GitHub's official svc.sh provisions this entry point from the runner package.
if [[ ! -x "$DIR/runsvc.sh" ]]; then
  [[ -f "$DIR/bin/runsvc.sh" ]] || die "Runner package is missing bin/runsvc.sh"
  cp -- "$DIR/bin/runsvc.sh" "$DIR/runsvc.sh"
  chmod 755 "$DIR/runsvc.sh"
fi

[[ -r "$SCRIPT_DIR/github-runner.service.template" ]] || die "Missing systemd service template"
# Quote paths for systemd syntax and escape its % specifiers.
UNIT_DIR_ESCAPED=${DIR//\\/\\\\}
UNIT_DIR_ESCAPED=${UNIT_DIR_ESCAPED//\"/\\\"}
UNIT_DIR_ESCAPED=${UNIT_DIR_ESCAPED//%/%%}
UNIT_CONTENT=$(<"$SCRIPT_DIR/github-runner.service.template")
UNIT_CONTENT=${UNIT_CONTENT//__RUNNER_DIR__/"$UNIT_DIR_ESCAPED"}
UNIT_CONTENT=${UNIT_CONTENT//__USER__/"$RUNNER_USER"}
UNIT_TEMP=$(mktemp "$DIR/.systemd-unit.XXXXXX")
printf '%s\n' "$UNIT_CONTENT" > "$UNIT_TEMP"
sudo install -m 0644 "$UNIT_TEMP" "$SERVICE_FILE"
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl start "$SERVICE_NAME"
systemctl is-active --quiet "$SERVICE_NAME" || die "Runner service did not remain active: $SERVICE_NAME"
echo "Runner for $REPO is configured and its service is started."
