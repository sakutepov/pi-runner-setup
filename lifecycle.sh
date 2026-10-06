#!/bin/bash

# Shared inventory and removal helpers. Callers source utils.sh and initialize
# configuration first. Inventory is completed before any runner is stopped.

lifecycle_error() {
  printf 'Error: %s\n' "$*" >&2
  return 1
}

runner_repository() {
  local runner_dir="$1" name="$2" repo="" runner_url="" url_repo=""

  if [[ -e "$runner_dir/.pi-runner-repo" || -L "$runner_dir/.pi-runner-repo" ]]; then
    [[ -f "$runner_dir/.pi-runner-repo" && ! -L "$runner_dir/.pi-runner-repo" &&
       -O "$runner_dir/.pi-runner-repo" && -r "$runner_dir/.pi-runner-repo" ]] || {
      lifecycle_error "Cannot safely read runner metadata in $runner_dir."
      return 1
    }
    repo="$(<"$runner_dir/.pi-runner-repo")"
    validate_repo "$repo" || {
      lifecycle_error "Invalid repository metadata in $runner_dir."
      return 1
    }
  fi

  if [[ -e "$runner_dir/.runner" || -L "$runner_dir/.runner" ]]; then
    [[ -f "$runner_dir/.runner" && ! -L "$runner_dir/.runner" &&
       -O "$runner_dir/.runner" && -r "$runner_dir/.runner" ]] || {
      lifecycle_error "Cannot safely read runner configuration in $runner_dir."
      return 1
    }
    if ! runner_url=$(jq -er 'if type == "object" then (.gitHubUrl // .githubUrl // "") else error("invalid runner configuration") end' "$runner_dir/.runner"); then
      lifecycle_error "Invalid runner configuration in $runner_dir."
      return 1
    fi
    if [[ -n "$runner_url" ]]; then
      runner_url="${runner_url%/}"
      [[ "$runner_url" == https://github.com/* ]] || {
        lifecycle_error "Unsupported runner repository URL in $runner_dir."
        return 1
      }
      url_repo="${runner_url#https://github.com/}"
      validate_repo "$url_repo" || {
        lifecycle_error "Invalid runner repository URL in $runner_dir."
        return 1
      }
      if [[ -n "$repo" && "$repo" != "$url_repo" ]]; then
        lifecycle_error "Repository metadata disagrees with .runner in $runner_dir."
        return 1
      fi
      repo="$url_repo"
    fi
  fi

  # GitHub owner names cannot contain underscores. Split only the first one:
  # owner_project_with_underscores represents owner/project_with_underscores.
  if [[ -z "$repo" && "$name" == *_* ]]; then
    repo="${name%%_*}/${name#*_}"
  fi
  validate_repo "$repo" || {
    lifecycle_error "Cannot determine the repository for $runner_dir."
    return 1
  }
  [[ "$(repo_to_name "$repo")" == "$name" ]] || {
    lifecycle_error "Runner directory name disagrees with its repository: $runner_dir."
    return 1
  }
  printf '%s\n' "$repo"
}

inspect_runner_service() {
  local service="$1" runner_dir="$2" details key value show_status=0
  local load_state="" service_user="" working_dir="" fragment_path=""
  RUNNER_HAS_SERVICE=0

  details=$(systemctl show "$service" --property=LoadState --property=User --property=WorkingDirectory --property=FragmentPath --no-pager) || show_status=$?
  while IFS='=' read -r key value; do
    case "$key" in
      LoadState) load_state="$value" ;;
      User) service_user="$value" ;;
      WorkingDirectory) working_dir="$value" ;;
      FragmentPath) fragment_path="$value" ;;
    esac
  done <<< "$details"

  if [[ "$load_state" == "not-found" ]]; then
    # A failed daemon-reload can leave a unit on disk that the manager does not
    # know about. Its ownership must be established before removing runner data.
    [[ ! -e "/etc/systemd/system/$service" && ! -L "/etc/systemd/system/$service" ]] || {
      lifecycle_error "Service exists on disk but is not loaded; inspect it before retrying: $service."
      return 1
    }
    return 0
  fi
  if [[ "$show_status" != 0 ]]; then
    lifecycle_error "Cannot inspect $service; no runners were changed."
    return 1
  fi
  [[ "$load_state" == "loaded" ]] || {
    lifecycle_error "Unexpected load state for $service: ${load_state:-unknown}."
    return 1
  }
  [[ "$service_user" == "$RUNNER_USER" && "$working_dir" == "$runner_dir" &&
     "$fragment_path" == "/etc/systemd/system/$service" ]] || {
    lifecycle_error "Refusing to change $service: it does not belong to this user's runner directory."
    return 1
  }
  RUNNER_HAS_SERVICE=1
}

