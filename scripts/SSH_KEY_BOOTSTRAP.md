# SSH Key Generation Integration

## Overview

The `setup-authorized-keys-server.sh` script has been enhanced to work seamlessly with the bootstrap system post-install process. It can now automatically generate SSH keys and securely deliver private keys via Telegram.

## Features

- **Non-interactive mode**: Runs without user prompts during system setup
- **Key generation**: Creates ed25519 SSH key pairs automatically  
- **Telegram delivery**: Securely sends private key to admin via Telegram
- **Auto-detection**: Uses server hostname for key naming
- **Integration ready**: Works with existing bootstrap.sh workflow

## Usage Modes

### Mode 1: Standard Setup (Manual Key Addition)

Basic authorized_keys configuration without key generation:

```bash
./setup-authorized-keys-server.sh root
```

### Mode 2: Generate Key & Send via Telegram

Automatically generate a key pair and send private key via Telegram:

```bash
TELEGRAM_BOT_TOKEN=123123:asdasdasd \
TELEGRAM_CHAT_ID=123123123 \
./setup-authorized-keys-server.sh --generate-key root
```

### Mode 3: Bootstrap Integration (Recommended)

Integrate with system post-install via bootstrap.sh:

```bash
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
DEBUG_MODE=yes \
TELEGRAM_BOT_TOKEN=123123:asdasdasdasdasdasd \
TELEGRAM_CHAT_ID=123123123 \
SETUP_SSH_ACCESS=yes \
SSH_ACCESS_USER=root \
bash
```

## Bootstrap Integration

### Add to bootstrap.sh

Add the following section to your bootstrap.sh script after the system setup is complete:

```bash
# SSH Access Key Generation
if [ "$SETUP_SSH_ACCESS" = "yes" ]; then
    log_info "==> Generating SSH access key"
    SSH_ACCESS_USER="${SSH_ACCESS_USER:-root}"
    
    export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
    export NONINTERACTIVE=yes
    
    if "${SCRIPT_DIR}/../setup-authorized-keys-server.sh" --generate-key "${SSH_ACCESS_USER}" 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ SSH access key generated and sent via Telegram"
    else
        log_warn "SSH access key generation had issues"
    fi
else
    log_info "==> SSH access key generation skipped (SETUP_SSH_ACCESS=$SETUP_SSH_ACCESS)"
fi
```

### Environment Variables

Add these to bootstrap.sh configuration section:

```bash
# SSH Access Key Generation
SETUP_SSH_ACCESS="${SETUP_SSH_ACCESS:-no}"     # Generate and send SSH key via Telegram
SSH_ACCESS_USER="${SSH_ACCESS_USER:-root}"     # User account for SSH access
```

## Complete Bootstrap Example

```bash
#!/bin/bash
# Complete system setup with SSH key generation

curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
DEBUG_MODE=yes \
TELEGRAM_BOT_TOKEN=7123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw \
TELEGRAM_CHAT_ID=123456789 \
REPO_BRANCH=main \
RUN_GEEKBENCH=yes \
RUN_BENCHMARKS=yes \
BENCHMARK_DURATION=5 \
SETUP_SSH_ACCESS=yes \
SSH_ACCESS_USER=root \
SWAP_RAM_SOLUTION=auto \
SWAP_DISK_TOTAL_GB=auto \
bash
```

## Key Naming Convention

Generated keys follow a consistent naming pattern:

**Private Key Filename:**
- Format: `server-access-<hostname>-<algorithm>`
- Example: `server-access-hosting218629-ed25519`

**Public Key Comment:**
- Format: `client@<fqdn>_<YYYYMM>`
- Example: `client@hosting218629.ae98d.netcup.net_202601`

This follows the established convention where:
- **Filename** identifies where to connect TO (the server)
- **Comment** identifies WHO is connecting FROM (future clients)

## Telegram Message Format

When a key is generated, the following is sent via Telegram:

```
🔑 SSH Server Access Key Generated

System: hosting218629.ae98d.netcup.net
User: root
Algorithm: ed25519

⚠️ SECURITY NOTICE
This private key grants SSH access to this server.
Treat it as a password and store securely.

Usage Instructions:
1. Save the attached file securely
2. Set permissions: chmod 600 server-access-hosting218629-ed25519
3. Connect: ssh -i server-access-hosting218629-ed25519 root@hosting218629.ae98d.netcup.net

Fingerprints for Verification:
SHA256: SHA256:abc123...
MD5: MD5:def456...

Add to ~/.ssh/config:
Host hosting218629
    HostName hosting218629.ae98d.netcup.net
    User root
    IdentityFile ~/.ssh/server-access-hosting218629-ed25519

Then connect with: ssh hosting218629
```

