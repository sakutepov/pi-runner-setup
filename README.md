# Raspberry Pi GitHub Actions Runner Setup

This project automates the installation and management of multiple GitHub self-hosted runners on Linux systems, with special optimizations for Raspberry Pi.

## Features

- **Multi-repository support**: One runner per GitHub repository
- **Automated setup**: Token retrieval and runner installation
- **Easy management**: Add/remove repositories with simple config files
- **Robust cleanup**: Complete removal including GitHub API deregistration
- **Systemd integration**: Persistent runners with automatic restart
- **Smart detection**: Prevents duplicate installations
- **Cross-platform**: Works on ARM64 (Raspberry Pi) and AMD64 systems

## Project Structure

```
pi-runner-setup/
├── .env.example              # Environment configuration template
├── repos.txt.example         # Repository list template
├── install_runner.sh         # Individual runner installation script
├── register_all.sh           # Register all runners from repos.txt
├── unregister_all.sh         # Complete cleanup of all runners
├── sync.sh                       # Sync runners with repository list
├── utils.sh                      # Utility functions for GitHub API
├── github-runner.service.template # Systemd service template
├── README.md
└── .gitignore
```

## Quick Start

### 1. Clone and Setup

```bash
git clone <repository-url>
cd pi-runner-setup
chmod +x *.sh
```

### 2. Configure Environment

```bash
cp .env.example .env
cp repos.txt.example repos.txt
```

Edit `.env` with your settings:
```bash
# GitHub Personal Access Token with repo and admin:org permissions
GITHUB_PAT=ghp_your_personal_access_token_here

# Repository owner (your GitHub username or organization)  
REPO_OWNER=your-github-username

# GitHub Actions Runner version
RUNNER_VERSION=2.327.1

# System architecture (arm64 for Raspberry Pi 4/5, amd64 for x86_64)
ARCH=arm64

# Custom labels for the runners (comma-separated)
LABELS="self-hosted,raspberry-pi"

# Language for runner output
LANG=en_US.UTF-8
```

### 3. Add Repositories

Edit `repos.txt` with your repositories (one per line):
```
your-username/first-repo
your-username/second-repo
your-organization/project-name
```

### 4. Install Runners

```bash
./register_all.sh
```

## Usage

### Register All Runners
```bash
./register_all.sh
```

### Check Runner Status
```bash
systemctl status github-runner@*
```

### Remove All Runners
```bash
./unregister_all.sh
```

### Sync Runners (remove unused, add new)
```bash
./sync.sh
```

## Configuration Details

### GitHub Personal Access Token

Your GitHub PAT needs the following permissions:
- `repo` (Full control of private repositories)
- `admin:org` (Full control of orgs and teams) - if using organization repositories

### Supported Architectures

- `arm64` - Raspberry Pi 4/5, ARM64 servers
- `amd64` - Standard x86_64 systems

### Runner Storage

- **Location**: `$HOME/github-runners/<repo-name>/`
- **Structure**: Each repository gets its own isolated directory

### Systemd Services

Each runner gets its own systemd service:
- Service name: `github-runner@<repo-name>.service`
- Template: `github-runner.service.template` (automatically customized per user)
- Auto-start on boot: Yes
- Auto-restart on failure: Yes
- User-specific: Runs under the user who installed it

## Troubleshooting

### Check Runner Logs
```bash
journalctl -u github-runner@<repo-name> -f
```

### Manual Runner Operations
```bash
# Stop specific runner
sudo systemctl stop github-runner@<repo-name>

# Start specific runner  
sudo systemctl start github-runner@<repo-name>

# Check runner directory
ls -la ~/github-runners/<repo-name>/
```

### Common Issues

1. **"Runner already exists"**: Use `./unregister_all.sh` first
2. **Permission denied**: Ensure your GitHub PAT has correct permissions
3. **Download failures**: Check network connectivity and runner version
4. **Service start failures**: Check systemd logs with `journalctl`

## Security Considerations

- Store your `.env` file securely (it's in `.gitignore`)
- Use GitHub PAT with minimal required permissions
- Regularly update runner versions
- Monitor runner activity in GitHub repository settings

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

MIT License - see LICENSE file for details
