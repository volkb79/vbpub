# SSH Key Management Scripts

Comprehensive SSH key generation, deployment, and management tools with bootstrap integration and Telegram delivery.

## Quick Start

### For Clients (Generate & Deploy Keys)

```bash
# Edit configuration
vim scripts/generate-ssh-key-pair.sh

# Run script
./scripts/generate-ssh-key-pair.sh
```

### For Servers (Bootstrap Integration)

```bash
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
TELEGRAM_BOT_TOKEN=<your-token> \
TELEGRAM_CHAT_ID=<your-chat-id> \
SETUP_SSH_ACCESS=yes \
SSH_ACCESS_USER=root \
bash
```

## Scripts

### 1. `generate-ssh-key-pair.sh` (Client Side)
Interactive script for generating SSH keys on client machines and deploying to remote servers.

**Features:**
- Guided key generation with proper naming
- Automatic ssh-agent configuration
- Public key deployment via ssh-copy-id
- Connection testing
- SSH config generation

**Usage:**
```bash
./scripts/generate-ssh-key-pair.sh
```

### 2. `setup-authorized-keys-server.sh` (Server Side)
Server-side script for configuring SSH key authentication with optional automatic key generation.

**Features:**
- Standard authorized_keys setup
- Automatic SSH key generation (`--generate-key`)
- Non-interactive mode for automation
- Telegram integration for key delivery
- Interactive key addition (paste/import)

**Usage:**
```bash
# Interactive setup
./scripts/setup-authorized-keys-server.sh root

# Generate key and send via Telegram
TELEGRAM_BOT_TOKEN=123:abc \
TELEGRAM_CHAT_ID=456 \
./scripts/setup-authorized-keys-server.sh --generate-key root

# Non-interactive (for bootstrap)
NONINTERACTIVE=yes \
TELEGRAM_BOT_TOKEN=123:abc \
TELEGRAM_CHAT_ID=456 \
./scripts/setup-authorized-keys-server.sh --generate-key root
```

## Naming Convention

**Private Key Filename:** `<service>-<user>-<algorithm>`
- Example: `netcup-hosting218629-ed25519`
- Purpose: Identifies WHERE to connect TO

**Public Key Comment:** `<owner>@<hostname>_<YYYYMM>`
- Example: `vb@gstammtisch.dchive.de_202511`
- Purpose: Identifies WHO is connecting FROM

## Bootstrap Integration

### Environment Variables

```bash
# Required for Telegram
TELEGRAM_BOT_TOKEN=<bot-token>
TELEGRAM_CHAT_ID=<chat-id>

# SSH key generation (add to bootstrap.sh)
SETUP_SSH_ACCESS=yes              # Enable automatic key generation
SSH_ACCESS_USER=root              # User for SSH access
```

### Complete Example

```bash
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
DEBUG_MODE=yes \
TELEGRAM_BOT_TOKEN=7123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw \
TELEGRAM_CHAT_ID=123456789 \
SETUP_SSH_ACCESS=yes \
SSH_ACCESS_USER=root \
RUN_GEEKBENCH=yes \
RUN_BENCHMARKS=yes \
bash
```

## Generated Keys

When using `--generate-key`, the script creates:

1. **Private key**: `/home/USER/.ssh/server-access-HOSTNAME-ed25519`
2. **Public key**: `/home/USER/.ssh/server-access-HOSTNAME-ed25519.pub`
3. **Telegram message**: Formatted instructions with fingerprints
4. **Telegram attachment**: Private key file

## Documentation

- **[SSH_KEY_MANAGEMENT.md](../docs/SSH_KEY_MANAGEMENT.md)** - Complete guide
  - Naming conventions explained
  - Best practices
  - Security recommendations
  - Troubleshooting

- **[SSH_KEY_BOOTSTRAP.md](SSH_KEY_BOOTSTRAP.md)** - Bootstrap integration
  - Integration instructions
  - Environment variables
  - Usage examples
  - Security considerations

- **[SSH_QUICK_REF.md](SSH_QUICK_REF.md)** - Quick reference
  - Common commands
  - Quick examples
  - Troubleshooting tips

- **[SSH_UPDATE_SUMMARY.md](SSH_UPDATE_SUMMARY.md)** - Update summary
  - What changed
  - New features
  - Testing notes

## Workflow

### Server Provisioning

1. **Bootstrap runs** on new server
2. **Script generates** SSH key pair
3. **Public key** added to authorized_keys
4. **Private key** sent via Telegram
5. **Admin receives** key with instructions
6. **Admin saves** key locally
7. **Admin connects** using key

### Client Setup

1. **Edit configuration** in script
2. **Run script** interactively
3. **Enter passphrase** when prompted
4. **Public key** deployed automatically
5. **Connection tested**
6. **SSH config** generated

## Security

### Key Protection
- Private keys generated with 600 permissions
- No passphrase for server-generated keys (automated access)
- Passphrase required for client-generated keys
- Secure transmission via Telegram (encrypted)
- Delete Telegram message after saving

### Best Practices
- Rotate keys annually
- Audit authorized_keys regularly
- Remove unused keys promptly
- Disable password auth after keys work
- Use key comments for tracking

## Examples

### Netcup VPS Provisioning

```bash
# Add to Netcup init script
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
TELEGRAM_BOT_TOKEN=<token> \
TELEGRAM_CHAT_ID=<chat-id> \
SETUP_SSH_ACCESS=yes \
bash
```

### Manual Server Setup

```bash
# Clone repo
git clone https://github.com/volkb79/vbpub.git /opt/vbpub

# Generate key
export TELEGRAM_BOT_TOKEN="<token>"
export TELEGRAM_CHAT_ID="<chat-id>"
export NONINTERACTIVE=yes

/opt/vbpub/scripts/setup-authorized-keys-server.sh --generate-key root
```

### Client Connection

```bash
# Download key from Telegram
chmod 600 ~/Downloads/server-access-hostname-ed25519
mv ~/Downloads/server-access-hostname-ed25519 ~/.ssh/

# Connect
ssh -i ~/.ssh/server-access-hostname-ed25519 root@hostname.example.com

# Or add to ~/.ssh/config
cat >> ~/.ssh/config << EOF
Host myserver
    HostName hostname.example.com
    User root
    IdentityFile ~/.ssh/server-access-hostname-ed25519
EOF

# Then connect simply
ssh myserver
```

## Troubleshooting

### Permission Denied

```bash
# Check key permissions
chmod 600 ~/.ssh/private-key

# Check server .ssh directory
ssh user@host "chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"

# Test with verbose
ssh -v -i ~/.ssh/key user@host
```

### Key Not Sent via Telegram

```bash
# Test Telegram connection
python3 /opt/vbpub/scripts/debian-install/telegram_client.py --test

# Check environment variables
echo $TELEGRAM_BOT_TOKEN
echo $TELEGRAM_CHAT_ID

# Run with debug
DEBUG_MODE=yes ./setup-authorized-keys-server.sh --generate-key root
```

### Agent Failure

```bash
# Start ssh-agent
eval "$(ssh-agent -s)"

# Add key
ssh-add ~/.ssh/private-key

# List loaded keys
ssh-add -l
```

## Related Tools

- **[bootstrap.sh](debian-install/bootstrap.sh)** - System post-install
- **[telegram_client.py](debian-install/telegram_client.py)** - Telegram notifications
- **[README_AUTH.md](README_AUTH.md)** - GitHub App authentication
- **[generate-test-certs.sh](generate-test-certs.sh)** - Certificate generation

## License

Part of the vbpub repository. See main README for license information.
