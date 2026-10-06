#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/lifecycle.sh"

init_config
require_linux
require_commands jq systemctl sudo id rm

# Validate the entire desired state before any service or directory is changed.
# An explicitly empty readable list means remove all managed runners.
load_repos
load_installed_runners

echo "Synchronizing runners with repository list..."
for ((i = 0; i < ${#INSTALLED_NAMES[@]}; i++)); do
  desired=0
  for ((j = 0; j < ${#REPOSITORIES[@]}; j++)); do
    if [[ "${INSTALLED_REPOSITORIES[$i]}" == "${REPOSITORIES[$j]}" ]]; then
      desired=1
      break
    fi
  done
  if [[ "$desired" == 0 ]]; then
    remove_installed_runner "$i"
  fi
done

echo "Registering desired runners..."
"$SCRIPT_DIR/register_all.sh"
echo "Sync complete."
