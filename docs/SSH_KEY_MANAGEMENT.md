# SSH Key Management Guide

Comprehensive guide for generating, deploying, and managing SSH keys with proper naming conventions and security practices.

## Table of Contents

- [Naming Conventions](#naming-conventions)
- [Scripts Overview](#scripts-overview)
- [Client-Side Setup](#client-side-setup)
- [Server-Side Setup](#server-side-setup)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

---

## Naming Conventions

### Private Key Filename

**Format:** `<service>_<user>_<algorithm>`

**Purpose:** Identifies **WHICH** server/service to connect **TO**

**Examples:**
- `netcup-hosting218629-ed25519`
- `github-vb-ed25519`
- `aws-ec2-production-rsa`

**Why:** The private key filename should immediately tell you what it's used for - which service or server you're connecting to.

### Public Key Comment

**Format:** `<owner>@<hostname_or_context>_<date_or_version>`

**Purpose:** Identifies **WHO** is using the key (appears in server's `authorized_keys`)

**Examples:**
- `vb@gstammtisch.dchive.de_202511`
- `john@devlaptop_202601`
- `ci-bot@github-actions_v2`

**Why:** This comment appears in the server's `authorized_keys` file, helping administrators identify which key belongs to which developer, machine, or system.

---

## Scripts Overview

### 1. `generate-ssh-key-pair.sh` (Client-Side)

**Use Case:** When you know which server/service you're connecting to

**Features:**
- Guided key generation with proper naming
- Automatic ssh-agent configuration
- Public key deployment to remote server
- Connection testing
- SSH config example generation

**Usage:**
```bash
./scripts/generate-ssh-key-pair.sh
```

Edit configuration variables in the script before running.

### 2. `setup-authorized-keys-server.sh` (Server-Side)

**Use Case:** When client details are not yet known (initial server setup)

**Features:**
- Prepares server for SSH key authentication
- Creates and secures `.ssh` directory and `authorized_keys`
- Interactive key addition (paste or import)
- SSHD configuration validation
- Security recommendations

**Usage:**
```bash
# For current user
./scripts/setup-authorized-keys-server.sh

# For specific user (requires sudo)
sudo ./scripts/setup-authorized-keys-server.sh username
```

---

## Client-Side Setup

### Prerequisites

- Bash shell
- SSH client installed
- Password access to target server (for initial setup)

### Quick Start

1. **Edit configuration variables** in `generate-ssh-key-pair.sh`:

```bash
# Identity information (who is generating this key)
KEY_OWNER="your-username"
KEY_HOSTNAME="your-workstation.example.com"
KEY_VERSION="202601"

# Target server information (where to connect)
TARGET_SERVICE="service-name"
TARGET_USERNAME="remote-user"
TARGET_HOSTNAME="server.example.com"

# Key configuration
KEY_ALGORITHM="ed25519"
KEY_STORAGE_PATH="$HOME/.ssh"
```

2. **Run the script:**

```bash
chmod +x scripts/generate-ssh-key-pair.sh
./scripts/generate-ssh-key-pair.sh
```

3. **Follow prompts:**
   - Set passphrase for private key (recommended)
   - Enter server password when deploying public key
   - Optionally test connection

### Manual Alternative

If you prefer manual steps:

```bash
# Generate key pair
ssh-keygen -t ed25519 \
           -C "user@host_202601" \
           -f ~/.ssh/service-user-ed25519

# Add to ssh-agent
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/service-user-ed25519

# Deploy to server
ssh-copy-id -i ~/.ssh/service-user-ed25519 user@server.example.com
```

---

## Server-Side Setup

### Prerequisites

- Root or sudo access on server
- SSH server (sshd) installed

### Scenario 1: Initial Server Setup (No Clients Yet)

Use when preparing a server before knowing which clients will connect:

```bash
sudo ./scripts/setup-authorized-keys-server.sh username
```

This will:
- Create and secure `.ssh` directory
- Initialize `authorized_keys` file
- Prompt for key addition (can skip and add later)
- Check SSHD configuration

### Scenario 2: Adding Keys Later

**Option A: Manual paste**
```bash
echo "ssh-ed25519 AAAAC3...key-data... user@host_202601" >> ~/.ssh/authorized_keys
```

**Option B: Import from file**
```bash
cat /path/to/received-key.pub >> ~/.ssh/authorized_keys
```

**Option C: Re-run server script**
```bash
./scripts/setup-authorized-keys-server.sh
# Select option to add key interactively
```

### Scenario 3: Multiple Users

For each user that needs SSH access:

```bash
sudo ./scripts/setup-authorized-keys-server.sh user1
sudo ./scripts/setup-authorized-keys-server.sh user2
```

---

## Best Practices

### Key Generation

1. **Use Ed25519 algorithm** (modern, secure, fast)
   ```bash
   ssh-keygen -t ed25519
   ```

2. **Always use a passphrase** for private keys
   - Protects key if file is stolen
   - Can use ssh-agent to avoid repeated entry

3. **Store keys securely**
   - Private key: `600` permissions (only owner can read/write)
   - Public key: `644` permissions
   - `.ssh` directory: `700` permissions

### Key Management

1. **Use descriptive names** following conventions
   - Makes key management easier as keys accumulate
   - Prevents confusion about which key is for what

2. **Include version/date in comments**
   - Helps with key rotation
   - Makes it easy to identify old keys for removal

3. **Regular key rotation**
   - Generate new keys periodically (e.g., annually)
   - Remove old keys from servers after rotation

4. **Document keys**
   - Keep inventory of which keys exist
   - Note which servers each key has access to

### Server Security

1. **Audit authorized_keys regularly**
   ```bash
   cat ~/.ssh/authorized_keys | grep -v '^#' | grep -v '^$'
   ```

2. **Remove unused keys promptly**
   - When team members leave
   - When machines are decommissioned

3. **Disable password authentication** after keys are set up:
   ```
   # /etc/ssh/sshd_config
   PasswordAuthentication no
   PubkeyAuthentication yes
   ```
   
   Then reload: `systemctl reload sshd`

4. **Additional hardening:**
   - Disable root login: `PermitRootLogin no`
   - Install fail2ban for brute force protection
   - Consider 2FA with PAM

### SSH Config

Create `~/.ssh/config` entries for convenience:

```
Host netcup-prod
    HostName hosting218629.ae98d.netcup.net
    User hosting218629
    IdentityFile ~/.ssh/netcup-hosting218629-ed25519
    
Host github
    HostName github.com
    User git
    IdentityFile ~/.ssh/github-vb-ed25519
```

Then connect simply with:
```bash
ssh netcup-prod
```

---

## Troubleshooting

### "Permission denied (publickey)"

**Causes:**
1. Public key not in server's `authorized_keys`
2. Wrong private key being used
3. Incorrect file permissions

**Solutions:**
```bash
# Check which key is being used
ssh -v user@server 2>&1 | grep "identity file"

# Verify server has your public key
ssh user@server "cat ~/.ssh/authorized_keys"

# Check permissions on server
ssh user@server "ls -la ~/.ssh/"
# Should be: drwx------ .ssh/
#           -rw------- authorized_keys

# Try specifying key explicitly
ssh -i ~/.ssh/specific-key user@server
```

### "Agent admitted failure to sign"

**Cause:** Key not loaded in ssh-agent

**Solution:**
```bash
# Check loaded keys
ssh-add -l

# Add your key
ssh-add ~/.ssh/your-private-key
```

### Key passphrase asked repeatedly

**Cause:** ssh-agent not running or key not added

**Solution:**
```bash
# Start ssh-agent
eval "$(ssh-agent -s)"

# Add key (enter passphrase once)
ssh-add ~/.ssh/your-private-key
```

### "Too many authentication failures"

**Cause:** ssh-agent has too many keys

**Solution:**
```bash
# Connect with specific key only
ssh -o IdentitiesOnly=yes -i ~/.ssh/specific-key user@server

# Or clear agent and add only needed keys
ssh-add -D
ssh-add ~/.ssh/needed-key
```

### Cannot find key file

**Cause:** Wrong path or filename

**Solution:**
```bash
# List all keys
ls -la ~/.ssh/*.pub

# Check absolute path
readlink -f ~/.ssh/your-key
```

---

## Security Considerations

### Private Key Protection

- **Never share private keys** between users or machines
- **Never commit private keys** to version control
- Use `.gitignore`:
  ```
  # Ignore all SSH keys
  *.pem
  *_rsa
  *_ed25519
  *_ecdsa
  !*.pub
  ```

### Public Key Safety

- Public keys can be freely shared
- Still be mindful where you publish them
- Comments in public keys may reveal information about your infrastructure

### Passphrase Strength

Use strong passphrases:
- Minimum 20 characters
- Include letters, numbers, symbols
- Or use diceware-style phrase (5-6 words)

Example: `correct-horse-battery-staple-96-!@`

---

## Quick Reference

### Generate new key pair
```bash
./scripts/generate-ssh-key-pair.sh
```

### Setup server (no clients yet)
```bash
sudo ./scripts/setup-authorized-keys-server.sh username
```

### Add key to agent
```bash
ssh-add ~/.ssh/private-key-name
```

### Copy key to server manually
```bash
ssh-copy-id -i ~/.ssh/key-name user@server
```

### Test connection
```bash
ssh -i ~/.ssh/key-name user@server
```

### View key fingerprint
```bash
ssh-keygen -lf ~/.ssh/key-name.pub
```

### List agent keys
```bash
ssh-add -l
```

---

## Related Documentation

- [README_AUTH.md](../scripts/README_AUTH.md) - GitHub App authentication
- [generate-test-certs.sh](../scripts/generate-test-certs.sh) - Certificate generation
- [SSH.com Documentation](https://www.ssh.com/academy/ssh/keygen)
- [GitHub SSH Guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)