load_installed_runners() {
  local runner_dir name repo service
  INSTALLED_NAMES=()
  INSTALLED_REPOSITORIES=()
  INSTALLED_DIRS=()
  INSTALLED_HAS_SERVICES=()
  RUNNER_USER=$(id -un) || return 1

  [[ ! -L "$RUNNERS_DIR" ]] || {
    lifecycle_error "Refusing to manage a symlinked runner root: $RUNNERS_DIR."
    return 1
  }
  [[ -e "$RUNNERS_DIR" ]] || return 0
  [[ -d "$RUNNERS_DIR" && -O "$RUNNERS_DIR" ]] || {
    lifecycle_error "Runner root must be a directory owned by the current user: $RUNNERS_DIR."
    return 1
  }

  for runner_dir in "$RUNNERS_DIR"/*; do
    [[ -d "$runner_dir" && ! -L "$runner_dir" && -O "$runner_dir" ]] || continue
    [[ -e "$runner_dir/.pi-runner-repo" || -L "$runner_dir/.pi-runner-repo" ||
       -e "$runner_dir/.runner" || -L "$runner_dir/.runner" ]] || continue
    name="${runner_dir##*/}"
    repo=$(runner_repository "$runner_dir" "$name") || return 1
    # A failed download may leave only repository metadata. There is nothing to
    # deregister in that state, so config.sh is needed only for configured runners.
    if [[ -f "$runner_dir/.runner" ]]; then
      [[ -f "$runner_dir/config.sh" && ! -L "$runner_dir/config.sh" &&
         -O "$runner_dir/config.sh" && -x "$runner_dir/config.sh" ]] || {
        lifecycle_error "Configured runner is missing an executable config.sh owned by the current user: $runner_dir."
        return 1
      }
    fi
    service="github-runner@$name.service"
    inspect_runner_service "$service" "$runner_dir" || return 1
    INSTALLED_NAMES+=("$name")
    INSTALLED_REPOSITORIES+=("$repo")
    INSTALLED_DIRS+=("$runner_dir")
    INSTALLED_HAS_SERVICES+=("$RUNNER_HAS_SERVICE")
  done
}

remove_installed_runner() {
  local index="$1" name repo runner_dir service token
  name="${INSTALLED_NAMES[$index]}"
  repo="${INSTALLED_REPOSITORIES[$index]}"
  runner_dir="${INSTALLED_DIRS[$index]}"
  service="github-runner@$name.service"

  printf 'Removing runner for %s...\n' "$repo"
  if [[ "${INSTALLED_HAS_SERVICES[$index]}" == 1 ]]; then
    if ! sudo systemctl stop "$service"; then
      lifecycle_error "Could not stop $service; runner directory and service file were kept."
      return 1
    fi
  fi

  # .runner disappears after successful deregistration. If a later local cleanup
  # fails, retain .pi-runner-repo so the next invocation can finish cleanup.
  if [[ -f "$runner_dir/.runner" ]]; then
    if ! token=$(get_removal_token "$repo"); then
      lifecycle_error "Could not get a removal token for $repo; runner directory and service file were kept."
      return 1
    fi
    if [[ ! -f "$runner_dir/.pi-runner-repo" ]]; then
      if ! printf '%s\n' "$repo" > "$runner_dir/.pi-runner-repo"; then
        lifecycle_error "Could not save repository metadata for $repo; runner directory and service file were kept."
        return 1
      fi
    fi
    if ! (cd "$runner_dir" && ./config.sh remove --token "$token" --unattended); then
      lifecycle_error "Could not deregister $repo; runner directory and service file were kept."
      return 1
    fi
  fi

  if [[ "${INSTALLED_HAS_SERVICES[$index]}" == 1 ]]; then
    if ! sudo systemctl disable "$service"; then
      lifecycle_error "$repo was deregistered, but $service could not be disabled; local files were kept."
      return 1
    fi
    if ! sudo rm -f -- "/etc/systemd/system/$service"; then
      lifecycle_error "$repo was deregistered, but its service file could not be removed; runner directory was kept."
      return 1
    fi
  fi
  if ! rm -rf -- "$runner_dir"; then
    lifecycle_error "$repo was deregistered, but runner directory cleanup failed: $runner_dir."
    return 1
  fi
  if [[ "${INSTALLED_HAS_SERVICES[$index]}" == 1 ]]; then
    if ! sudo systemctl daemon-reload; then
      lifecycle_error "$repo was removed, but systemd could not reload its units."
      return 1
    fi
  fi
  printf 'Removed runner for %s.\n' "$repo"
}
