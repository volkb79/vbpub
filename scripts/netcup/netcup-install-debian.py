#!/usr/bin/env python3
"""
Netcup Server Control Panel - Automated Debian Installation

consume the netcup SCP API to automate the installation of Debian on a server.

Get API access / authentication:

1. Get a device_code and activate it 
curl -X POST 'https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect/auth/device' \
  -d "client_id=scp" \
  -d 'scope=offline_access openid' | jq

1.2. extract link in "verification_uri_complete", open it, login with SCP credentials, confirm grant access
1.3. extract the "device_code" : e.g. "BqCuANW2nKFwCtdf5HcbYRIEZ_RrklqiSF40r9AQH0k"

2. Use activated `device-token` to get long-term `refresh_token` to generate `access_token` for API access
curl -X POST 'https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:device_code' \
  -d 'device_code=<device-code>' \
  -d 'client_id=scp' | jq

Notes: 
- Use access token within the next 300 seconds to access the API. See "Refresh access token" how to obtain a new access token.
- The offline refresh token can be used multiple times and does not expire as long as it is used at least once every 30 days.
- If the refresh token is leaked or no longer needed it could be revoked.
- Forgotten refresh tokens can be revoked in the Account Console: 
   https://www.servercontrolpanel.de/realms/scp/account

3. Make API calls:
3.1. Get fresh access token
ACCESS_TOKEN=$(curl -s 'https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'client_id=scp' \
  -d "refresh_token=${REFRESH_TOKEN}" \
  -d 'grant_type=refresh_token' | jq -r '.access_token')

3.2. Make API calls with access token
curl 'https://www.servercontrolpanel.de/scp-core/api/v1/servers?limit=10' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}"

4. refresh flow: 
curl 'https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'client_id=scp' \
  -d 'refresh_token=<refresh_token>' \
  -d 'grant_type=refresh_token'
"""

import os
import sys
import json
import argparse
import requests
from typing import Optional, Dict, Any
from datetime import datetime
from pathlib import Path

# Load .env file if it exists
def load_env_file():
    """Load environment variables from .env file"""
    env_file = Path.cwd() / ".env"
    if env_file.exists():
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    # Remove quotes if present
                    value = value.strip().strip('"').strip("'")
                    os.environ.setdefault(key.strip(), value)

load_env_file()

# Configuration
BASE_URL = "https://www.servercontrolpanel.de/scp-core"
KEYCLOAK_URL = "https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect"
KEYCLOAK_TOKEN_URL = f"{KEYCLOAK_URL}/token"
KEYCLOAK_USERINFO_URL = f"{KEYCLOAK_URL}/userinfo"

# Server configuration
# Example server info:
#  {
#    "id": 799611,
#    "name": "v2202511209318402047",
#    "disabled": false,
#    "hostname": "r1002.vxxu.de",
#    "nickname": "r1002",
#    "template": {
#      "id": 1357,
#      "name": "RS 1000 G12 Pro"
#    }
#  }
SERVER_NAME = os.environ.get("SERVER_NAME", "v2202511209318402047")
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID")

# Installation settings
INSTALLATION_CONFIG = {
    "hostname": SERVER_NAME,
    "locale": "en_US.UTF-8",
    "timezone": "Europe/Berlin",
    "customScript":  f"curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | DEBUG_MODE=yes TELEGRAM_BOT_TOKEN={TELEGRAM_BOT_TOKEN} TELEGRAM_CHAT_ID={TELEGRAM_CHAT_ID} bash",
    "rootPartitionFullDiskSize": False,
    "sshPasswordAuthentication": False,
    "emailToExecutingUser": True,
}

# Debug mode
DEBUG = os.environ.get("DEBUG", "no").lower() in ("yes", "true", "1")


def log_debug(message: str):
    """Print debug messages if DEBUG is enabled"""
    if DEBUG:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"[DEBUG] {timestamp} {message}", file=sys.stderr)


