#!/bin/bash
# Setup Let's Encrypt certificate permissions for Docker group access
# Based on docs/0-prerequisites.md
#
# This script must be run as ROOT to adjust certificate permissions
# After running this script, containers in the docker group can read the certificates
#
# Usage:
#   sudo bash docs/setup-letsencrypt-permissions.sh <domain>
#
# Example:
#   sudo bash docs/setup-letsencrypt-permissions.sh r1001.vxxu.de

set -e

if [ "$EUID" -ne 0 ]; then 
    echo "[ERROR] This script must be run as root"
    echo "Usage: sudo bash $0 <domain>"
    exit 1
fi

CERT_DOMAIN="${1}"

if [ -z "$CERT_DOMAIN" ]; then
    # Auto-detect domain via reverse DNS
    PUBLIC_IP=$(curl -s https://api.ipify.org/)
    CERT_DOMAIN=$(dig +short -x "$PUBLIC_IP" | sed 's/\.$//')
    
    if [ -z "$CERT_DOMAIN" ]; then
        echo "[ERROR] Could not auto-detect domain. Please provide domain as argument."
        echo "Usage: sudo bash $0 <domain>"
        exit 1
    fi
    
    echo "[INFO] Auto-detected domain: $CERT_DOMAIN"
fi

# Check if certificate exists
if [ ! -d "/etc/letsencrypt/live/$CERT_DOMAIN" ]; then
    echo "[ERROR] Certificate not found for domain: $CERT_DOMAIN"
    echo "[INFO] Certificate directory does not exist: /etc/letsencrypt/live/$CERT_DOMAIN"
    echo ""
    echo "[INFO] To generate a Let's Encrypt certificate, run:"
    echo "  sudo certbot certonly --standalone -d $CERT_DOMAIN"
    exit 1
fi

echo "[INFO] Setting up permissions for domain: $CERT_DOMAIN"
echo "[INFO] Granting read access to docker group..."

# Grant docker group traversal rights to parent directories
chgrp docker /etc/letsencrypt/archive /etc/letsencrypt/live
chmod 750 /etc/letsencrypt/archive /etc/letsencrypt/live

# Grant docker group read access to all certificate files
chgrp docker /etc/letsencrypt/archive/$CERT_DOMAIN/*
chmod 640 /etc/letsencrypt/archive/$CERT_DOMAIN/privkey*.pem

echo "[SUCCESS] Permissions updated successfully!"
echo ""
echo "Directory permissions:"
ls -ld /etc/letsencrypt/archive /etc/letsencrypt/live
echo ""
echo "Certificate file permissions:"
ls -l /etc/letsencrypt/archive/$CERT_DOMAIN/
echo ""
echo "[INFO] Containers running as docker group can now read the certificates"
echo "[INFO] Certificate paths:"
echo "  Private key: /etc/letsencrypt/live/$CERT_DOMAIN/privkey.pem"
echo "  Full chain:  /etc/letsencrypt/live/$CERT_DOMAIN/fullchain.pem"
