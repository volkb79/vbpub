# VB Scripts Collection

A comprehensive collection of development and automation scripts organized by purpose. This repository contains tools for GitHub App authentication, Docker Compose management, repository synchronization, and utility functions.

## 📁 Directory Structure

```
scripts/
├── github/          # GitHub App authentication and repository management
├── utils/           # General-purpose utilities and tools
├── docker/          # Docker and container-related scripts
└── legacy/          # Legacy scripts with unique functionality (7 scripts)
```

## 🚀 Quick Start

### GitHub App Authentication

```bash
# List GitHub App installations
github/list-installations --app-id 2030793 --verbose

# Synchronize repositories using GitHub App
github/app-sync --app-id 2030793 --verbose --force-clean

# Decode and analyze JWT tokens
echo "JWT_TOKEN" | utils/jwt-decode --validate --verbose
```

### Repository Management

```bash
# Clone specific subdirectory from repository
utils/subtree-checkout volkb79/DST-DNS projects/controller

# Interactive subtree selection
utils/subtree-checkout --repo DST-DNS
```

### Docker Operations

```bash
# Initialize and start Docker Compose services
compose-init-up.py --directory /path/to/project --verbose
```

## 📚 Script Documentation

### GitHub Tools (`github/`)

#### `github/app-sync` - Repository Synchronization
**Purpose:** Synchronizes multiple GitHub repositories using GitHub App authentication.

```bash
# Basic usage
github/app-sync --app-id 2030793

# Advanced usage with custom settings
github/app-sync --app-id 2030793 --directory /opt/repos --branch develop --verbose --force-clean --submodules

# Validate configuration
github/app-sync --validate --app-id 2030793 --verbose
```

**Key Features:**
- ✅ Automatic Installation ID discovery
- ✅ JWT generation and token management
- ✅ Robust error handling with detailed logging
- ✅ Parallel processing support (configurable)
- ✅ Submodule support
- ✅ Force clean option for dirty repositories
- ✅ Comprehensive configuration validation

**Options:**
- `--app-id ID`: GitHub App ID (required)
- `--installation-id ID`: Installation ID (auto-discovered if not set)
- `--directory DIR`: Base directory for repositories (default: ~/repos)
- `--branch BRANCH`: Target branch (default: main)
- `--submodules`: Include git submodules
- `--force-clean`: Clean working directories before pull
- `--verbose`: Enable detailed logging
- `--validate`: Configuration validation only

#### `github/list-installations` - Installation Discovery
**Purpose:** Discovers and analyzes GitHub App installations.

```bash
# List all installations
github/list-installations --app-id 2030793

# Detailed JSON output with repositories
github/list-installations --app-id 2030793 --format json --show-repos --permissions

# Quick summary for automation
github/list-installations --app-id 2030793 --format summary --quiet
```

**Key Features:**
- ✅ Multiple output formats (table, JSON, summary)
- ✅ Repository enumeration per installation
- ✅ Permission analysis and validation
- ✅ Specific installation filtering
- ✅ Authentication validation mode

**Output Formats:**
- `table`: Human-readable table format (default)
- `json`: Machine-readable JSON output
- `summary`: Compact one-line per installation

### Utility Tools (`utils/`)

#### `utils/jwt-decode` - JWT Token Analyzer
**Purpose:** Decodes and analyzes JSON Web Tokens for GitHub Apps.

```bash
# Decode JWT with validation
utils/jwt-decode --validate --verbose "eyJhbGciOiJSUzI1NiIs..."

# Extract only payload in JSON format
echo "JWT_TOKEN" | utils/jwt-decode --payload-only --quiet

# Table format with signature info
utils/jwt-decode --format table --signature-info "JWT_TOKEN"
```

**Key Features:**
- ✅ Complete JWT structure analysis
- ✅ Timestamp validation and human-readable dates
- ✅ Multiple output formats (JSON, YAML, table)
- ✅ GitHub App claim validation
- ✅ Base64url decoding with error handling
- ✅ Signature metadata analysis

**Validation Checks:**
- JWT structure (3 parts: header.payload.signature)
- Algorithm validation (RS256 required for GitHub Apps)
- Required claims presence (iss, iat, exp)
- Timestamp validation (not expired, reasonable lifetime)

#### `utils/subtree-checkout` - Repository Subtree Tool
**Purpose:** Efficiently checkout specific subdirectories from GitHub repositories.

```bash
# Interactive subtree selection
utils/subtree-checkout volkb79/DST-DNS

# Direct subtree download
utils/subtree-checkout volkb79/DST-DNS projects/controller --output /tmp/controller

# Use sparse checkout for large repositories
utils/subtree-checkout --method sparse-checkout volkb79/DST-DNS projects/controller
```

