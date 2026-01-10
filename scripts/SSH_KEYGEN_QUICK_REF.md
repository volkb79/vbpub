# ssh-keygen-deploy.py - Quick Reference

## Modes

```bash
# LOCAL MODE (Server): Generate key, install locally, send via Telegram
./ssh-keygen-deploy.py --user root --send-private

# REMOTE MODE (Client): Generate key, deploy to remote server
./ssh-keygen-deploy.py --remote user@server.com --key-owner name --key-hostname laptop
```

## Common Commands

### Bootstrap (Automated Server Setup)

```bash
# From bootstrap.sh
python3 ssh-keygen-deploy.py --user root --send-private --non-interactive
```

### Server Manual Setup

```bash
# Interactive with Telegram
./ssh-keygen-deploy.py --user root --send-private

# Non-interactive
TELEGRAM_BOT_TOKEN=<token> TELEGRAM_CHAT_ID=<id> \
./ssh-keygen-deploy.py --user root --send-private --non-interactive
```

### Client to Netcup

```bash
./ssh-keygen-deploy.py \
  --remote hosting218629@hosting218629.ae98d.netcup.net \
  --key-owner vb \
  --key-hostname workstation \
  --service netcup
```

### Client to GitHub

```bash
./ssh-keygen-deploy.py \
  --remote git@github.com \
  --key-owner vb \
  --key-hostname laptop \
  --service github
```

### CI/CD Automation

```bash
# No passphrase, automated deployment
./ssh-keygen-deploy.py \
  --remote deploy@prod.com \
  --key-owner ci-bot \
  --key-hostname github-actions \
  --non-interactive
```

## Options Reference

| Option | Description | Example |
|--------|-------------|---------|
| `--remote USER@HOST` | Deploy to remote (client mode) | `user@server.com` |
| `--user USER` | Local user for .ssh directory | `root` |
| `--key-owner OWNER` | Owner in public key comment | `vb`, `client` |
| `--key-hostname HOST` | Hostname in comment | `laptop`, `workstation` |
| `--service SERVICE` | Service name in filename | `netcup`, `github` |
| `--algorithm ALGO` | Key algorithm | `ed25519`, `rsa` |
| `--send-private` | Send private key via Telegram | - |
| `--non-interactive` | Skip all prompts | - |
| `--debug` | Enable debug logging | - |

## Environment Variables

```bash
TELEGRAM_BOT_TOKEN=<token>     # Telegram bot token
TELEGRAM_CHAT_ID=<id>          # Telegram chat ID
NONINTERACTIVE=yes             # Non-interactive mode
USER=<username>                # Default user
```

## Key Naming

### Local Mode (Server)
```
Private: server-access-hostname-ed25519
Comment: client@hostname.example.com_202601
```

### Remote Mode (Client)
```
Private: service-user-ed25519
Comment: owner@hostname_202601
```

## File Locations

```
~/.ssh/
├── authorized_keys                    (600) - Public keys
├── server-access-hostname-ed25519     (600) - Server private key
├── server-access-hostname-ed25519.pub (644) - Server public key
├── service-user-ed25519               (600) - Client private key
└── service-user-ed25519.pub           (644) - Client public key
```

## Workflow

### Local Mode
1. Generate key pair
2. Add public key to authorized_keys
3. Send private key via Telegram
4. Client downloads and uses

### Remote Mode
1. Generate key pair
2. Deploy public key to remote (ssh-copy-id)
3. Add to ssh-agent
4. Private key stays local

## Troubleshooting

```bash
# Test Telegram
python3 telegram_client.py --test

# Check syntax
python3 -m py_compile ssh-keygen-deploy.py

# Debug mode
./ssh-keygen-deploy.py --user root --send-private --debug

# Fix permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys ~/.ssh/*_ed25519
chmod 644 ~/.ssh/*_ed25519.pub
```

## Bootstrap Integration

Add to `bootstrap.sh`:

```bash
SETUP_SSH_ACCESS="${SETUP_SSH_ACCESS:-no}"
SSH_ACCESS_USER="${SSH_ACCESS_USER:-root}"

if [ "$SETUP_SSH_ACCESS" = "yes" ]; then
    python3 "${SCRIPT_DIR}/../ssh-keygen-deploy.py" \
        --user "${SSH_ACCESS_USER}" \
        --send-private \
        --non-interactive
fi
```

## Exit Codes

- `0` - Success
- `1` - Error
- `130` - User cancelled (Ctrl+C)

## Links

- [README_SSH_KEYGEN_DEPLOY.md](README_SSH_KEYGEN_DEPLOY.md) - Full documentation
- [MIGRATION_SSH_KEYGEN.md](MIGRATION_SSH_KEYGEN.md) - Migration from shell scripts
- [SSH_KEY_MANAGEMENT.md](../docs/SSH_KEY_MANAGEMENT.md) - Best practices
