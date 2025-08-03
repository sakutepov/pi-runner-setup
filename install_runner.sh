#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"
REPO="$1"
TOKEN="$2"
NAME="$3"
DIR="$HOME/github-runners/$NAME"

mkdir -p "$DIR"
cd "$DIR"

# Check if runner is already configured
if [ -f ".runner" ]; then
  echo "Runner already configured in $DIR"
else
  curl -s -L -o runner.tar.gz https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-$ARCH-$RUNNER_VERSION.tar.gz
  tar xzf runner.tar.gz

  ./config.sh --url "https://github.com/$REPO" --token "$TOKEN" \
    --unattended --name "$NAME" --labels "$LABELS"
fi

# Configure systemd service
# Create personalized service file for this runner
SERVICE_FILE="/etc/systemd/system/github-runner@$NAME.service"
sed -e "s|__RUNNER_DIR__|$DIR|g" \
    -e "s|__USER__|$(whoami)|g" \
    "$SCRIPT_DIR/github-runner.service.template" | sudo tee "$SERVICE_FILE" > /dev/null

sudo systemctl daemon-reload
sudo systemctl enable github-runner@$NAME
sudo systemctl start github-runner@$NAME