**Key Features:**
- ✅ Two checkout methods: download (API) and sparse-checkout (Git)
- ✅ Interactive subtree browser with search
- ✅ Support for private repositories (PAT authentication)
- ✅ Recursive directory scanning and listing
- ✅ Progress tracking and verbose logging
- ✅ Overwrite protection with confirmation

**Checkout Methods:**
- `download`: Fast API-based download (no Git history)
- `sparse-checkout`: Git-based with history preservation

### Docker Tools (`docker/`)

#### `compose-init-up.py` - Docker Compose Automation
**Purpose:** Automates Docker Compose initialization, environment setup, and service startup.

```bash
# Initialize and start services
compose-init-up.py --directory /path/to/project

# Generate environment configuration only
compose-init-up.py --env-only --file docker-compose.yml
```

**Key Features:**
- ✅ Automatic .env file generation from .env.sample
- ✅ Password generation and token prompting
- ✅ Docker Compose validation and image checking
- ✅ Host directory creation with proper permissions
- ✅ Pre-compose hook integration
- ✅ Comprehensive error handling and rollback

## 🔧 Configuration

### Environment Variables

Create or update your shell profile (`~/.zshrc`, `~/.bashrc`) with:

```bash
# GitHub App Configuration
export GITHUB_APP_ID="2030793"
export GITHUB_INSTALLATION_ID="88054503"  # Optional - auto-discovered
export GITHUB_APP_PRIVATE_KEY_PATH="$HOME/.ssh/github_app_key.pem"

# Default Repository Settings
export REPO_BASE_DIR="$HOME/repos"
export CHECKOUT_BRANCH="main"
export FETCH_SUBMODULES="false"
export FORCE_CLEAN="false"

# GitHub PAT for utils (if needed)
export GITHUB_PAT="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Default Repository Settings for Subtree Checkout
export DEFAULT_OWNER="volkb79"
export DEFAULT_REPO="DST-DNS"
```

### GitHub App Setup

1. **Create GitHub App:**
   - Go to GitHub Settings → Developer settings → GitHub Apps
   - Create new GitHub App with required permissions
   - Note the App ID (e.g., 2030793)

2. **Generate Private Key:**
   - In GitHub App settings → Private keys
   - Generate and download the private key (.pem file)
   - Place at `~/.ssh/github_app_key.pem` with 600 permissions

3. **Install GitHub App:**
   - Install the app on your account/organization
   - Select repositories or grant access to all repositories
   - Installation ID will be auto-discovered by scripts

### Private Key Security

```bash
# Set proper permissions
chmod 600 ~/.ssh/github_app_key.pem

# Verify key format
openssl rsa -in ~/.ssh/github_app_key.pem -check -noout

# Test key with GitHub
github/list-installations --app-id 2030793 --validate --verbose
```

## 🔍 Troubleshooting

### Common Issues

#### Authentication Errors
```bash
# Problem: "Integration not found" or "Authentication failed"
# Solution: Verify App ID and private key match

# Check JWT generation
github/list-installations --validate --verbose --app-id YOUR_APP_ID

# Decode generated JWT to verify claims
github/generate-jwt --app-id YOUR_APP_ID | utils/jwt-decode --validate --verbose
```

#### Repository Access Issues
```bash
# Problem: "Repository not found" or "Permission denied"
# Solution: Check GitHub App installation and permissions

# List accessible repositories
github/list-installations --app-id YOUR_APP_ID --show-repos --verbose

# Verify repository permissions in GitHub App settings
```

#### Network/API Issues
```bash
# Problem: Network timeouts or API rate limits
# Solution: Check connectivity and API status

# Test GitHub API connectivity
curl -H "Accept: application/vnd.github+json" https://api.github.com/zen

# Check API rate limits
curl -H "Authorization: Bearer YOUR_TOKEN" https://api.github.com/rate_limit
```

### Debug Mode

All scripts support verbose logging for troubleshooting:

```bash
# Enable maximum verbosity
github/app-sync --verbose --app-id 2030793

# Check configuration without executing
github/app-sync --validate --verbose --app-id 2030793

# Debug JWT tokens
echo "JWT" | utils/jwt-decode --validate --verbose --format table
```

### Log Analysis

Scripts provide structured logging with severity levels:

```bash
[2025-10-01 01:23:45] [INFO] Configuration validation passed
[2025-10-01 01:23:46] [VERBOSE] JWT generated successfully (522 chars)
[2025-10-01 01:23:47] [ERROR] Repository not found: volkb79/invalid-repo
```

## 📖 Exit Codes

