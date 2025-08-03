#!/bin/bash
source .env
source utils.sh

echo "Synchronizing runners with repository list..."

# Get desired runners from repos.txt
desired=$(cat repos.txt | grep -v '^#' | grep -v '^$' | tr '/' '_')

# Get existing systemd services
existing=$(systemctl list-units --type=service --no-legend | grep 'github-runner@' | awk '{print $1}' | sed 's/github-runner@//;s/\.service//')

# Find runners to remove (exist but not in repos.txt)
to_remove=$(comm -23 <(echo "$existing" | sort) <(echo "$desired" | sort))

# Remove unused runners
for svc in $to_remove; do
  echo "Removing unused runner: $svc"
  
  # Stop and disable service
  sudo systemctl stop github-runner@$svc
  sudo systemctl disable github-runner@$svc
  
  # Remove from GitHub if possible
  repo=$(echo "$svc" | tr '_' '/')
  runner_dir="$HOME/github-runners/$svc"
  
  if [ -d "$runner_dir" ] && [ -f "$runner_dir/config.sh" ]; then
    echo "  Disconnecting from GitHub..."
    cd "$runner_dir"
    TOKEN=$(get_runner_token "$repo" 2>/dev/null)
    if [ -n "$TOKEN" ]; then
      ./config.sh remove --token "$TOKEN" --unattended 2>/dev/null || echo "  Warning: could not disconnect from GitHub"
    fi
    cd - > /dev/null
  fi
  
  # Remove directories and service files
  sudo rm -f "/etc/systemd/system/github-runner@$svc.service"
  rm -rf "$HOME/github-runners/$svc" 2>/dev/null || true
  
  echo "  Removed runner: $svc"
done

# Reload systemd
sudo systemctl daemon-reload

# Register new runners
echo "Registering new runners..."
./register_all.sh

echo "Sync complete."
