#!/bin/bash
source .env
source utils.sh

while read -r repo; do
  [ -z "$repo" ] && continue

  NAME=$(echo "$repo" | tr '/' '_')

  if systemctl is-active --quiet github-runner@$NAME; then
    echo "Runner for $repo already running."
    continue
  fi

  echo "Setting up runner for $repo..."
  TOKEN=$(get_runner_token "$repo")
  ./install_runner.sh "$repo" "$TOKEN" "$NAME"
done < repos.txt