All scripts follow consistent exit code conventions:

- `0`: Success - operation completed successfully
- `1`: Configuration error - invalid arguments, missing files, or dependencies
- `2`: Authentication error - JWT generation, token validation, or API access failed
- `3`: Resource error - repository/installation not found, permission denied
- `4`: Operation error - specific operation failed (subtree not found, sync failure)

## 🔗 Dependencies

### System Requirements
- **Bash 4.0+**: For modern shell features and error handling
- **Git 2.20+**: Required for repository operations and sparse-checkout
- **curl**: HTTP requests to GitHub API
- **jq**: JSON parsing and manipulation
- **openssl**: Cryptographic operations for JWT signing
- **base64**: Base64 encoding/decoding operations

### Python Dependencies (for Python scripts)
```bash
# Install Python dependencies
pip install requests

# For Docker compose script (if using advanced features)
pip install docker-compose pyyaml
```

### Installation Verification
```bash
# Check all dependencies
for cmd in bash git curl jq openssl base64 python3; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "✓ $cmd: $(command -v "$cmd")"
    else
        echo "✗ $cmd: Not found"
    fi
done
```

## 🛠️ Development

### Script Standards

All scripts follow these conventions:

1. **Comprehensive Documentation:** Extensive header documentation with purpose, usage, examples, and troubleshooting
2. **Argument Parsing:** Robust command-line argument handling with `--help` and validation
3. **Error Handling:** Strict error handling with meaningful messages and appropriate exit codes
4. **Logging:** Structured logging with verbosity control and consistent formatting
5. **Security:** Secure credential handling, input validation, and permission checking

### Adding New Scripts

When adding new scripts to this collection:

1. **Choose Appropriate Directory:** Place in `github/`, `utils/`, or `docker/` based on purpose
2. **Follow Naming Convention:** Use lowercase with hyphens (kebab-case)
3. **Add Comprehensive Header:** Include all standard documentation sections
4. **Implement Standard Options:** Support `--help`, `--verbose`, `--quiet` at minimum
5. **Update This README:** Add documentation and examples for the new script

### Testing Scripts

```bash
# Test argument parsing
script-name --help

# Test configuration validation
script-name --validate --verbose

# Test with minimal arguments
script-name --required-arg value

# Test error conditions
script-name --invalid-option
```

## 📋 Migration from Legacy Scripts

The `scripts/` directory contains legacy scripts that are being reorganized:

### Migration Status

- ✅ **Migrated and Legacy Deleted:**
  - `github_app_sync.sh` → `github/app-sync` (enhanced) ~~deleted~~
  - `get_installation_id.sh` → `github/list-installations` (enhanced) ~~deleted~~
  - `decode_jwt.sh` → `utils/jwt-decode` (enhanced) ~~deleted~~
  - `test_jwt.sh` → functionality in `utils/jwt-decode` ~~deleted~~
  - `checkout_subtree.py` → `utils/subtree-checkout` (enhanced) ~~deleted~~
  
- ✅ **Migrated to `docker/`:**
  - `docker/compose-init` → `compose-init-up.py` (canonical)

- � **Legacy Scripts (unique functionality, kept):**
  - `git-credential-github-app` - Git credential helper
  - `setup_github_app_auth.sh` - Authentication setup
  - `convert_to_github_app.sh` - Repository conversion
  - `convert_to_ssh.sh` - SSH conversion
  - `github_app_config.sh` - Configuration management
  - `switch_to_writeable_app.sh` - App switching
  - `install_gcm_latest.sh` - Git Credential Manager installer

### Using New Scripts

Replace legacy script calls:

```bash
# Old usage
./github_app_sync.sh

# New usage
github/app-sync --app-id 2030793

# Old usage
./get_installation_id.sh

# New usage  
github/list-installations --app-id 2030793
```

---

## 🔧 Debian Install Tools (`debian-install/`)

### Comprehensive Swap Configuration Toolkit

A complete toolkit for configuring and optimizing swap on Debian 12/13 systems with support for multiple architectures including ZRAM, ZSWAP, swap files, and ZFS zvol configurations.

#### Features

- **7 Architecture Options:**
  1. ZRAM Only (memory-only compression)
  2. ZRAM + Swap Files (two-tier)
  3. ZSWAP + Swap Files (recommended, single compression)
  4. Swap Files Only (no compression)
  5. ZFS Compressed Swap (zvol)
  6. ZRAM + ZFS zvol (double compression)
  7. Compressed Swap File Alternatives (experimental)

- **Intelligent Configuration:**
  - Automatic system detection (RAM, disk, CPU, storage type)
  - Dynamic sizing based on available resources
  - Default 8 swap files for optimal concurrency
  - SSD vs HDD optimizations

