# Migration to ssh-keygen-deploy.py

Quick reference for migrating from shell scripts to the unified Python tool.

## Overview

The new `ssh-keygen-deploy.py` replaces:
- `generate-ssh-key-pair.sh` (client-side key generation)
- `setup-authorized-keys-server.sh` (server-side key setup)

## Quick Migration

### Server-Side (Bootstrap/Local)

**Old:**
```bash
TELEGRAM_BOT_TOKEN=123:abc \
TELEGRAM_CHAT_ID=456 \
NONINTERACTIVE=yes \
./setup-authorized-keys-server.sh --generate-key root
```

**New:**
```bash
TELEGRAM_BOT_TOKEN=123:abc \
TELEGRAM_CHAT_ID=456 \
./ssh-keygen-deploy.py --user root --send-private --non-interactive
```

### Client-Side (Remote Deployment)

**Old:**
```bash
# Edit variables in generate-ssh-key-pair.sh
ssh_comment='vb@gstammtisch.dchive.de_202511'
ssh_purpose='netcup-hosting218629-ed25519'
remote_conn='hosting218629@hosting218629.ae98d.netcup.net'

./generate-ssh-key-pair.sh
```

**New:**
```bash
./ssh-keygen-deploy.py \
  --remote hosting218629@hosting218629.ae98d.netcup.net \
  --key-owner vb \
  --key-hostname gstammtisch.dchive.de \
  --service netcup
```

## Command Comparison

| Old Script | Old Command | New Command |
|------------|-------------|-------------|
| setup-authorized-keys-server.sh | `--generate-key root` | `--user root --send-private` |
| setup-authorized-keys-server.sh | `--non-interactive` | `--non-interactive` |
| generate-ssh-key-pair.sh | Edit config + run | `--remote user@host --key-owner X --key-hostname Y` |

## Bootstrap Integration

### Old bootstrap.sh Integration

```bash
# SSH Access Key Generation (OLD)
if [ "$SETUP_SSH_ACCESS" = "yes" ]; then
    log_info "==> Generating SSH access key"
    SSH_ACCESS_USER="${SSH_ACCESS_USER:-root}"
    
    export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
    export NONINTERACTIVE=yes
    
    if "${SCRIPT_DIR}/../setup-authorized-keys-server.sh" \
        --generate-key "${SSH_ACCESS_USER}" 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ SSH access key generated and sent via Telegram"
    else
        log_warn "SSH access key generation had issues"
    fi
fi
```

### New bootstrap.sh Integration

```bash
# SSH Access Key Generation (NEW)
if [ "$SETUP_SSH_ACCESS" = "yes" ]; then
    log_info "==> Generating SSH access key"
    SSH_ACCESS_USER="${SSH_ACCESS_USER:-root}"
    
    export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
    
    if python3 "${SCRIPT_DIR}/../ssh-keygen-deploy.py" \
        --user "${SSH_ACCESS_USER}" \
        --send-private \
        --non-interactive 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ SSH access key generated and sent via Telegram"
    else
        log_warn "SSH access key generation had issues"
    fi
fi
```

## Advantages of New Tool

### 1. Unified Interface
- Single tool for both server and client modes
- Consistent command-line interface
- Better error handling

### 2. Flexibility
- Command-line options instead of editing scripts
- Support for both interactive and non-interactive modes
- Environment variable support

### 3. Better Integration
- Python-based (matches telegram_client.py)
- Easier to import and use from other Python tools
- More maintainable codebase

### 4. Enhanced Features
- Automatic hostname detection
- Better logging with timestamps
- Debug mode for troubleshooting
- Proper exit codes

## Environment Variables

Both old and new support these:

```bash
TELEGRAM_BOT_TOKEN=<token>
TELEGRAM_CHAT_ID=<chat-id>
NONINTERACTIVE=yes
```

The new tool adds:
```bash
USER=<default-user>  # Falls back to this for --user
```

## File Locations

### Generated Keys

**Local Mode:**
- Old: `/home/USER/.ssh/server-access-HOSTNAME-ed25519`
- New: `/home/USER/.ssh/server-access-HOSTNAME-ed25519` (same)

**Remote Mode:**
- Old: Custom path via `ssh_mounted_path` variable
- New: `/home/USER/.ssh/SERVICE-USER-ed25519`

### Key Names

Both use the same naming convention:
- Private key: Identifies WHERE to connect TO
- Public comment: Identifies WHO is connecting FROM

## Testing

### Test Local Mode

```bash
# Old
TELEGRAM_BOT_TOKEN=test TELEGRAM_CHAT_ID=123 \
./setup-authorized-keys-server.sh --generate-key testuser

# New
TELEGRAM_BOT_TOKEN=test TELEGRAM_CHAT_ID=123 \
./ssh-keygen-deploy.py --user testuser --send-private --non-interactive
```

### Test Remote Mode

```bash
# Old (edit script first)
./generate-ssh-key-pair.sh

# New
./ssh-keygen-deploy.py \
  --remote user@server.com \
  --key-owner myname \
  --key-hostname laptop
```

## Backward Compatibility

The old scripts will remain available for now:
- `generate-ssh-key-pair.sh` - Still works
- `setup-authorized-keys-server.sh` - Still works

But new deployments should use `ssh-keygen-deploy.py`.

## Common Patterns

### Pattern 1: Bootstrap Server Setup

```bash
# Complete bootstrap with SSH key
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
TELEGRAM_BOT_TOKEN=<token> \
TELEGRAM_CHAT_ID=<chat-id> \
SETUP_SSH_ACCESS=yes \
SSH_ACCESS_USER=root \
bash
```

### Pattern 2: Manual Server Setup

```bash
# Clone repo
git clone https://github.com/volkb79/vbpub.git /opt/vbpub

# Generate and send key
export TELEGRAM_BOT_TOKEN="<token>"
export TELEGRAM_CHAT_ID="<chat-id>"

python3 /opt/vbpub/scripts/ssh-keygen-deploy.py \
  --user root \
  --send-private \
  --non-interactive
```

### Pattern 3: Client Access Setup

```bash
# For accessing Netcup hosting
./ssh-keygen-deploy.py \
  --remote hosting218629@hosting218629.ae98d.netcup.net \
  --key-owner vb \
  --key-hostname workstation \
  --service netcup

# For accessing GitHub
./ssh-keygen-deploy.py \
  --remote git@github.com \
  --key-owner vb \
  --key-hostname laptop \
  --service github
```

### Pattern 4: Automated CI/CD

```bash
# No passphrase, deploy to production
./ssh-keygen-deploy.py \
  --remote deploy@prod.example.com \
  --key-owner ci-bot \
  --key-hostname github-actions \
  --service production \
  --non-interactive
```

## Rollback

If you need to rollback to shell scripts:

```bash
# The old scripts are still available
cd /opt/vbpub/scripts

# Server mode
./setup-authorized-keys-server.sh --generate-key root

# Client mode (edit first)
vim generate-ssh-key-pair.sh
./generate-ssh-key-pair.sh
```

## Questions?

See the full documentation:
- [README_SSH_KEYGEN_DEPLOY.md](README_SSH_KEYGEN_DEPLOY.md) - Complete guide
- [SSH_KEY_MANAGEMENT.md](../docs/SSH_KEY_MANAGEMENT.md) - Naming conventions and best practices
