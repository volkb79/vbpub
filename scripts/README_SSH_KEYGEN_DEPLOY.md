# SSH Key Generation and Deployment Tool

Unified Python tool for generating and deploying SSH keys in both local (server) and remote (client) modes.

## Overview

`ssh-keygen-deploy.py` replaces the previous shell scripts (`generate-ssh-key-pair.sh` and `setup-authorized-keys-server.sh`) with a single, flexible Python tool that supports:

- **Local Mode (Server)**: Generate keys and install locally, optionally sending private key via Telegram
- **Remote Mode (Client)**: Generate keys locally and deploy to remote server
- **Bootstrap Integration**: Non-interactive mode for automated system provisioning
- **Standalone Usage**: Interactive mode for manual key management

## Quick Start

### Local Server Mode (Bootstrap)

```bash
# Generate key, install locally, send private key via Telegram
./ssh-keygen-deploy.py --user root --send-private

# With Telegram credentials
TELEGRAM_BOT_TOKEN=123:abc \
TELEGRAM_CHAT_ID=456 \
./ssh-keygen-deploy.py --user root --send-private --non-interactive
```

### Remote Client Mode

```bash
# Generate key and deploy to remote server
./ssh-keygen-deploy.py \
  --remote user@server.example.com \
  --key-owner myname \
  --key-hostname laptop

# With custom service name
./ssh-keygen-deploy.py \
  --remote hosting218629@hosting218629.ae98d.netcup.net \
  --key-owner vb \
  --key-hostname workstation \
  --service netcup
```

## Command-Line Options

### Mode Selection

- `--remote USER@HOST` - Deploy to remote server (client mode). Without this, runs in local mode.

### Key Configuration

- `--user USER` - Local user for .ssh directory (default: $USER or root)
- `--key-owner OWNER` - Owner identifier for public key comment
  - Default: "client" (local mode) or username (remote mode)
- `--key-hostname HOSTNAME` - Hostname/context for key comment (default: auto-detected)
- `--service SERVICE` - Service identifier for key filename (default: "server")
- `--algorithm ALGO` - Key algorithm: ed25519 (default), rsa, ecdsa
- `--key-path PATH` - Custom .ssh directory (default: /home/USER/.ssh)

### Telegram Integration

- `--send-private` - Send private key via Telegram (local mode only)
- `--telegram-token TOKEN` - Bot token (or use TELEGRAM_BOT_TOKEN env)
- `--telegram-chat-id ID` - Chat ID (or use TELEGRAM_CHAT_ID env)

### Behavior

- `--non-interactive` - Non-interactive mode (no prompts)
- `--debug` - Enable debug logging

## Usage Examples

### 1. Bootstrap Integration (Automated Server Setup)

```bash
# From bootstrap.sh
export TELEGRAM_BOT_TOKEN="<token>"
export TELEGRAM_CHAT_ID="<chat-id>"

/opt/vbpub/scripts/ssh-keygen-deploy.py \
  --user root \
  --send-private \
  --non-interactive
```

### 2. Manual Server Setup

```bash
# Interactive (will prompt for confirmations)
./ssh-keygen-deploy.py --user root --send-private

# With custom owner
./ssh-keygen-deploy.py \
  --user admin \
  --key-owner ops-team \
  --send-private
```

### 3. Client Key for Remote Access

```bash
# Interactive (will prompt for passphrase)
./ssh-keygen-deploy.py \
  --remote root@server.example.com \
  --key-owner myname \
  --key-hostname mylaptop

# For Netcup hosting
./ssh-keygen-deploy.py \
  --remote hosting218629@hosting218629.ae98d.netcup.net \
  --key-owner vb \
  --key-hostname gstammtisch \
  --service netcup
```

### 4. Non-Interactive Remote Deployment

```bash
# Useful for automation (generates key without passphrase)
./ssh-keygen-deploy.py \
  --remote user@server.com \
  --key-owner automation \
  --key-hostname ci-server \
  --non-interactive
```

## Naming Convention

The tool follows the established naming convention:

### Local Mode (Server)

**Private Key:** `server-access-<hostname>-<algorithm>`
- Example: `server-access-hosting218629-ed25519`
- Identifies the server this key grants access TO

**Public Key Comment:** `<owner>@<hostname>_<YYYYMM>`
- Example: `client@hosting218629.ae98d.netcup.net_202601`
- Identifies WHO will use this key (future clients)

### Remote Mode (Client)

**Private Key:** `<service>-<user>-<algorithm>`
- Example: `netcup-hosting218629-ed25519`
- Identifies the service/server to connect TO

**Public Key Comment:** `<owner>@<hostname>_<YYYYMM>`
- Example: `vb@gstammtisch.dchive.de_202601`
- Identifies WHO owns this key (this client)