- **Comprehensive Monitoring:**
  - Real-time swap and memory monitoring
  - Correct metrics: pgmajfault, ZSWAP writeback ratio, PSI
  - Color-coded alerts for pressure indicators
  - Per-process swap usage tracking

- **Performance Testing:**
  - Benchmark different block sizes
  - Test compression algorithms (lz4, zstd, lzo-rle)
  - Test allocators (zsmalloc, z3fold, zbud)
  - Compare ZRAM vs ZSWAP performance

#### Quick Start

**Netcup Bootstrap (<10KB):**

```bash
# Minimal bootstrap for VPS initialization
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | bash

# Or with custom configuration
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
  SWAP_ARCH=3 SWAP_TOTAL_GB=16 SWAP_FILES=8 bash
```

**Full Installation:**

```bash
cd scripts/debian-install

# Analyze your system first
./analyze-memory.sh

# Run setup with defaults (ZSWAP + Swap Files, 8 files)
sudo ./setup-swap.sh

# Or customize
sudo SWAP_ARCH=3 SWAP_TOTAL_GB=16 SWAP_FILES=8 ./setup-swap.sh
```

#### Script Reference

| Script | Purpose |
|--------|---------|
| `README.md` | User guide and quick start |
| `SWAP_ARCHITECTURE.md` | Technical deep-dive documentation |
| `bootstrap.sh` | Minimal bootstrap (<10KB for netcup) |
| `setup-swap.sh` | Main installation orchestrator |
| `analyze-memory.sh` | Pre-installation system analysis |
| `benchmark.py` | Performance testing |
| `swap-monitor.sh` | Real-time monitoring with correct metrics |
| `sysinfo-notify.py` | System info and Telegram notifications |
| `ksm-trial.sh` | KSM effectiveness testing |

#### Key Technical Points

- **SWAP_TOTAL_GB / SWAP_FILES = per-file size** for concurrent I/O
- **Default 8 swap files** for optimal concurrency
- **vm.page-cluster controls I/O size, NOT striping** (round-robin across equal-priority devices)
- **ZRAM same_pages only zero-filled pages** (not arbitrary identical content)
- **ZSWAP single compression** vs ZRAM decompress→recompress inefficiency
- **Monitoring metrics:** pgmajfault (actual disk I/O), writeback ratio, PSI (pressure stall information)
- **vmstat si is MISLEADING** - includes ZSWAP RAM hits, not just disk I/O!
- **KSM requires MADV_MERGEABLE** - most apps don't use it, typically ineffective

#### Telegram Notifications

Optional Telegram integration for deployment notifications:

```bash
export TELEGRAM_BOT_TOKEN="110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
export TELEGRAM_CHAT_ID="123456789"

# Test configuration
./sysinfo-notify.py --test-mode

# Send system info
./sysinfo-notify.py --notify
```

**CRITICAL:** Send a message to your bot first before it can message you! Use @userinfobot or @getidsbot to get your chat ID.

#### Post-Installation

```bash
# Monitor swap status
./swap-monitor.sh

# Single snapshot
./swap-monitor.sh --once

# JSON output
./swap-monitor.sh --json

# Benchmark performance
sudo ./benchmark.py --test-all

# Test KSM effectiveness
sudo ./ksm-trial.sh
```

#### Architecture Selection Guide

- **1-2GB RAM:** ZSWAP + Swap Files with zstd compression
- **Limited disk (<30GB):** ZRAM Only
- **General purpose:** ZSWAP + Swap Files (arch 3, recommended)
- **ZFS systems:** ZFS Compressed Swap (arch 5)
- **Maximum speed:** ZRAM Only (arch 1)

See `debian-install/README.md` for comprehensive documentation and `debian-install/SWAP_ARCHITECTURE.md` for technical details.

---

## 📞 Support

For issues, questions, or contributions:

1. **Check Documentation:** Comprehensive help available with `--help` flag
2. **Enable Verbose Logging:** Use `--verbose` for detailed troubleshooting information  
3. **Validate Configuration:** Use `--validate` options to check setup
4. **Review Exit Codes:** Check exit codes for error classification
5. **Consult Troubleshooting:** Reference the troubleshooting section above

**Script Versions:**
- `github/app-sync`: v2.0.0
- `github/list-installations`: v1.0.0
- `utils/jwt-decode`: v1.0.0  
- `utils/subtree-checkout`: v2.0.0
- `docker/compose-init`: v2.0.0
- `debian-install`: v1.0.0

All scripts are designed for production use with comprehensive error handling, security considerations, and extensive documentation.