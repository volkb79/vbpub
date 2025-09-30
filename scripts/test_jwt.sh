#!/bin/bash
# Just generate and output the JWT for testing

# Configuration - using App ID 2030793
APP_ID="2030793"  # Using correct App ID
PRIVATE_KEY_PATH="$HOME/.ssh/github_app_key.pem"

# Base64 URL encode function
b64enc() { 
    openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'
}

generate_jwt() {
    local app_id="$1"
    local private_key_path="$2"
    
    if [[ ! -f "$private_key_path" ]]; then
        echo "Error: Private key file not found: $private_key_path" >&2
        exit 1
    fi
    
    # Read the private key content
    local pem=$(cat "$private_key_path")
    
    # Generate timestamps
    local now=$(date +%s)
    local iat=$((now - 60))
    local exp=$((now + 600))
    
    # Create header and payload
    local header_json='{
        "typ":"JWT",
        "alg":"RS256"
    }'
    
    local payload_json="{
        \"iat\":${iat},
        \"exp\":${exp},
        \"iss\":\"${app_id}\"
    }"
    
    # Encode header and payload
    local header=$(echo -n "${header_json}" | b64enc)
    local payload=$(echo -n "${payload_json}" | b64enc)
    
    # Create signature
    local header_payload="${header}.${payload}"
    local signature=$(
        openssl dgst -sha256 -sign <(echo -n "${pem}") \
        <(echo -n "${header_payload}") | b64enc
    )
    
    # Output final JWT
    echo "${header_payload}.${signature}"
}

# Generate and output JWT
generate_jwt "$APP_ID" "$PRIVATE_KEY_PATH"