#!/bin/bash
# Simple JWT decoder to check what's in our JWT

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <JWT_TOKEN>"
    exit 1
fi

JWT="$1"

# Split JWT into parts
IFS='.' read -ra PARTS <<< "$JWT"

if [[ ${#PARTS[@]} -ne 3 ]]; then
    echo "Error: Invalid JWT format (expected 3 parts, got ${#PARTS[@]})"
    exit 1
fi

# Decode header
echo "=== JWT HEADER ==="
echo "${PARTS[0]}" | base64 -d 2>/dev/null | jq '.' 2>/dev/null || echo "Failed to decode header"

echo -e "\n=== JWT PAYLOAD ==="
# Add padding if needed for base64 decoding
payload="${PARTS[1]}"
while [[ $((${#payload} % 4)) -ne 0 ]]; do
    payload="${payload}="
done

echo "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null | jq '.' 2>/dev/null || echo "Failed to decode payload"

echo -e "\n=== JWT SIGNATURE ==="
echo "Signature length: ${#PARTS[2]} characters"