The private key file is attached to the message.

## Security Considerations

### Key Protection

- **No passphrase**: Keys are generated without passphrase for automated access
- **Secure transmission**: Private keys sent only via Telegram (encrypted)
- **Single use**: Intended for initial setup; rotate after first use
- **Delete after saving**: Remove Telegram message once key is saved locally

### Best Practices

1. **Save immediately**: Download private key from Telegram right away
2. **Set permissions**: `chmod 600 private-key-file` locally
3. **Delete message**: Remove from Telegram after saving
4. **Rotate key**: Generate new key-pair for production use
5. **Audit access**: Regularly review authorized_keys file

### Production Hardening

After initial setup and key verification:

```bash
# Disable password authentication
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
systemctl reload sshd

# Remove generated key (if using different keys for production)
rm /root/.ssh/server-access-*

# Use client-generated keys instead
./generate-ssh-key-pair.sh  # From client machine
```

## Client Connection

### Quick Connection

```bash
# Download key from Telegram and save as:
chmod 600 ~/Downloads/server-access-hosting218629-ed25519
mv ~/Downloads/server-access-hosting218629-ed25519 ~/.ssh/

# Connect
ssh -i ~/.ssh/server-access-hosting218629-ed25519 root@hosting218629.ae98d.netcup.net
```

### SSH Config Entry

Add to `~/.ssh/config`:

```
Host hosting218629
    HostName hosting218629.ae98d.netcup.net
    User root
    IdentityFile ~/.ssh/server-access-hosting218629-ed25519
    
Host hosting218629-prod
    HostName hosting218629.ae98d.netcup.net
    User root
    IdentityFile ~/.ssh/netcup-hosting218629-ed25519
```

Then connect with: `ssh hosting218629`

## Troubleshooting

### Key not sent via Telegram

**Check:**
1. TELEGRAM_BOT_TOKEN is set correctly
2. TELEGRAM_CHAT_ID is set correctly  
3. telegram_client.py is accessible
4. Network connectivity to Telegram API

**Debug:**
```bash
# Test Telegram connection
python3 /opt/vbpub/scripts/debian-install/telegram_client.py --test

# Run with debug
DEBUG_MODE=yes ./setup-authorized-keys-server.sh --generate-key root
```

### Permission denied after setup

**Check:**
1. Private key permissions: `chmod 600 private-key`
2. Server ~/.ssh permissions: `chmod 700 ~/.ssh`
3. Server authorized_keys: `chmod 600 ~/.ssh/authorized_keys`
4. Key is in authorized_keys: `cat ~/.ssh/authorized_keys`

### Key already exists

Script will skip generation if key exists. To regenerate:

```bash
# Remove existing key
rm /root/.ssh/server-access-*

# Generate new one
./setup-authorized-keys-server.sh --generate-key root
```

## Examples

### Manual server-side run

```bash
# Setup SSH directory and generate key
export TELEGRAM_BOT_TOKEN="123:abc"
export TELEGRAM_CHAT_ID="456"
export NONINTERACTIVE=yes

./setup-authorized-keys-server.sh --generate-key root
```

### Netcup VPS provisioning

```bash
# During netcup VPS creation, use this as init script:
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
TELEGRAM_BOT_TOKEN=<your-token> \
TELEGRAM_CHAT_ID=<your-chat-id> \
SETUP_SSH_ACCESS=yes \
SSH_ACCESS_USER=root \
bash
```

### Docker container setup

```bash
# For a container that needs SSH access
docker run -it debian:bookworm bash

# Inside container:
apt-get update && apt-get install -y curl python3 python3-requests openssh-server
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/setup-authorized-keys-server.sh | \
TELEGRAM_BOT_TOKEN=<token> \
TELEGRAM_CHAT_ID=<chat-id> \
NONINTERACTIVE=yes \
bash -s -- --generate-key root
```

## Related Documentation

- [SSH_KEY_MANAGEMENT.md](../docs/SSH_KEY_MANAGEMENT.md) - Complete SSH key management guide
- [README_AUTH.md](README_AUTH.md) - GitHub App authentication
- [bootstrap.sh](debian-install/bootstrap.sh) - System bootstrap script
- [telegram_client.py](debian-install/telegram_client.py) - Telegram notification client
