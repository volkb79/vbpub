# SSH Key Management - Quick Reference

## Naming Convention

```
Private Key: service-user-algorithm  (WHERE to connect TO)
Example:     netcup-hosting218629-ed25519

Public Key:  owner@hostname_YYYYMM   (WHO is connecting FROM)
Example:     vb@gstammtisch.dchive.de_202511
```

## Client Side - Generate & Deploy Key

```bash
# Edit configuration in script
vim scripts/generate-ssh-key-pair.sh

# Run interactively
./scripts/generate-ssh-key-pair.sh
```

## Server Side - Manual Setup

```bash
# Basic setup (interactive)
./scripts/setup-authorized-keys-server.sh root

# Generate key and send via Telegram
TELEGRAM_BOT_TOKEN=123:abc \
TELEGRAM_CHAT_ID=456 \
./scripts/setup-authorized-keys-server.sh --generate-key root
```

## Bootstrap Integration

### Full System Setup with SSH Key

```bash
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
TELEGRAM_BOT_TOKEN=<your-token> \
TELEGRAM_CHAT_ID=<your-chat-id> \
SETUP_SSH_ACCESS=yes \
SSH_ACCESS_USER=root \
bash
```

### Bootstrap Environment Variables

```bash
# Required for Telegram
TELEGRAM_BOT_TOKEN=123:abc
TELEGRAM_CHAT_ID=456

# SSH key generation
SETUP_SSH_ACCESS=yes        # Enable key generation
SSH_ACCESS_USER=root        # User for SSH access

# Other bootstrap options
DEBUG_MODE=yes
RUN_GEEKBENCH=yes
RUN_BENCHMARKS=yes
```

## Key Files & Permissions

```
~/.ssh/                                    (700)
├── authorized_keys                        (600)
├── server-access-hostname-ed25519         (600) - Private key
└── server-access-hostname-ed25519.pub     (644) - Public key
```

## Connect After Setup

### Quick Connect

```bash
# Download key from Telegram
chmod 600 server-access-hostname-ed25519

# Connect
ssh -i server-access-hostname-ed25519 root@hostname.example.com
```

### SSH Config

Add to `~/.ssh/config`:

```
Host myserver
    HostName hostname.example.com
    User root
    IdentityFile ~/.ssh/server-access-hostname-ed25519
```

Then: `ssh myserver`

## Troubleshooting

```bash
# Check key fingerprint
ssh-keygen -lf ~/.ssh/key-file.pub

# Test connection with verbose
ssh -v -i ~/.ssh/key-file user@host

# Check server authorized_keys
cat ~/.ssh/authorized_keys

# Check permissions
ls -la ~/.ssh/
```

## Security Checklist

- [ ] Private key has 600 permissions
- [ ] Public key added to authorized_keys
- [ ] Delete Telegram message after saving key
- [ ] Test connection before disabling password auth
- [ ] Disable password auth after key works
- [ ] Consider key rotation (annually)

## Common Commands

```bash
# Generate key manually
ssh-keygen -t ed25519 -C "user@host_202601" -f ~/.ssh/service-user-ed25519

# Copy key to server
ssh-copy-id -i ~/.ssh/key-file user@host

# Add key to agent
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/key-file

# List agent keys
ssh-add -l

# View public key
cat ~/.ssh/key-file.pub

# Calculate fingerprint
ssh-keygen -lf ~/.ssh/key-file.pub -E sha256
```

## Links

- [SSH_KEY_MANAGEMENT.md](../docs/SSH_KEY_MANAGEMENT.md) - Full guide
- [SSH_KEY_BOOTSTRAP.md](SSH_KEY_BOOTSTRAP.md) - Bootstrap integration
- [README_AUTH.md](README_AUTH.md) - GitHub authentication
