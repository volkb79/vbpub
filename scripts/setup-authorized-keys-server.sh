#!/bin/bash
#
# Server-Side SSH Authorized Keys Setup
# ======================================
#
# Purpose: Configure SSH authorized_keys on server when client details are not yet known
# Use Case: Initial server setup, preparing for multiple clients, or manual key installation
#
# This script prepares the server to accept SSH key authentication and can add
# keys manually when they are provided out-of-band (email, secure chat, etc.)
#
# Integration with bootstrap.sh:
#   Can be called automatically during system post-install
#   Supports --generate-key flag to create server key and send via Telegram
#
# Usage:
#   ./setup-authorized-keys-server.sh [username]
#   ./setup-authorized-keys-server.sh --generate-key [username]
#
# Environment Variables (for non-interactive mode):
#   TELEGRAM_BOT_TOKEN - Telegram bot token for sending keys
#   TELEGRAM_CHAT_ID - Telegram chat ID for notifications
#   NONINTERACTIVE=yes - Skip all interactive prompts

set -euo pipefail

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================

GENERATE_KEY=false
NONINTERACTIVE="${NONINTERACTIVE:-no}"
TARGET_USER=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --generate-key)
            GENERATE_KEY=true
            shift
            ;;
        --non-interactive)
            NONINTERACTIVE=yes
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            TARGET_USER="$1"
            shift
            ;;
    esac
done

# ==============================================================================
# CONFIGURATION SECTION
# ==============================================================================

# User account to configure (use provided argument, or default to current user)
TARGET_USER="${TARGET_USER:-$USER}"

# SSH directory path
SSH_DIR="/home/${TARGET_USER}/.ssh"
AUTHORIZED_KEYS_FILE="${SSH_DIR}/authorized_keys"

# Backup settings
CREATE_BACKUP=true
BACKUP_SUFFIX="backup-$(date +%Y%m%d-%H%M%S)"

# Telegram configuration (from environment)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Path to telegram client script (auto-detect)
TELEGRAM_CLIENT=""
if [ -f "/opt/vbpub/scripts/debian-install/telegram_client.py" ]; then
    TELEGRAM_CLIENT="/opt/vbpub/scripts/debian-install/telegram_client.py"
elif [ -f "$(dirname "$0")/debian-install/telegram_client.py" ]; then
    TELEGRAM_CLIENT="$(dirname "$0")/debian-install/telegram_client.py"
fi

# Key generation settings
KEY_ALGORITHM="ed25519"
KEY_VERSION="$(date +%Y%m)"

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

