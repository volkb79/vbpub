
### Quick Start Examples

```bash
# GitHub App repository sync
github/app-sync --app-id 2030793 --verbose

# List GitHub App installations
github/list-installations --app-id 2030793 --format table --show-repos

# Decode JWT token
echo "JWT_TOKEN" | utils/jwt-decode --validate --verbose

# Checkout repository subtree
utils/subtree-checkout volkb79/DST-DNS projects/controller

# Initialize Docker Compose
ciu --directory /path/to/project --verbose
```

### Configuration Validation

```bash
# Validate GitHub App configuration
github/app-sync --validate --app-id 2030793 --verbose

# Test JWT generation
github/list-installations --validate --app-id 2030793


# GitHub Authentication Scripts

This directory contains scripts for managing Git authentication with GitHub Apps and SSH keys.

## Scripts Overview

### 🔐 GitHub App Authentication (Recommended)

- **`setup_github_app_auth.sh`** - Complete setup for GitHub App authentication
- **`git-credential-github-app`** - Git credential helper for automatic token management
- **`convert_to_github_app.sh`** - Convert repositories to use GitHub App authentication
- **`github_app_config.sh`** - Check and configure GitHub App settings
- **`switch_to_writeable_app.sh`** - Switch from read-only to writeable GitHub App

### 🔑 SSH Authentication (Alternative)

- **`convert_to_ssh.sh`** - Convert repositories to use SSH authentication

### 🔧 GitHub App Management

- **`github_app_sync.sh`** - Comprehensive GitHub App repository synchronization

## Quick Start

### 1. Setup GitHub App Authentication (Recommended)

```bash
cd /path/to/vbpub/scripts

# Complete setup (installs credential helper, configures Git)
./setup_github_app_auth.sh

# Convert all repositories to use GitHub App
./convert_to_github_app.sh
```

### 2. Alternative: SSH Authentication

```bash
cd /path/to/vbpub/scripts

# Convert repositories to SSH (requires SSH key setup)
./convert_to_ssh.sh
```

## Prerequisites

### For GitHub App Authentication:
- GitHub App with appropriate permissions (read/write)
- App private key file (usually `~/.ssh/github_app_key.pem`)
- Environment variables set:
  ```bash
  export WRITEABLE_APP_ID=YOUR_APP_ID
  export GITHUB_APP_PRIVATE_KEY_PATH=~/.ssh/github_app_key.pem
  ```

### For SSH Authentication:
- SSH key pair generated and added to GitHub
- SSH agent running (if using passphrase)

## Configuration

### GitHub App Environment Variables

Add these to your shell profile (`~/.zshrc`, `~/.bashrc`, or `~/.profile`):

```bash
# Writeable GitHub App Configuration
export WRITEABLE_APP_ID=2041752
export GITHUB_APP_ID=2041752
export GITHUB_APP_PRIVATE_KEY_PATH=/home/vb/.ssh/github_app_key.pem
```

### Repository Detection

Scripts automatically detect the repository structure:
- When run from `vbpub/scripts`: Works with `../../` (parent directories)
- When run from `~/repos`: Works with current directory structure
- Supports repositories: `DST-DNS`, `vbpro`, `vbpub`

## How GitHub App Authentication Works

1. **Credential Helper**: `git-credential-github-app` intercepts Git authentication requests
2. **JWT Generation**: Creates signed JWT using your GitHub App private key
3. **Installation Discovery**: Finds GitHub App installation ID automatically  
4. **Token Generation**: Exchanges JWT for short-lived installation token
5. **Token Caching**: Caches tokens until near expiration for performance
6. **Automatic Refresh**: Generates new tokens when needed

## Benefits of GitHub App vs SSH

### GitHub App Authentication ✅
- ✅ Fine-grained repository permissions
- ✅ Short-lived tokens (automatic expiration)
- ✅ Better audit trail and logging
- ✅ Higher API rate limits
- ✅ Organization-managed access control
- ✅ Recommended for automation and CI/CD
- ✅ Works seamlessly with VS Code

### SSH Authentication ⚡
- ⚡ Simple setup for individual developers
- ⚡ No token management needed
- ⚡ Works across all Git operations
- ❌ User-level access (not app-specific)
- ❌ Key management complexity in teams

## Troubleshooting

### GitHub App Issues

```bash
# Check configuration
./github_app_config.sh

# Test credential helper
echo -e 'protocol=https\nhost=github.com\npath=test\n' | git-credential-github-app get

# Clear token cache
git-credential-github-app erase
```

### SSH Issues

```bash
# Test SSH connection
ssh -T git@github.com

# Check SSH key
ls -la ~/.ssh/id_*
```

### Common Solutions

1. **Token expired**: Credential helper auto-refreshes, or run `git-credential-github-app erase`
2. **Permission denied**: Check GitHub App has repository access
3. **Not found**: Verify repository URLs and GitHub App installation
4. **Network issues**: Check internet connection and GitHub API status

## Integration with VS Code

All authentication methods work seamlessly with VS Code:
- **Source Control panel**: Commit, push, pull operations
- **Terminal**: Git commands work normally  
- **Extensions**: Git-related extensions use configured authentication

## Security Notes

- **GitHub App tokens**: Expire automatically (1 hour default)
- **Private keys**: Keep secure with proper file permissions (600)
- **SSH keys**: Use passphrases for additional security
- **Token caching**: Cached in `~/.cache/github-app-token` (user-only access)

## Script Portability

All scripts are designed to work from any location:
- Auto-detect repository structure
- Portable path resolution
- Cross-platform shell compatibility
- Minimal dependencies (curl, jq, git, openssl)