## Bootstrap Integration

### Add to bootstrap.sh

Add this section after system configuration:

```bash
# SSH Access Key Generation
SETUP_SSH_ACCESS="${SETUP_SSH_ACCESS:-no}"
SSH_ACCESS_USER="${SSH_ACCESS_USER:-root}"

if [ "$SETUP_SSH_ACCESS" = "yes" ]; then
    log_info "==> Generating SSH access key"
    
    export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
    
    if python3 "${SCRIPT_DIR}/../ssh-keygen-deploy.py" \
        --user "${SSH_ACCESS_USER}" \
        --send-private \
        --non-interactive 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ SSH access key generated and sent via Telegram"
    else
        log_warn "SSH access key generation had issues"
    fi
else
    log_info "==> SSH access key generation skipped (SETUP_SSH_ACCESS=$SETUP_SSH_ACCESS)"
fi
```

### Bootstrap Environment Variables

```bash
# Enable SSH key generation
SETUP_SSH_ACCESS=yes

# User for SSH access (default: root)
SSH_ACCESS_USER=root

# Telegram credentials (required)
TELEGRAM_BOT_TOKEN=123:abc
TELEGRAM_CHAT_ID=456
```

### Complete Bootstrap Example

```bash
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
TELEGRAM_BOT_TOKEN=<token> \
TELEGRAM_CHAT_ID=<chat-id> \
SETUP_SSH_ACCESS=yes \
SSH_ACCESS_USER=root \
RUN_GEEKBENCH=yes \
bash
```

## Operation Modes

### Local Mode (--send-private)

1. Generate SSH key pair
2. Add public key to local authorized_keys
3. Send private key via Telegram
4. Client downloads and uses private key

**Use Case:** Server provisioning where clients are unknown

### Remote Mode (--remote)

1. Generate SSH key pair locally
2. Deploy public key to remote server (ssh-copy-id)
3. Add to local ssh-agent
4. Private key stays on client

**Use Case:** Client setting up access to known server

## Output

### Local Mode

```
[INFO] 2026-01-10 16:00:00 === Generating SSH Key Pair ===
[INFO] 2026-01-10 16:00:00 System:       hosting218629.ae98d.netcup.net
[INFO] 2026-01-10 16:00:00 Algorithm:    ed25519
[INFO] 2026-01-10 16:00:00 Comment:      client@hosting218629.ae98d.netcup.net_202601
[INFO] 2026-01-10 16:00:00 Private Key:  server-access-hosting218629-ed25519
[INFO] 2026-01-10 16:00:00 Public Key:   server-access-hosting218629-ed25519.pub
[INFO] 2026-01-10 16:00:01 Generating key pair (no passphrase for automated access)...
[INFO] 2026-01-10 16:00:01 ✓ Key pair generated successfully
[INFO] 2026-01-10 16:00:01 Adding public key to authorized_keys...
[INFO] 2026-01-10 16:00:01 ✓ Public key added to authorized_keys
[INFO] 2026-01-10 16:00:01 
[INFO] 2026-01-10 16:00:01 === Key Generation Complete ===
[INFO] 2026-01-10 16:00:01 Private Key: /root/.ssh/server-access-hosting218629-ed25519
[INFO] 2026-01-10 16:00:01 Public Key:  /root/.ssh/server-access-hosting218629-ed25519.pub
[INFO] 2026-01-10 16:00:01 Fingerprint (SHA256): SHA256:abc123...
[INFO] 2026-01-10 16:00:01 Fingerprint (MD5):    MD5:def456...
[INFO] 2026-01-10 16:00:02 
[INFO] 2026-01-10 16:00:02 === Sending Private Key via Telegram ===
[INFO] 2026-01-10 16:00:03 ✓ Message sent
[INFO] 2026-01-10 16:00:04 ✓ Private key sent
```

### Remote Mode

