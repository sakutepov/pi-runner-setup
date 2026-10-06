#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/lifecycle.sh"

init_config
require_linux
require_commands jq systemctl sudo id rm

# Installed runner metadata, rather than the current desired list, determines
# what must be deregistered. Unmanaged directories under RUNNERS_DIR are kept.
load_installed_runners

echo "Unregistering installed runners..."
for ((i = 0; i < ${#INSTALLED_NAMES[@]}; i++)); do
  remove_installed_runner "$i"
done
echo "All managed runners unregistered and cleaned."
