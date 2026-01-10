# SSH Key Management Update Summary

## Overview

Updated SSH key management scripts to support automated server provisioning with secure key delivery via Telegram during system bootstrap.

## Files Created/Modified

### 1. **scripts/generate-ssh-key-pair.sh** (New - Client Side)
- Interactive client-side key generation script
- Follows naming conventions (filename = where TO, comment = WHO)
- Integrated ssh-agent management
- Auto-deployment via ssh-copy-id
- Connection testing
- SSH config generation

### 2. **scripts/setup-authorized-keys-server.sh** (Enhanced - Server Side)
- **NEW**: `--generate-key` flag for automated key generation
- **NEW**: Non-interactive mode (`NONINTERACTIVE=yes`)
- **NEW**: Telegram integration for secure private key delivery
- **NEW**: Automatic hostname detection
- Standard authorized_keys setup (backward compatible)
- Interactive key addition (manual paste/import)

### 3. **docs/SSH_KEY_MANAGEMENT.md** (New - Documentation)
- Comprehensive SSH key management guide
- Naming convention explanations
- Usage scenarios and examples
- Best practices and security guidelines
- Troubleshooting guide

### 4. **scripts/SSH_KEY_BOOTSTRAP.md** (New - Integration Guide)
- Bootstrap integration instructions
- Environment variable documentation
- Complete usage examples
- Security considerations

## Key Features

### Naming Conventions

**Private Key Filename:** `<service>-<user>-<algorithm>`
- Example: `netcup-hosting218629-ed25519`
- Identifies WHERE to connect TO

**Public Key Comment:** `<owner>@<hostname>_<YYYYMM>`
- Example: `vb@gstammtisch.dchive.de_202511`
- Identifies WHO is connecting FROM

### Server-Side Key Generation

```bash
# Basic usage (no Telegram)
./setup-authorized-keys-server.sh --generate-key root

# With Telegram delivery
TELEGRAM_BOT_TOKEN=123:abc \
TELEGRAM_CHAT_ID=456 \
NONINTERACTIVE=yes \
./setup-authorized-keys-server.sh --generate-key root
```

### Bootstrap Integration

```bash
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
DEBUG_MODE=yes \
TELEGRAM_BOT_TOKEN=123123:asdasdasdasdasdasd \
TELEGRAM_CHAT_ID=123123123 \
SETUP_SSH_ACCESS=yes \
SSH_ACCESS_USER=root \
bash
```

## Generated Key Details

When `--generate-key` is used:

1. **Private key location**: `/home/USER/.ssh/server-access-HOSTNAME-ed25519`
2. **Public key**: Automatically added to `authorized_keys`
3. **Telegram delivery**: Private key sent as file attachment with usage instructions
4. **Security**: No passphrase (for automated access), permissions set to 600

## Telegram Message Format

The script sends a formatted message with:
- System hostname and IP
- Security notice
- Usage instructions (chmod, ssh command)
- SHA256 and MD5 fingerprints
- SSH config example
- Connection command

Example:
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

[Fingerprints and config example follow...]
```

## Security Features

1. **Secure transmission**: Keys only sent via encrypted Telegram
2. **Automatic permissions**: Proper file permissions set (600 private, 644 public, 700 .ssh)
3. **Fingerprint verification**: Both SHA256 and MD5 provided
4. **Backup creation**: Existing authorized_keys backed up before modification
5. **Validation**: Public key format validated before addition
6. **Non-interactive mode**: Safe for automation (preserves existing keys)

## Integration Points

### With bootstrap.sh

Add this section after system setup in bootstrap.sh:

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
fi
```

### Environment Variables

Add to bootstrap configuration:

```bash
SETUP_SSH_ACCESS="${SETUP_SSH_ACCESS:-no}"     # Generate and send SSH key
SSH_ACCESS_USER="${SSH_ACCESS_USER:-root}"     # User for SSH access
```

## Usage Examples

### 1. Netcup VPS Provisioning

```bash
# During VPS creation (init script)
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
TELEGRAM_BOT_TOKEN=<token> \
TELEGRAM_CHAT_ID=<chat-id> \
SETUP_SSH_ACCESS=yes \
SSH_ACCESS_USER=root \
bash
```

### 2. Manual Server Setup

```bash
# Clone repo
git clone https://github.com/volkb79/vbpub.git /opt/vbpub

# Setup and generate key
cd /opt/vbpub/scripts
export TELEGRAM_BOT_TOKEN="your-token"
export TELEGRAM_CHAT_ID="your-chat-id"
export NONINTERACTIVE=yes

./setup-authorized-keys-server.sh --generate-key root
```

### 3. Client Key Generation

```bash
# Edit configuration in script
cd /opt/vbpub/scripts
vim generate-ssh-key-pair.sh

# Run interactively
./generate-ssh-key-pair.sh
```

## Backward Compatibility

All existing functionality preserved:
- Standard authorized_keys setup still works
- Interactive key addition unchanged
- Can be used without Telegram
- Can be used without --generate-key flag

## Testing

```bash
# Syntax check
bash -n setup-authorized-keys-server.sh

# Test without Telegram
./setup-authorized-keys-server.sh root

# Test with key generation (no Telegram)
./setup-authorized-keys-server.sh --generate-key testuser

# Test non-interactive mode
NONINTERACTIVE=yes ./setup-authorized-keys-server.sh --generate-key root
```

## Next Steps

1. **Test bootstrap integration**: Add to bootstrap.sh and test full flow
2. **Documentation review**: Ensure all docs are clear and complete
3. **Security review**: Verify key permissions and Telegram security
4. **Production deployment**: Use in actual VPS provisioning

## Related Files

- [scripts/generate-ssh-key-pair.sh](scripts/generate-ssh-key-pair.sh) - Client-side key generation
- [scripts/setup-authorized-keys-server.sh](scripts/setup-authorized-keys-server.sh) - Server-side setup
- [docs/SSH_KEY_MANAGEMENT.md](docs/SSH_KEY_MANAGEMENT.md) - Complete guide
- [scripts/SSH_KEY_BOOTSTRAP.md](scripts/SSH_KEY_BOOTSTRAP.md) - Bootstrap integration
- [scripts/debian-install/bootstrap.sh](scripts/debian-install/bootstrap.sh) - System bootstrap
- [scripts/debian-install/telegram_client.py](scripts/debian-install/telegram_client.py) - Telegram client