def get_access_token(refresh_token: str) -> str:
    """Get fresh access token using refresh token"""
    log_debug("Refreshing access token...")

    response = requests.post(
        KEYCLOAK_TOKEN_URL,
        data={
            "client_id": "scp",
            "refresh_token": refresh_token,
            "grant_type": "refresh_token",
        },
    )
    response.raise_for_status()

    token_data = response.json()
    access_token = token_data.get("access_token")

    if not access_token:
        raise ValueError("No access token in response")

    log_debug(f"Access token obtained (expires in {token_data.get('expires_in', 'unknown')} seconds)")
    return access_token


def parse_args():
    """Parse command-line arguments"""
    parser = argparse.ArgumentParser(
        description="Netcup Server Control Panel - Automated Debian Installation",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Interactive mode (gather information and prompt for confirmation):
  %(prog)s
  
  # Direct installation from payload file (skip gathering):
  %(prog)s --payload=install-debian.json
  
Environment Variables:
  NETCUP_REFRESH_TOKEN    Required: Netcup API refresh token
  SERVER_NAME             Server name to install (default: v2202511209318402047)
  TELEGRAM_BOT_TOKEN      Optional: Telegram bot token for notifications
  TELEGRAM_CHAT_ID        Optional: Telegram chat ID for notifications
  DEBUG                   Enable debug output (yes/true/1)

These can be set in a .env file in the current directory.
"""
    )
    parser.add_argument(
        "--payload",
        metavar="FILE",
        help="Path to JSON payload file for direct installation (skips interactive gathering)"
    )
    return parser.parse_args()


def save_payload_with_comments(payload: Dict, filepath: str, server_name: str, image_name: str, user_id: int):
    """Save installation payload to JSONC file with helpful comments"""
    with open(filepath, "w") as f:
        f.write("{\n")
        for key, value in payload.items():
            # Add comments for IDs to make them more understandable
            if key == "serverId":
                f.write(f'  // Server ID for: {server_name}\n')
            elif key == "imageFlavourId":
                f.write(f'  // Image: {image_name}\n')
            elif key == "sshKeyIds":
                f.write(f'  // SSH key IDs for user {user_id}\n')
            
            # Write the actual key-value pair
            if isinstance(value, str):
                f.write(f'  "{key}": {json.dumps(value)},\n')
            elif isinstance(value, bool):
                f.write(f'  "{key}": {str(value).lower()},\n')
            elif isinstance(value, list):
                f.write(f'  "{key}": {json.dumps(value)},\n')
            else:
                f.write(f'  "{key}": {value},\n')
        
        # Remove trailing comma from last line
        f.seek(f.tell() - 2)
        f.write('\n}\n')


class NetcupSCPClient:
    def __init__(self, access_token: str):
        self.base_url = BASE_URL
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {access_token}",
            "Accept":  "application/json",
            "Content-Type": "application/json",
        })

    def get(self, endpoint: str, params: Optional[Dict] = None) -> Any:
        """Make GET request to API"""
        url = f"{self.base_url}{endpoint}"
        log_debug(f"GET {url} {params or ''}")
        response = self.session.get(url, params=params)
        response.raise_for_status()
        result = response.json()
        log_debug(f"Response: {json.dumps(result, indent=2)}")
        return result

    def post(self, endpoint: str, data: Dict) -> Any:
        """Make POST request to API"""
        url = f"{self.base_url}{endpoint}"
        log_debug(f"POST {url}")
        log_debug(f"Payload: {json.dumps(data, indent=2)}")
        response = self.session.post(url, json=data)
        response.raise_for_status()
        result = response.json()
        log_debug(f"Response: {json.dumps(result, indent=2)}")
        return result

    def get_user_info(self) -> Dict:
        """Get user information from OIDC userinfo endpoint"""
        log_debug(f"GET {KEYCLOAK_USERINFO_URL}")
        response = self.session.get(KEYCLOAK_USERINFO_URL)
        response.raise_for_status()
        result = response.json()
        log_debug(f"Response: {json.dumps(result, indent=2)}")
        return result


def install_from_payload(client: NetcupSCPClient, payload_path: str):
    """Install directly from a payload JSON file"""
    print("=" * 70)
    print("DIRECT INSTALLATION MODE")
    print("=" * 70)
    print()
    
    # Load payload
    print(f"Loading payload from: {payload_path}")
    try:
        with open(payload_path) as f:
            installation_payload = json.load(f)
    except FileNotFoundError:
        print(f"❌ ERROR: Payload file not found: {payload_path}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"❌ ERROR: Invalid JSON in payload file: {e}", file=sys.stderr)
        sys.exit(1)
    
    print("✓ Payload loaded successfully")
    print()
    
    # Extract server ID from payload or use hostname to find it
    server_id = None
    if "serverId" in installation_payload:
        server_id = installation_payload.pop("serverId")
        print(f"Using server ID from payload: {server_id}")
    else:
        # Try to find server by the hostname in payload
        hostname = installation_payload.get("hostname")
        if hostname:
            print(f"Finding server by hostname: {hostname}")
            servers = client.get("/api/v1/servers", params={"name": hostname})
            if servers:
                server_id = servers[0]["id"]
                print(f"✓ Found server ID: {server_id}")
            else:
                print(f"❌ ERROR: Server with hostname '{hostname}' not found!", file=sys.stderr)
                sys.exit(1)
        else:
            print("❌ ERROR: Payload must contain 'serverId' or 'hostname'", file=sys.stderr)
            sys.exit(1)
    
    print()
    
    # Display payload summary
    print("=" * 70)
    print("PAYLOAD SUMMARY")
    print("=" * 70)
    print(json.dumps(installation_payload, indent=2))
    print()
    
    # Ask for confirmation
    print("=" * 70)
    response = input("Do you want to start the installation now? (y/n): ")
    
    if response.lower() not in ("y", "yes"):
        print("Installation cancelled.")
        return
    
    # Start installation
    print()
    print("Starting installation...")
    try:
        result = client.post(f"/api/v1/servers/{server_id}/image", installation_payload)
        
        print(json.dumps(result, indent=2))
        print()
        
        if "uuid" in result:
            task_uuid = result["uuid"]
            print("=" * 70)
            print("✓ Installation started successfully!")
            print("=" * 70)
            print(f"Task UUID: {task_uuid}")
            print()
            print("Monitor progress with:")
            print(f"  export NETCUP_REFRESH_TOKEN='...'")
            print(f"  python3 monitor-task.py {task_uuid}")
    except requests.HTTPError as e:
        print(f"❌ HTTP Error: {e}", file=sys.stderr)
        if e.response.text:
            try:
                error_data = e.response.json()
                print(f"Response: {json.dumps(error_data, indent=2)}", file=sys.stderr)
            except:
                print(f"Response: {e.response.text}", file=sys.stderr)
        sys.exit(1)


def main():
    args = parse_args()
    
    # Check for refresh token
    refresh_token = os.environ.get("NETCUP_REFRESH_TOKEN")
    if not refresh_token:
        print("ERROR: missing $NETCUP_REFRESH_TOKEN", file=sys.stderr)
        print("Usage: export NETCUP_REFRESH_TOKEN='your-refresh-token' && python3 <this script>")
        sys.exit(1)

    try:
        # Get fresh access token
        access_token = get_access_token(refresh_token)
    except Exception as e:
        print(f"❌ Failed to get access token:  {e}", file=sys.stderr)
        sys.exit(1)

    client = NetcupSCPClient(access_token)
    
    # If payload file is provided, use direct installation mode
    if args.payload:
        install_from_payload(client, args.payload)
        return

    print("=" * 70)
    print(f"Gathering installation information for server:   {SERVER_NAME}")
    print("=" * 70)
    print()

    try:
        # 1. Find server by name
        print(f"1. Finding server '{SERVER_NAME}'...")
        servers = client.get("/api/v1/servers", params={"name": SERVER_NAME})

        if not servers:
            print(f"   ❌ ERROR: Server '{SERVER_NAME}' not found!")
            sys.exit(1)

        server_id = servers[0]["id"]
        print(f"   ✓ Server ID: {server_id}")
        print()

        # 2. Get server details (for disk info)
        print("2. Getting server details...")
        server_details = client.get(f"/api/v1/servers/{server_id}")

        disk_dev = server_details["serverLiveInfo"]["disks"][0]["dev"]
        disk_capacity_gib = server_details["serverLiveInfo"]["disks"][0]["capacityInMiB"] / 1024
        print(f"   ✓ Primary Disk: {disk_dev} ({disk_capacity_gib:.0f} GiB)")
        print()

        # 3. Find newest Debian UEFI image flavour
        print("3. Finding newest Debian UEFI image flavour...")
        image_flavours = client.get(f"/api/v1/servers/{server_id}/imageflavours")

        print("   Available Debian images:")
        debian_images = [
            img for img in image_flavours
            if "Debian" in img["image"]["name"] and "UEFI" in img["image"]["name"]
        ]
        
        if not debian_images:
            print("   ❌ ERROR: No Debian UEFI images found!")
            sys.exit(1)
        
        for img in debian_images:
            print(f"   - ID: {img['id']:3d} | {img['image']['name']}")
        print()

        # Sort by version number (extract version from name like "Debian 13.2.0 UEFI amd64")
        # Select the newest version
        debian_images_sorted = sorted(
            debian_images,
            key=lambda img: [int(x) if x.isdigit() else x for x in img["image"]["name"].split() if any(c.isdigit() for c in x)],
            reverse=True
        )
        newest_debian = debian_images_sorted[0]

        image_flavour_id = newest_debian["id"]
        print(f"   ✓ Selected newest: {newest_debian['image']['name']}")
        print(f"   ✓ Image Flavour ID: {image_flavour_id}")
        print()

        # 4. Get user ID
        print("4. Getting user information...")
        user_info = client.get_user_info()
        user_id = user_info["id"]
        print(f"   ✓ User ID: {user_id}")
        print()

        # 5. Get SSH keys
        print("5. Getting SSH keys...")
        ssh_keys = client.get(f"/api/v1/users/{user_id}/ssh-keys")

        if not ssh_keys:
            print("   ⚠ WARNING: No SSH keys found!")
            ssh_key_ids = None
        else:
            for key in ssh_keys:
                print(f"   - ID: {key['id']:3d} | {key['name']}")
            ssh_key_ids = [ssh_keys[0]["id"]]
            print(f"   ✓ Using SSH Key ID: {ssh_key_ids[0]}")
        print()

        # 6. Prepare installation payload
        installation_payload = {
            "serverId": server_id,  # Include for --payload mode
            "imageFlavourId": image_flavour_id,
            "diskName": disk_dev,
            "sshKeyIds": ssh_key_ids,
            **INSTALLATION_CONFIG
        }

        # 7. Display summary
        print("=" * 70)
        print("INSTALLATION PARAMETERS SUMMARY")
        print("=" * 70)
        print(json.dumps(installation_payload, indent=2))
        print()

        # 8. Save payload to file with comments
        save_payload_with_comments(
            installation_payload,
            "install-debian.json",
            SERVER_NAME,
            newest_debian['image']['name'],
            user_id
        )
        print("✓ Installation payload saved to:  install-debian.json")
        print()

        # 9. Ask for confirmation
        print("=" * 70)
        response = input("Do you want to start the installation now? (y/n): ")

        if response.lower() not in ("y", "yes"):
            print("Installation cancelled.")
            return

        # 10. Start installation
        print()
        print("Starting installation...")
        result = client.post(f"/api/v1/servers/{server_id}/image", installation_payload)

        print(json.dumps(result, indent=2))
        print()

        if "uuid" in result:
            task_uuid = result["uuid"]
            print("=" * 70)
            print("✓ Installation started successfully!")
            print("=" * 70)
            print(f"Task UUID: {task_uuid}")
            print()
            print("Monitor progress with:")
            print(f"  export NETCUP_REFRESH_TOKEN='...'")
            print(f"  python3 monitor-task.py {task_uuid}")

    except requests.HTTPError as e:
        print(f"❌ HTTP Error: {e}", file=sys.stderr)
        if e.response.text:
            try:
                error_data = e.response.json()
                print(f"Response: {json.dumps(error_data, indent=2)}", file=sys.stderr)
            except:
                print(f"Response: {e.response.text}", file=sys.stderr)
        sys.exit(1)
    except KeyError as e:
        print(f"❌ Missing expected field in API response: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"❌ Unexpected error: {e}", file=sys.stderr)
        if DEBUG:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
