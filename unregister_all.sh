#!/bin/bash
source .env
source utils.sh

echo "Finding GitHub runners..."

# Stop and remove systemd services
for svc in $(systemctl list-units --type=service --no-legend | grep 'github-runner@' | awk '{print $1}'); do
  echo "Stopping $svc"
  sudo systemctl stop "$svc"
  sudo systemctl disable "$svc"
  
  # Remove service file
  if [ -f "/etc/systemd/system/$svc" ]; then
    sudo rm "/etc/systemd/system/$svc"
    echo "   Removed service file: $svc"
  fi
done

# Remove runners from GitHub (if directories exist)
echo "Disconnecting runners from GitHub..."
while read -r repo; do
  [ -z "$repo" ] && continue
  
  NAME=$(echo "$repo" | tr '/' '_')
  DIR="$HOME/github-runners/$NAME"
  
  if [ -d "$DIR" ] && [ -f "$DIR/config.sh" ]; then
    echo "   Disconnecting runner for $repo..."
    cd "$DIR"
    
    # Get removal token
    TOKEN=$(get_runner_token "$repo")
    if [ -n "$TOKEN" ]; then
      ./config.sh remove --token "$TOKEN" --unattended 2>/dev/null || echo "     Warning: could not disconnect runner from GitHub"
    else
      echo "     Warning: could not get token for $repo"
    fi
    cd - > /dev/null
  fi
done < repos.txt

# Reload systemd
sudo systemctl daemon-reload

# Clean up runner directories
echo "Cleaning up runner directories..."

# Remove runners in home directory
if [ -d "$HOME/github-runners" ]; then
  echo "   Found runners in $HOME/github-runners"
  rm -rf "$HOME/github-runners"
  echo "   Removed directory $HOME/github-runners"
fi

echo "All runners unregistered and cleaned."
