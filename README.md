# Raspberry Pi GitHub Actions Runner Setup

Install and manage one repository-level GitHub Actions runner per repository on
Linux with systemd. Supports 64-bit Raspberry Pi OS (ARM64) and x86_64 Linux.

The next project release is **v0.1.0**. The bootstrap version of the GitHub Runner
application is configured separately in `.env`; existing runners keep GitHub's
default automatic updates enabled.

## Requirements

- Linux with systemd 240 or later and a supported 64-bit OS; on Raspberry Pi, use 64-bit
  Raspberry Pi OS. This project does not manage runners on macOS or Windows.
- Bash, `curl`, `jq`, `tar`, `sudo`, `systemctl`, and `sha256sum` or `shasum`.
- A non-root account with permission to manage system services through `sudo`.
- Outbound HTTPS access to GitHub and the domains used by Actions.
- Administration access to every repository in `repos.txt`.

On Debian/Ubuntu, install the command-line dependencies with:

```bash
sudo apt-get update
sudo apt-get install curl jq tar
```

The runner also needs the native libraries listed in [GitHub's supported runner
requirements](https://docs.github.com/en/actions/reference/runners/self-hosted-runners).
If configuration reports a missing library, the downloaded package provides
`bin/installdependencies.sh`; run it with `sudo` in the affected runner directory,
then retry registration.

## Quick start

Use this only for repositories and workflows you trust. Jobs run as the Linux
account that performs installation; see the security section before setup.

```bash
git clone https://github.com/sakutepov/pi-runner-setup.git
cd pi-runner-setup
cp .env.example .env
chmod 600 .env
cp repos.txt.example repos.txt
```

Edit `.env` and replace the example PAT. A fine-grained PAT can be limited to the
selected repositories with **Administration: read and write** permission. For
classic PATs, GitHub documents the `repo` scope for these repository endpoints.
An `admin:org` scope is not needed merely because a repository belongs to an
organization; this project uses repository-level runners, not organization-level
runners. Organization policy may require separate approval of the token.
See the [GitHub runner API authentication requirements](https://docs.github.com/en/rest/actions/self-hosted-runners#create-a-registration-token-for-a-repository).

For Raspberry Pi, keep `ARCH=arm64`. For x86_64 Linux, set `ARCH=x64`;
`amd64`/`x86_64` aliases are accepted. `aarch64` maps to `arm64`.

The default runner version is `2.337.0`; its official ARM64 and x64 SHA-256
checksums are built in. To use another version, set both `RUNNER_VERSION` and
`RUNNER_SHA256` using the checksum from the [official runner release](https://github.com/actions/runner/releases).
The archive is verified before extraction. GitHub progressively rolls out runner
versions, so check your repository's runner download instructions when selecting
a different version.

Edit `repos.txt` with one `owner/repo` per line:

```text
my-account/first-repo
my-organization/project_with_underscores
```

Blank lines and full-line comments are ignored. CRLF files, surrounding whitespace,
duplicates, and a final line without a newline are supported. Malformed entries
stop the operation before any runner is changed.

```bash
./register_all.sh
```

Scripts resolve configuration relative to their own location, so they can also
be invoked by absolute path from another directory.

## Managing runners

```bash
# Install missing runners and start configured runners, including stopped ones.
./register_all.sh

# Match installed runners to repos.txt: remove unused runners, then register.
./sync.sh

# Remove all managed runners owned by this account, regardless of repos.txt.
./unregister_all.sh

# Inspect a particular runner. Replace owner_repo with its actual name.
systemctl status github-runner@owner_repo.service
journalctl -u github-runner@owner_repo.service -f
```

**An explicitly empty or comments-only `repos.txt` removes all managed runners
when running `sync.sh`.** A missing, unreadable, or malformed list fails before
removal. Review the list before syncing; a dry-run command is planned for a later
release.

Run one management command at a time; concurrent management operations are not
supported. Runner directories live at `$HOME/github-runners/owner_repo/`.
Service units are named `github-runner@owner_repo.service` and use GitHub's
`runsvc.sh` entry point.
The unit uses `Type=exec` and startup checks confirm it remains active; this
does not prove the runner has connected to GitHub or accepted a job.
New installations store the exact repository in `.pi-runner-repo`. Existing
installations from the original scripts can be recognized from `.runner`
metadata and their directory name.

Cleanup inventories managed directories rather than relying on running service
status, so stopped runners and repositories removed from the desired list are
included. Unmanaged directories and another user's services are left untouched;
inconsistent managed state causes an error requiring inspection.

Registration and removal use separate short-lived GitHub API tokens. HTTP,
JSON, checksum, configuration, and service errors result in a nonzero exit code.
A service is installed only after successful runner configuration. If stopping
or deregistering a runner fails, its local state is preserved for retry. Cleanup
is not a filesystem transaction: a later disable or deletion error can leave a
partially cleaned, already deregistered runner; the script reports the failure.

## Troubleshooting

- **Invalid token / permission denied:** check PAT expiry, selected repositories,
  Administration permission, and any organization approval requirements.
- **Download or checksum failure:** check the runner version, architecture, and
  published checksum. Retry after fixing the cause; do not disable verification.
- **Configuration failure:** inspect the runner output and `_diag/` logs. The
  partial directory is kept so you can diagnose missing native libraries.
- **Removal failure:** repair the token, connectivity, or service error and rerun
  cleanup. Avoid manually deleting a configured runner's credentials.
- **Foreign or inconsistent service:** inspect `systemctl cat` and `.runner`
  metadata. The scripts deliberately refuse to overwrite or remove that service.

## Security

Self-hosted runners execute workflow code with the permissions and filesystem
access of their Linux user. Separate runner directories **do not isolate jobs**
from each other, `.env`, personal files, or the local network. This setup is
intended for trusted workflows. Do not execute untrusted fork pull requests on
these persistent runners.

Use a dedicated machine/account with no personal SSH keys or unrelated secrets;
keep PAT permissions and lifetime limited. `.env` is a Bash script sourced during
management, so only trusted users should edit it. `chmod 600` protects it from
other accounts, not from jobs running as its owner. A PAT used for management
must not be exposed to untrusted jobs. Avoid giving the runtime account
passwordless unrestricted `sudo` or Docker socket access.

For untrusted workloads, use GitHub-hosted runners or properly isolated disposable
environments. This project does not implement that isolation. GitHub documents
these risks in its [self-hosted runner security guidance](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners).
The automated report in [issue #1](https://github.com/sakutepov/pi-runner-setup/issues/1)
is not evidence of an exploitable workflow in this repository, which has no
self-hosted CI workflow. The project's own checks run on GitHub-hosted Ubuntu.

## Development and releases

```bash
for script in *.sh; do bash -n "$script"; done
shellcheck *.sh
python3 -m unittest discover -s tests -v
```

Tests use temporary homes, fake tokens, and command stubs; they never register
real runners or manage the host's services. When `systemd-analyze` is available,
they also verify actual generated units, including paths with spaces. CI runs
syntax checks, ShellCheck, and all 23 regressions on GitHub-hosted Ubuntu.

See [CHANGELOG.md](CHANGELOG.md) and the [v0.1.0 release draft and validation
checklist](docs/releases/v0.1.0.md). A real Raspberry Pi and end-to-end GitHub
registration need separate validation; mock tests alone do not verify them.

MIT License. See [LICENSE](LICENSE).
