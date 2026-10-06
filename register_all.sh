#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

[[ $# -eq 0 ]] || die "Usage: $0"
require_linux
require_commands id
[[ $(id -u) != 0 ]] || die "Run this script as the runner user, without sudo."
init_config
load_repos

for repo in ${REPOSITORIES[@]+"${REPOSITORIES[@]}"}; do
  name=$(repo_to_name "$repo")
  token=''
  if [[ ! -f "$RUNNERS_DIR/$name/.runner" ]]; then
    echo "Requesting registration for $repo..."
    token=$(get_runner_token "$repo")
  fi
  "$SCRIPT_DIR/install_runner.sh" "$repo" "$token" "$name"
done
