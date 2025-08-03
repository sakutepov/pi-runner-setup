#!/bin/bash

# Get GitHub Actions runner registration token for a repository
# Usage: get_runner_token "owner/repo"
get_runner_token() {
  local REPO="$1"
  curl -s -X POST \
    -H "Authorization: token $GITHUB_PAT" \
    https://api.github.com/repos/$REPO/actions/runners/registration-token \
    | jq -r .token
}
