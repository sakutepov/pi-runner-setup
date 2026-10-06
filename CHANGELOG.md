# Changelog

## Unreleased — planned v0.1.0

### Fixed

- Stop before mutation when the repository list is missing, unreadable, or invalid.
- Parse comments, CRLF, whitespace, duplicates, and a final line without a newline
  consistently across management scripts.
- Propagate GitHub API, download, configuration, and service errors.
- Verify the downloaded runner's SHA-256 checksum before extraction.
- Accept `amd64`/`x86_64` aliases for the correct `x64` download asset.
- Use separate registration and removal tokens and preserve local state on
  stop or deregistration failure.
- Discover installed runners even when stopped or removed from `repos.txt`.
- Preserve exact repository identities, including underscores in repository names.
- Use `runsvc.sh` and `Type=exec` for systemd, check active status after startup,
  and refuse foreign or inconsistent service units.
- Resolve configuration relative to script location.

### Added

- Hermetic regression tests and CI on GitHub-hosted Ubuntu.
- Release preparation checklist and documented trust boundaries and PAT scopes.

### Changed

- Bootstrap GitHub Actions Runner version from 2.327.1 to 2.337.0.
- Removed the unused `REPO_OWNER` setting; each list entry provides its owner.