```
[INFO] 2026-01-10 16:00:00 === Generating SSH Key Pair ===
[INFO] 2026-01-10 16:00:00 Owner:           vb
[INFO] 2026-01-10 16:00:00 Context:         gstammtisch
[INFO] 2026-01-10 16:00:00 Target Service:  netcup
[INFO] 2026-01-10 16:00:00 Target User:     hosting218629
[INFO] 2026-01-10 16:00:00 Target Host:     hosting218629.ae98d.netcup.net
[INFO] 2026-01-10 16:00:00 Algorithm:       ed25519
[INFO] 2026-01-10 16:00:00 Private Key:     netcup-hosting218629-ed25519
[INFO] 2026-01-10 16:00:00 Public Comment:  vb@gstammtisch_202601
[INFO] 2026-01-10 16:00:01 
[INFO] 2026-01-10 16:00:01 === Generating Key Pair ===
[INFO] 2026-01-10 16:00:01 Enter passphrase when prompted (or press Enter for no passphrase)
Generating public/private ed25519 key pair.
Enter passphrase (empty for no passphrase): 
Enter same passphrase again: 
[INFO] 2026-01-10 16:00:05 ✓ Key pair generated successfully
[INFO] 2026-01-10 16:00:05 
[INFO] 2026-01-10 16:00:05 === Adding Key to SSH Agent ===
[INFO] 2026-01-10 16:00:05 ssh-agent already running
[INFO] 2026-01-10 16:00:06 ✓ Key added to ssh-agent
[INFO] 2026-01-10 16:00:06 
[INFO] 2026-01-10 16:00:06 === Deploying Public Key to Remote Server ===
[INFO] 2026-01-10 16:00:06 Target: hosting218629@hosting218629.ae98d.netcup.net
[INFO] 2026-01-10 16:00:06 
[INFO] 2026-01-10 16:00:06 Note: You will be prompted for the password on first connection
...
[INFO] 2026-01-10 16:00:10 
[INFO] 2026-01-10 16:00:10 ✓ Public key deployed successfully
```

## Features

### Automatic Detection

- **Hostname**: Uses `socket.getfqdn()` for FQDN
- **IP Address**: Detects primary IP via `hostname -I`
- **User**: Uses `--user` arg or $USER environment variable

### Security

- **Local mode**: Keys generated without passphrase (for automated access)
- **Remote mode**: Prompts for passphrase (secure client keys)
- **Non-interactive mode**: Skips passphrase in both modes
- **Proper permissions**: 600 (private), 644 (public), 700 (.ssh directory)
- **Ownership**: Sets correct user:group when run as root
- **Telegram**: Encrypted transmission, includes security warnings

### Error Handling

- **Key exists**: Prompts to overwrite (interactive) or exits (non-interactive)
- **Missing Telegram**: Warns but continues
- **Command failures**: Proper error messages and exit codes
- **Timeout protection**: 30-second timeout on subprocess calls

### Validation

- **Key format**: Validates generated keys
- **Fingerprints**: SHA256 and MD5 for verification
- **Connection test**: Optional SSH connection test (remote mode)
- **Backup**: Creates backup of existing authorized_keys

## Dependencies

**Required:**
- Python 3.6+
- OpenSSH client tools (ssh-keygen, ssh-copy-id, ssh-add)

**Optional:**
- telegram_client.py (for Telegram notifications)
- Python requests library (for Telegram)

## Environment Variables

- `TELEGRAM_BOT_TOKEN` - Telegram bot token
- `TELEGRAM_CHAT_ID` - Telegram chat ID
- `NONINTERACTIVE` - Skip prompts (yes/no)
- `USER` - Default user for .ssh directory

## Exit Codes

- `0` - Success
- `1` - General error
- `130` - User cancelled (Ctrl+C)

## Troubleshooting

### Telegram not sending

```bash
# Test Telegram connectivity
python3 /opt/vbpub/scripts/debian-install/telegram_client.py --test

# Check environment variables
echo $TELEGRAM_BOT_TOKEN
echo $TELEGRAM_CHAT_ID

# Run with debug
./ssh-keygen-deploy.py --user root --send-private --debug
```

### Permission denied

```bash
# Check file permissions
ls -la ~/.ssh/

# Fix permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chmod 600 ~/.ssh/private-key-file
```

### ssh-copy-id fails

```bash
# Ensure password authentication is enabled on remote
ssh user@host

# Try manual copy
cat ~/.ssh/key.pub | ssh user@host 'cat >> ~/.ssh/authorized_keys'
```

### Key already exists

```bash
# Remove existing key
rm ~/.ssh/existing-key ~/.ssh/existing-key.pub

# Or use different service name
./ssh-keygen-deploy.py --service myservice-v2 ...
```

## Migration from Shell Scripts

Old shell scripts can be replaced:

**Old:**
```bash
./generate-ssh-key-pair.sh
./setup-authorized-keys-server.sh --generate-key root
```

**New:**
```bash
./ssh-keygen-deploy.py --remote user@host --key-owner name --key-hostname laptop
./ssh-keygen-deploy.py --user root --send-private
```

## Related Files

- [telegram_client.py](debian-install/telegram_client.py) - Telegram integration
- [bootstrap.sh](debian-install/bootstrap.sh) - System provisioning
- [SSH_KEY_MANAGEMENT.md](../docs/SSH_KEY_MANAGEMENT.md) - Detailed guide

## License

Part of the vbpub repository. See main README for license information.