# Send message via Telegram
tg_send() {
    local msg="$1"
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
    [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    [ -z "$TELEGRAM_CLIENT" ] && return 0
    [ ! -f "$TELEGRAM_CLIENT" ] && return 0
    python3 "$TELEGRAM_CLIENT" --send "$msg" 2>/dev/null || true
}

# Send file via Telegram
tg_send_file() {
    local file="$1"
    local caption="${2:-}"
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
    [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    [ -z "$TELEGRAM_CLIENT" ] && return 0
    [ ! -f "$TELEGRAM_CLIENT" ] && return 0
    [ ! -f "$file" ] && return 0
    if [ -n "$caption" ]; then
        python3 "$TELEGRAM_CLIENT" --file "$file" --caption "$caption" 2>/dev/null || true
    else
        python3 "$TELEGRAM_CLIENT" --file "$file" 2>/dev/null || true
    fi
}

# Get system identification
get_system_id() {
    local hostname_fqdn
    
    # Try to get FQDN
    hostname_fqdn=$(hostname -f 2>/dev/null || hostname)
    
    echo "${hostname_fqdn}"
}

# ==============================================================================
# KEY GENERATION FUNCTION
# ==============================================================================

generate_and_send_key() {
    log_info "=== Generating SSH Access Key for Remote Clients ==="
    
    local system_hostname=$(get_system_id)
    local system_short=$(hostname -s 2>/dev/null || hostname)
    local key_owner="client"
    local key_comment="${key_owner}@${system_hostname}_${KEY_VERSION}"
    local key_filename="server-access-${system_short}-${KEY_ALGORITHM}"
    local key_path="${SSH_DIR}/${key_filename}"
    
    log_info "Key Details:"
    log_info "  System:       ${system_hostname}"
    log_info "  Algorithm:    ${KEY_ALGORITHM}"
    log_info "  Comment:      ${key_comment}"
    log_info "  Private Key:  ${key_filename}"
    log_info "  Public Key:   ${key_filename}.pub"
    
    # Check if key already exists
    if [ -f "${key_path}" ]; then
        log_warn "Private key already exists at ${key_path}"
        if [ "$NONINTERACTIVE" != "yes" ]; then
            read -p "Overwrite existing key? (yes/no): " confirm
            if [ "${confirm}" != "yes" ]; then
                log_info "Keeping existing key"
                return 0
            fi
        else
            log_info "Non-interactive mode: Skipping key generation to preserve existing key"
            return 0
        fi
    fi
    
    # Generate key pair without passphrase (for automated server access)
    log_info "Generating key pair (no passphrase for automated access)..."
    ssh-keygen -t "${KEY_ALGORITHM}" \
               -C "${key_comment}" \
               -f "${key_path}" \
               -N "" \
               -q
    
    # Set proper permissions
    chmod 600 "${key_path}"
    chmod 644 "${key_path}.pub"
    chown "${TARGET_USER}:${TARGET_USER}" "${key_path}" "${key_path}.pub"
    
    log_info "✓ Key pair generated successfully"
    
    # Add public key to authorized_keys
    log_info "Adding public key to authorized_keys..."
    cat "${key_path}.pub" >> "${AUTHORIZED_KEYS_FILE}"
    log_info "✓ Public key added to authorized_keys"
    
    # Calculate fingerprints
    local fp_sha256=$(ssh-keygen -lf "${key_path}.pub" -E sha256 | awk '{print $2}')
    local fp_md5=$(ssh-keygen -lf "${key_path}.pub" -E md5 | awk '{print $2}')
    
    # Display key information
    log_info ""
    log_info "=== Key Generation Complete ==="
    log_info "Private Key: ${key_path}"
    log_info "Public Key:  ${key_path}.pub"
    log_info "Fingerprint (SHA256): ${fp_sha256}"
    log_info "Fingerprint (MD5):    ${fp_md5}"
    
    # Send via Telegram if configured
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        log_info ""
        log_info "=== Sending Private Key via Telegram ==="
        
        # Create secure message with usage instructions
        local telegram_msg="🔑 <b>SSH Server Access Key Generated</b>

<b>System:</b> ${system_hostname}
<b>User:</b> ${TARGET_USER}
<b>Algorithm:</b> ${KEY_ALGORITHM}

<b>⚠️ SECURITY NOTICE</b>
This private key grants SSH access to this server.
Treat it as a password and store securely.

<b>Usage Instructions:</b>
1. Save the attached file securely
2. Set permissions: <code>chmod 600 ${key_filename}</code>
3. Connect: <code>ssh -i ${key_filename} ${TARGET_USER}@${system_hostname}</code>

<b>Fingerprints for Verification:</b>
SHA256: <code>${fp_sha256}</code>
MD5: <code>${fp_md5}</code>

<b>Add to ~/.ssh/config:</b>
<pre>Host ${system_short}
    HostName ${system_hostname}
    User ${TARGET_USER}
    IdentityFile ~/.ssh/${key_filename}</pre>

Then connect with: <code>ssh ${system_short}</code>"
        
        # Send message first
        tg_send "$telegram_msg"
        
        # Send private key as file
        tg_send_file "${key_path}" "🔐 Private Key: ${key_filename}"
        
        log_info "✓ Private key sent via Telegram"
        log_info ""
        log_info "⚠️  IMPORTANT: The private key has been sent via Telegram"
        log_info "    Delete the message after saving the key securely"
        log_info "    Consider rotating this key periodically"
    else
        log_warn ""
        log_warn "Telegram not configured - private key NOT sent"
        log_warn "Private key location: ${key_path}"
        log_warn ""
        log_warn "To retrieve the key manually:"
        log_warn "  cat ${key_path}"
        log_warn ""
        log_warn "Or transfer securely:"
        log_warn "  scp ${TARGET_USER}@${system_hostname}:${key_path} ~/.ssh/"
    fi
    
    # Display public key for reference
    log_info ""
    log_info "=== Public Key (for reference) ==="
    cat "${key_path}.pub"
    echo ""
}

# ==============================================================================
# VALIDATION
# ==============================================================================

if [ "$NONINTERACTIVE" != "yes" ]; then
    echo "=== Server-Side SSH Setup ==="
    echo "Target User:      ${TARGET_USER}"
    echo "SSH Directory:    ${SSH_DIR}"
    echo "Authorized Keys:  ${AUTHORIZED_KEYS_FILE}"
    echo "Mode:             $([ "$GENERATE_KEY" = true ] && echo "Generate Key & Send via Telegram" || echo "Standard Setup")"
    echo ""
fi

# Check if running as root or with sudo when targeting different user
if [ "${TARGET_USER}" != "${USER}" ] && [ "${EUID}" -ne 0 ]; then
    log_error "Must run as root or with sudo to configure different user"
    exit 1
fi

# Check if user exists
if ! id "${TARGET_USER}" &>/dev/null; then
    log_error "User '${TARGET_USER}' does not exist"
    exit 1
fi

# ==============================================================================
# SSH DIRECTORY SETUP
# ==============================================================================

if [ "$NONINTERACTIVE" != "yes" ]; then
    echo "=== Configuring SSH Directory ==="
fi

# Create .ssh directory if it doesn't exist
if [ ! -d "${SSH_DIR}" ]; then
    log_info "Creating SSH directory: ${SSH_DIR}"
    mkdir -p "${SSH_DIR}"
else
    if [ "$NONINTERACTIVE" != "yes" ]; then
        echo "✓ SSH directory exists"
    fi
fi

# Set proper ownership and permissions
chown "${TARGET_USER}:${TARGET_USER}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

if [ "$NONINTERACTIVE" != "yes" ]; then
    echo "✓ SSH directory permissions set (700)"
fi

# ==============================================================================
# AUTHORIZED_KEYS FILE SETUP
# ==============================================================================

if [ "$NONINTERACTIVE" != "yes" ]; then
    echo ""
    echo "=== Configuring authorized_keys File ==="
fi

# Create authorized_keys file if it doesn't exist
if [ ! -f "${AUTHORIZED_KEYS_FILE}" ]; then
    log_info "Creating authorized_keys file"
    touch "${AUTHORIZED_KEYS_FILE}"
    {
        echo "# Authorized SSH public keys for ${TARGET_USER}"
        echo "# Format: ssh-ALGORITHM KEY-DATA COMMENT"
        echo "# Comment format: owner@hostname_version"
        echo ""
    } > "${AUTHORIZED_KEYS_FILE}"
else
    if [ "$NONINTERACTIVE" != "yes" ]; then
        echo "✓ authorized_keys file exists"
    fi
    
    # Create backup if enabled
    if [ "${CREATE_BACKUP}" = true ]; then
        BACKUP_FILE="${AUTHORIZED_KEYS_FILE}.${BACKUP_SUFFIX}"
        cp "${AUTHORIZED_KEYS_FILE}" "${BACKUP_FILE}"
        if [ "$NONINTERACTIVE" != "yes" ]; then
            echo "✓ Backup created: ${BACKUP_FILE}"
        fi
    fi
fi

# Set proper ownership and permissions
chown "${TARGET_USER}:${TARGET_USER}" "${AUTHORIZED_KEYS_FILE}"
chmod 600 "${AUTHORIZED_KEYS_FILE}"

if [ "$NONINTERACTIVE" != "yes" ]; then
    echo "✓ authorized_keys permissions set (600)"
fi

# ==============================================================================
# KEY GENERATION MODE
# ==============================================================================

if [ "$GENERATE_KEY" = true ]; then
    generate_and_send_key
    
    # Skip interactive sections in generate key mode
    NONINTERACTIVE=yes
fi

# ==============================================================================
# DISPLAY CURRENT KEYS
# ==============================================================================

if [ "$NONINTERACTIVE" != "yes" ]; then
    echo ""
    echo "=== Current Authorized Keys ==="

    if [ -s "${AUTHORIZED_KEYS_FILE}" ]; then
        # Count non-comment, non-empty lines
        KEY_COUNT=$(grep -v '^#' "${AUTHORIZED_KEYS_FILE}" | grep -v '^$' | wc -l)
        echo "Total keys: ${KEY_COUNT}"
        echo ""
        
        if [ "${KEY_COUNT}" -gt 0 ]; then
            echo "Keys:"
            grep -v '^#' "${AUTHORIZED_KEYS_FILE}" | grep -v '^$' | while IFS= read -r line; do
                # Extract algorithm and comment
                KEY_ALGO=$(echo "${line}" | awk '{print $1}')
                KEY_COMMENT=$(echo "${line}" | awk '{print $NF}')
                # Calculate fingerprint
                KEY_FP=$(echo "${line}" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || echo "unknown")
                echo "  - ${KEY_ALGO} ${KEY_COMMENT} (${KEY_FP})"
            done
        fi
    else
        echo "No keys configured yet"
    fi
fi

# ==============================================================================
# INTERACTIVE KEY ADDITION
# ==============================================================================

if [ "$NONINTERACTIVE" != "yes" ]; then
    echo ""
    echo "=== Add New Public Key ==="
    echo ""
    echo "Options:"
    echo "  1) Paste public key manually"
    echo "  2) Import from file"
    echo "  3) Skip (configure later)"
    echo ""

    read -p "Select option (1-3): " option
else
    # Skip interactive key addition in non-interactive mode
    option=3
fi

case "${option}" in
    1)
        echo ""
        echo "Paste the complete public key line (ssh-algo key-data comment)"
        echo "Press Enter on empty line when done:"
        
        PUBLIC_KEY=""
        while IFS= read -r line; do
            [ -z "${line}" ] && break
            PUBLIC_KEY="${PUBLIC_KEY}${line}"
        done
        
        if [ -n "${PUBLIC_KEY}" ]; then
            # Validate key format
            if echo "${PUBLIC_KEY}" | ssh-keygen -lf - &>/dev/null; then
                echo "${PUBLIC_KEY}" >> "${AUTHORIZED_KEYS_FILE}"
                echo "✓ Public key added successfully"
                
                # Show fingerprint
                FINGERPRINT=$(echo "${PUBLIC_KEY}" | ssh-keygen -lf - | awk '{print $2}')
                echo "  Fingerprint: ${FINGERPRINT}"
            else
                echo "ERROR: Invalid public key format"
                exit 1
            fi
        else
            echo "No key provided, skipping"
        fi
        ;;
    
    2)
        read -p "Enter path to public key file (.pub): " pubkey_file
        
        if [ -f "${pubkey_file}" ]; then
            # Validate key format
            if ssh-keygen -lf "${pubkey_file}" &>/dev/null; then
                cat "${pubkey_file}" >> "${AUTHORIZED_KEYS_FILE}"
                echo "✓ Public key imported successfully"
                
                # Show fingerprint
                FINGERPRINT=$(ssh-keygen -lf "${pubkey_file}" | awk '{print $2}')
                echo "  Fingerprint: ${FINGERPRINT}"
            else
                echo "ERROR: Invalid public key file"
                exit 1
            fi
        else
            echo "ERROR: File not found: ${pubkey_file}"
            exit 1
        fi
        ;;
    
    3)
        echo "Skipping key addition"
        ;;
    
    *)
        echo "Invalid option, skipping"
        ;;
