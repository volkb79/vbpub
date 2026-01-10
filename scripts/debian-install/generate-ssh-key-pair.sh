#!/bin/bash
#
# SSH Key Pair Generation and Setup Script (Client-Side)
# ======================================================
# 
# Purpose: Generate SSH key pair with proper naming conventions and deploy to remote server
# 
# Naming Conventions:
# - Private key filename: <service>_<user>_<algorithm>
#   Example: netcup-hosting218629-ed25519
#   Purpose: Identifies WHICH server/service to connect TO
#
# - Public key comment: <owner>@<hostname_or_context>_<date_or_version>
#   Example: vb@gstammtisch.dchive.de_202511
#   Purpose: Identifies WHO is using the key (appears in authorized_keys)

set -euo pipefail

# ==============================================================================
# CONFIGURATION SECTION
# ==============================================================================

# Identity information (who is generating this key)
KEY_OWNER="vb"                                    # Username or identifier of key owner
KEY_HOSTNAME="gstammtisch.dchive.de"             # Hostname or context of client machine
KEY_VERSION="202511"                              # Date or version identifier (YYYYMM format recommended)

# Target server information (where to connect)
TARGET_SERVICE="netcup"                           # Service name (e.g., netcup, github, aws)
TARGET_USERNAME="hosting218629"                   # Username on remote server
TARGET_HOSTNAME="hosting218629.ae98d.netcup.net" # Remote server hostname

# Key configuration
KEY_ALGORITHM="ed25519"                           # Algorithm: ed25519, rsa, ecdsa
KEY_STORAGE_PATH="/home/vscode/.ssh-host"        # Local path to store keys

# ==============================================================================
# DERIVED VARIABLES (Do not modify)
# ==============================================================================

# Construct public key comment (identifies WHO)
PUBLIC_KEY_COMMENT="${KEY_OWNER}@${KEY_HOSTNAME}_${KEY_VERSION}"

# Construct private key filename (identifies connection TO)
PRIVATE_KEY_FILENAME="${TARGET_SERVICE}-${TARGET_USERNAME}-${KEY_ALGORITHM}"

# Full path to private key file
PRIVATE_KEY_PATH="${KEY_STORAGE_PATH}/${PRIVATE_KEY_FILENAME}"

# Remote connection string
REMOTE_CONNECTION="${TARGET_USERNAME}@${TARGET_HOSTNAME}"

# ==============================================================================
# VALIDATION
# ==============================================================================

echo "=== SSH Key Generation Configuration ==="
echo "Owner:            ${KEY_OWNER}"
echo "Context:          ${KEY_HOSTNAME}"
echo "Version:          ${KEY_VERSION}"
echo "Target Service:   ${TARGET_SERVICE}"
echo "Target User:      ${TARGET_USERNAME}"
echo "Target Host:      ${TARGET_HOSTNAME}"
echo "Algorithm:        ${KEY_ALGORITHM}"
echo "Key Storage:      ${KEY_STORAGE_PATH}"
echo "Private Key:      ${PRIVATE_KEY_FILENAME}"
echo "Public Comment:   ${PUBLIC_KEY_COMMENT}"
echo ""

# Ensure storage directory exists
if [ ! -d "${KEY_STORAGE_PATH}" ]; then
    echo "Creating key storage directory: ${KEY_STORAGE_PATH}"
    mkdir -p "${KEY_STORAGE_PATH}"
    chmod 700 "${KEY_STORAGE_PATH}"
fi

# Check if key already exists
if [ -f "${PRIVATE_KEY_PATH}" ]; then
    echo "WARNING: Private key already exists at ${PRIVATE_KEY_PATH}"
    read -p "Overwrite existing key? (yes/no): " confirm
    if [ "${confirm}" != "yes" ]; then
        echo "Aborted by user"
        exit 1
    fi
fi

# ==============================================================================
# KEY GENERATION
# ==============================================================================

echo ""
echo "=== Generating SSH Key Pair ==="
ssh-keygen -t "${KEY_ALGORITHM}" \
           -C "${PUBLIC_KEY_COMMENT}" \
           -f "${PRIVATE_KEY_PATH}"

# Set proper permissions
chmod 600 "${PRIVATE_KEY_PATH}"
chmod 644 "${PRIVATE_KEY_PATH}.pub"

echo "✓ Key pair generated successfully"
echo "  Private: ${PRIVATE_KEY_PATH}"
echo "  Public:  ${PRIVATE_KEY_PATH}.pub"

# ==============================================================================
# SSH AGENT SETUP
# ==============================================================================

echo ""
echo "=== Adding Key to SSH Agent ==="

# Check if ssh-agent is running
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "Starting ssh-agent..."
    eval "$(ssh-agent -s)"
else
    echo "ssh-agent already running (PID: ${SSH_AGENT_PID:-unknown})"
fi

# Add key to agent (will prompt for passphrase if set)
ssh-add "${PRIVATE_KEY_PATH}"

echo "✓ Key added to ssh-agent"

# ==============================================================================
# REMOTE DEPLOYMENT
# ==============================================================================

echo ""
echo "=== Deploying Public Key to Remote Server ==="
echo "Target: ${REMOTE_CONNECTION}"
echo ""
echo "Note: You will be prompted for the password on first connection"

# Copy public key to remote server
ssh-copy-id -i "${PRIVATE_KEY_PATH}" "${REMOTE_CONNECTION}"

echo ""
echo "✓ Public key deployed successfully"

# ==============================================================================
# TEST CONNECTION
# ==============================================================================

echo ""
read -p "Test SSH connection now? (yes/no): " test_connection

if [ "${test_connection}" = "yes" ]; then
    echo ""
    echo "=== Testing SSH Connection ==="
    ssh -i "${PRIVATE_KEY_PATH}" "${REMOTE_CONNECTION}" "echo '✓ Connection successful!'"
fi

# ==============================================================================
# COMPLETION SUMMARY
# ==============================================================================

echo ""
echo "=== Setup Complete ==="
echo ""
echo "To use this key for SSH connections:"
echo "  ssh -i ${PRIVATE_KEY_PATH} ${REMOTE_CONNECTION}"
echo ""
echo "Or add to your ~/.ssh/config:"
echo "  Host ${TARGET_SERVICE}-${TARGET_USERNAME}"
echo "    HostName ${TARGET_HOSTNAME}"
echo "    User ${TARGET_USERNAME}"
echo "    IdentityFile ${PRIVATE_KEY_PATH}"
echo ""
echo "Then connect with:"
echo "  ssh ${TARGET_SERVICE}-${TARGET_USERNAME}"
echo ""
