#!/bin/bash

# Generate self-signed certificates for testing the registry-secure setup
# This script creates a self-signed certificate that can be used for local testing

set -e

DOMAIN="${PUBLIC_FQDN:-r1001.vxxu.de}"
CERT_DIR="./certs"

echo "[INFO] Creating self-signed TLS certificates for domain: $DOMAIN"

# Create certificate directory
mkdir -p "$CERT_DIR"

# Generate private key
openssl genrsa -out "$CERT_DIR/privkey.pem" 2048

# Generate certificate signing request
cat > "$CERT_DIR/cert.conf" << EOF
[req]
default_bits = 2048
prompt = no
distinguished_name = dn
req_extensions = v3_req

[dn]
CN=$DOMAIN

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

# Generate self-signed certificate (valid for 365 days)
openssl req -new -x509 -key "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" -days 365 -config "$CERT_DIR/cert.conf" -extensions v3_req

# Set proper permissions
chmod 600 "$CERT_DIR/privkey.pem"
chmod 644 "$CERT_DIR/fullchain.pem"

# Clean up temporary files
rm -f "$CERT_DIR/cert.conf"

echo "[INFO] Self-signed certificates generated:"
echo "[INFO]   Certificate: $CERT_DIR/fullchain.pem"
echo "[INFO]   Private key: $CERT_DIR/privkey.pem"
echo "[INFO] Note: These are self-signed certificates for testing only."
echo "[INFO] Your browser will show security warnings which you can safely ignore for testing."