esac

# ==============================================================================
# SSHD CONFIGURATION CHECK
# ==============================================================================

if [ "$NONINTERACTIVE" != "yes" ]; then
    echo ""
    echo "=== SSHD Configuration Check ==="
fi

SSHD_CONFIG="/etc/ssh/sshd_config"

if [ -f "${SSHD_CONFIG}" ]; then
    if [ "$NONINTERACTIVE" != "yes" ]; then
        echo "Checking SSHD configuration..."
    fi
    
    # Check PubkeyAuthentication
    if grep -q "^PubkeyAuthentication yes" "${SSHD_CONFIG}"; then
        if [ "$NONINTERACTIVE" != "yes" ]; then
            echo "✓ PubkeyAuthentication is enabled"
        fi
    else
        log_warn "PubkeyAuthentication may not be explicitly enabled"
        if [ "$NONINTERACTIVE" != "yes" ]; then
            echo "  Consider adding 'PubkeyAuthentication yes' to ${SSHD_CONFIG}"
        fi
    fi
    
    # Check PasswordAuthentication (informational)
    if grep -q "^PasswordAuthentication yes" "${SSHD_CONFIG}"; then
        if [ "$NONINTERACTIVE" != "yes" ]; then
            echo "ℹ PasswordAuthentication is enabled (can be disabled after key setup)"
        fi
    fi
    
    if [ "$NONINTERACTIVE" != "yes" ]; then
        echo ""
        echo "To reload SSHD configuration:"
        echo "  systemctl reload sshd"
    fi
