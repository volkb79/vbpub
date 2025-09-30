#!/bin/bash
# Script to find your GitHub App Installation ID

# You need to set these:
# Using App ID 2030793 as requested
APP_ID="2030793"  # GitHub App ID
PRIVATE_KEY_PATH="$HOME/.ssh/github_app_key.pem"  # Path to your private key

# Generate JWT (same as in your main script)
# Base64 URL encode function (from GitHub's official bash example)
b64enc() { 
    openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'
}

generate_jwt() {
    local app_id="$1"
    local private_key_path="$2"
    
    # Expand tilde and check if file exists
    private_key_path="${private_key_path/#\~/$HOME}"
    
    if [[ ! -f "$private_key_path" ]]; then
        echo "Error: Private key file not found: $private_key_path" >&2
        echo "Please ensure you have downloaded your GitHub App private key and placed it at this location." >&2
        exit 1
    fi
    
    # Read the private key content
    local pem=$(cat "$private_key_path")
    
    # Generate timestamps (following GitHub's official example)
    local now=$(date +%s)
    local iat=$((now - 60))  # 60 seconds in the past (GitHub recommendation)
    local exp=$((now + 600)) # 10 minutes in the future
    
    # Create header and payload (following GitHub's official format)
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
    
    # Create signature (using GitHub's official method)
    local header_payload="${header}.${payload}"
    local signature=$(
        openssl dgst -sha256 -sign <(echo -n "${pem}") \
        <(echo -n "${header_payload}") | b64enc
    )
    
    # Create final JWT
    echo "${header_payload}.${signature}"
}

echo "Getting installations for App ID: $APP_ID"
echo "Using private key: $PRIVATE_KEY_PATH"

# Generate JWT using the App ID
JWT=$(generate_jwt "$APP_ID" "$PRIVATE_KEY_PATH")
if [[ $? -ne 0 ]]; then
    echo "Failed to generate JWT" >&2
    exit 1
fi

echo "JWT generated successfully (length: ${#JWT})"
echo "First few characters of JWT: ${JWT:0:50}..."

# Test the JWT by getting app info first
echo "Testing JWT by getting app information..."
curl -s -H "Authorization: Bearer $JWT" \
     -H "Accept: application/vnd.github+json" \
     -H "User-Agent: Installation-Finder/1.0" \
     -H "X-GitHub-Api-Version: 2022-11-28" \
     "https://api.github.com/app" | jq '.'

echo -e "\nNow trying to get installations..."
curl -s -H "Authorization: Bearer $JWT" \
     -H "Accept: application/vnd.github+json" \
     -H "User-Agent: Installation-Finder/1.0" \
     -H "X-GitHub-Api-Version: 2022-11-28" \
     "https://api.github.com/app/installations" | jq '.'