else
    log_warn "SSHD config not found at ${SSHD_CONFIG}"
fi

# ==============================================================================
# COMPLETION SUMMARY
# ==============================================================================

if [ "$NONINTERACTIVE" != "yes" ]; then
    echo ""
    echo "=== Setup Complete ==="
    echo ""
    echo "Server is ready to accept SSH key authentication for user: ${TARGET_USER}"
    echo ""
    echo "To add more keys manually:"
    echo "  echo 'ssh-algo key-data comment' >> ${AUTHORIZED_KEYS_FILE}"
    echo ""
    echo "To view configured keys:"
    echo "  cat ${AUTHORIZED_KEYS_FILE}"
    echo ""
    echo "To test connection from client:"
    echo "  ssh -i /path/to/private_key ${TARGET_USER}@$(hostname)"
    echo ""
else
    log_info "✓ SSH setup complete for user: ${TARGET_USER}"
fi

# ==============================================================================
# SECURITY RECOMMENDATIONS
# ==============================================================================

if [ "$NONINTERACTIVE" != "yes" ]; then
    echo "=== Security Recommendations ==="
    echo ""
    echo "1. After verifying key authentication works:"
    echo "   - Disable password authentication in /etc/ssh/sshd_config"
    echo "   - Set: PasswordAuthentication no"
    echo ""
    echo "2. Consider additional hardening:"
    echo "   - Disable root login: PermitRootLogin no"
    echo "   - Use fail2ban to prevent brute force attacks"
    echo "   - Enable 2FA with pam_google_authenticator (optional)"
    echo ""
    echo "3. Key management:"
    echo "   - Regularly audit authorized_keys"
    echo "   - Remove keys for users who no longer need access"
    echo "   - Use key expiration dates in comments for tracking"
    echo ""
fi
