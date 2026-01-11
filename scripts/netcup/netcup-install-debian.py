#!/usr/bin/env python3
"""
Consume the netcup SCP API to automate the installation of Debian on a server.

netcup SCP API docs (see `netcup-scp-openapi.json`): 
``` 
curl 'https://www.servercontrolpanel.de/scp-core/api/v1/openapi' -H "Authorization: Bearer ${ACCESS_TOKEN}"
```

Get API access / Authentication:

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
import socket
import argparse
import subprocess
import threading
import time
import requests
from typing import Optional, Dict, Any, List
from datetime import datetime
from pathlib import Path


_SENSITIVE_DICT_KEYS = {
    "access_token",
    "refresh_token",
    "rootPassword",
    "password",
    "token",
    "authorization",
    "Authorization",
    "cloudInitResultBase64Encoded",
}


def _redact_for_log(value: Any) -> Any:
    if isinstance(value, dict):
        redacted: Dict[str, Any] = {}
        for k, v in value.items():
            if k in _SENSITIVE_DICT_KEYS:
                redacted[k] = "***REDACTED***"
            elif k == "customScript" and isinstance(v, str):
                redacted[k] = f"***REDACTED customScript (len={len(v)})***"
            else:
                redacted[k] = _redact_for_log(v)
        return redacted
    if isinstance(value, list):
        return [_redact_for_log(v) for v in value]
    return value

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

# Server configuration
# Example server info from `/servers` API:
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

#SERVER_NAME = os.environ.get("SERVER_NAME", "v2202511209318402047")   # r1002.vxxu.de
SERVER_NAME = os.environ.get("SERVER_NAME", "v2202511209318406253")    # v1001.vxxu.de
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID")

# Installation settings (hostname will be set dynamically from server info)
INSTALLATION_CONFIG = {
    "locale": "en_US.UTF-8",
    "timezone": "Europe/Berlin",
    "customScript":  f"curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | DEBUG_MODE=yes TELEGRAM_BOT_TOKEN={TELEGRAM_BOT_TOKEN} TELEGRAM_CHAT_ID={TELEGRAM_CHAT_ID} bash",
    "rootPartitionFullDiskSize": True,
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
        f"{KEYCLOAK_URL}/token",
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

    parser.add_argument(
        "--yes",
        action="store_true",
        help="Run non-interactively (auto-confirm prompts). Also enabled automatically when stdin is not a TTY."
    )
    parser.add_argument(
        "--monitor",
        action="store_true",
        help="After starting an installation, poll /api/v1/tasks/{uuid} until finished."
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=5.0,
        help="Polling interval in seconds for --monitor (default: 5)."
    )

    parser.add_argument(
        "--attach-bootstrap",
        dest="attach_bootstrap",
        action="store_true",
        default=True,
        help="When monitoring, attempt to SSH in once cloud-init starts and tail bootstrap logs. (default: enabled)"
    )
    parser.add_argument(
        "--no-attach-bootstrap",
        dest="attach_bootstrap",
        action="store_false",
        help="Disable SSH attach/bootstrap log tailing while monitoring."
    )
    parser.add_argument(
        "--ssh-host",
        default=os.environ.get("NETCUP_SSH_HOST"),
        help="SSH host/IP to attach to (default: detected server IPv4; override via NETCUP_SSH_HOST)."
    )
    parser.add_argument(
        "--ssh-user",
        default=os.environ.get("NETCUP_SSH_USER", "root"),
        help="SSH user for attaching to the freshly installed system (default: root; override via NETCUP_SSH_USER)."
    )
    parser.add_argument(
        "--ssh-identity-file",
        default=os.environ.get("NETCUP_SSH_IDENTITY_FILE"),
        help="Path to SSH identity file to use for attach (optional; override via NETCUP_SSH_IDENTITY_FILE)."
    )
    return parser.parse_args()


def is_noninteractive(args: argparse.Namespace) -> bool:
    # Treat non-tty execution as non-interactive to prevent blocking in automation.
    if getattr(args, "yes", False):
        return True
    try:
        return not sys.stdin.isatty()
    except Exception:
        return True


def _fmt_ts(ts: Optional[str]) -> str:
    if not ts:
        return ""
    return ts


def _extract_primary_ipv4(server_details: Dict[str, Any]) -> Optional[str]:
    ip_address = None
    if "ipv4Addresses" in server_details and server_details["ipv4Addresses"]:
        ip_address = server_details["ipv4Addresses"][0].get("ip")
    elif "serverLiveInfo" in server_details and "interfaces" in server_details["serverLiveInfo"]:
        interfaces = server_details["serverLiveInfo"]["interfaces"]
        if interfaces and "ipv4Addresses" in interfaces[0] and interfaces[0]["ipv4Addresses"]:
            ip_address = interfaces[0]["ipv4Addresses"][0]
    return ip_address


def _tcp_port_open(host: str, port: int = 22, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _build_ssh_cmd_base(host: str, user: str, identity_file: Optional[str] = None) -> List[str]:
    if not identity_file:
        raise ValueError("ssh identity_file is required (refusing to use default ssh identities)")

    cmd = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=3",
        "-o", "LogLevel=ERROR",
    ]
    cmd += ["-i", identity_file]
    cmd.append(f"{user}@{host}")
    return cmd


def _server_short_name_from_details(server_details: Optional[Dict[str, Any]]) -> Optional[str]:
    if not isinstance(server_details, dict):
        return None
    for key in ("nickname", "hostname", "name"):
        val = server_details.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip().split(".")[0]
    return None


class _SSHBootstrapFollower:
    def __init__(
        self,
        task_uuid: str,
        host: str,
        user: str,
        identity_file: Optional[str],
        poll_interval: float,
        initial_delay: float = 10.0,
        max_wait_seconds: float = 300.0,
    ) -> None:
        self.task_uuid = task_uuid
        self.host = host
        self.user = user
        self.identity_file = identity_file
        self.poll_interval = max(1.0, float(poll_interval))
        self.initial_delay = max(0.0, float(initial_delay))
        self.max_wait_seconds = max(5.0, float(max_wait_seconds))
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._proc: Optional[subprocess.Popen[str]] = None
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.local_log_path = Path.cwd() / f"ssh-tail-{task_uuid}-{ts}.log"

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._proc and self._proc.poll() is None:
            try:
                self._proc.terminate()
            except Exception:
                pass
        if self._thread:
            self._thread.join(timeout=3)

    def _run(self) -> None:
        banner = f"SSH ATTACH: {self.user}@{self.host}"
        identity_hint = self.identity_file or "(missing identity file)"

        # Always create the local capture file immediately so users have
        # something to inspect even if SSH isn't reachable/auth fails.
        try:
            self.local_log_path.parent.mkdir(parents=True, exist_ok=True)
        except Exception:
            pass

        def _log(line: str, lf: Optional[Any] = None) -> None:
            print(line)
            if lf is not None:
                try:
                    lf.write(line + "\n")
                    lf.flush()
                except Exception:
                    pass

        with open(self.local_log_path, "a", encoding="utf-8") as lf:
            _log("=" * 70, lf)
            _log(banner, lf)
            _log("=" * 70, lf)
            _log(f"[attach] Local capture: {self.local_log_path}", lf)
            _log(f"[attach] Identity: {identity_hint}", lf)

            if self.initial_delay > 0:
                _log(f"[attach] Waiting {self.initial_delay:.0f}s before first SSH probe...", lf)
                time.sleep(self.initial_delay)

            # Wait for SSH to become reachable and usable (up to max_wait_seconds).
            last_reason = None
            start = time.monotonic()
            while not self._stop.is_set():
                if (time.monotonic() - start) > self.max_wait_seconds:
                    _log(f"[attach] Giving up after {self.max_wait_seconds:.0f}s without SSH becoming usable.", lf)
                    return
                if not _tcp_port_open(self.host, 22, timeout=2.0):
                    time.sleep(self.poll_interval)
                    continue

                cmd_probe = _build_ssh_cmd_base(self.host, self.user, self.identity_file) + ["true"]
                try:
                    r = subprocess.run(cmd_probe, text=True, capture_output=True, timeout=10)
                    if r.returncode == 0:
                        _log("[attach] SSH reachable; starting remote tail.", lf)
                        break

                    reason = (r.stderr or "").strip().splitlines()[-1:]  # last line only
                    reason_txt = reason[0] if reason else f"ssh exit={r.returncode}"
                    if reason_txt != last_reason:
                        last_reason = reason_txt
                        _log(f"[attach] SSH not ready/auth failed: {reason_txt}", lf)
                        if not self.identity_file:
                            _log(
                                "[attach] Hint: pass --ssh-identity-file or set NETCUP_SSH_IDENTITY_FILE if this is a key auth issue.",
                                lf,
                            )
                except Exception as e:
                    reason_txt = f"{type(e).__name__}: {e}"
                    if reason_txt != last_reason:
                        last_reason = reason_txt
                        _log(f"[attach] SSH probe error: {reason_txt}", lf)

                time.sleep(self.poll_interval)

            if self._stop.is_set():
                return

            # Tail multiple candidate logs. This is more robust than picking a single file,
            # because some logs may be truncated/replaced/removed during post-install.
            tail_remote = (
                "bash -lc 'set -euo pipefail; "
                "shopt -s nullglob; "
                "cands=("
                "/root/custom_script.output "
                "/var/log/custom_script.output "
                "/var/log/custom-script.output "
                "/var/log/custom_script/custom_script.output "
                "/var/log/custom_script/custom-script.output "
                "/var/log/netcup/custom_script.output "
                "/var/log/scp/custom_script.output "
                "/var/log/debian-install/custom_script.output "
                "/var/log/debian-install/bootstrap-*.log "
                "/var/log/cloud-init-output.log "
                "); "
                "echo \"[attach] Tailing candidates: ${cands[*]}\"; "
                "tail -n 200 -F \"${cands[@]}\"'"
            )

            cmd_tail = _build_ssh_cmd_base(self.host, self.user, self.identity_file) + [tail_remote]
            try:
                self._proc = subprocess.Popen(
                    cmd_tail,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
            except Exception as e:
                _log(f"[attach] Failed to start SSH tail: {e}", lf)
                return

            assert self._proc.stdout is not None
            try:
                for line in self._proc.stdout:
                    if self._stop.is_set():
                        break
                    out_line = f"[remote] {line}"
                    sys.stdout.write(out_line)
                    sys.stdout.flush()
                    lf.write(out_line)
                    lf.flush()
            except Exception as e:
                _log(f"[attach] Failed while capturing remote output: {e}", lf)

            try:
                if self._proc and self._proc.poll() is None:
                    self._proc.terminate()
            except Exception:
                pass


def monitor_task(
    client: "NetcupSCPClient",
    task_uuid: str,
    poll_interval: float = 5.0,
    *,
    ssh_host: Optional[str] = None,
    ssh_user: str = "root",
    ssh_identity_file: Optional[str] = None,
    attach_bootstrap: bool = True,
) -> Dict[str, Any]:
    """Poll task endpoint until it reaches a terminal state."""
    last_progress = None
    last_state = None
    last_step_states = {}

    follower: Optional[_SSHBootstrapFollower] = None
    attach_started = False

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    monitor_log_path = Path.cwd() / f"task-monitor-{task_uuid}-{ts}.log"

    print("=" * 70)
    print(f"MONITORING TASK {task_uuid}")
    print("=" * 70)
    print(f"Monitor capture: {monitor_log_path}")

    if attach_bootstrap and not ssh_identity_file:
        raise ValueError(
            "--ssh-identity-file (or $NETCUP_SSH_IDENTITY_FILE) is required when attach_bootstrap is enabled; "
            "refusing to use default ssh identities"
        )

    # Start attach early (about 10s after installation kickoff) and retry until SSH becomes usable.
    # This avoids relying on SCP step names / Cloudinit timing.
    if attach_bootstrap and not attach_started and ssh_host:
        attach_started = True
        follower = _SSHBootstrapFollower(
            task_uuid=task_uuid,
            host=ssh_host,
            user=ssh_user,
            identity_file=ssh_identity_file,
            poll_interval=poll_interval,
            initial_delay=10.0,
            max_wait_seconds=300.0,
        )
        follower.start()

    while True:
        task = client.get(f"/api/v1/tasks/{task_uuid}")
        state = task.get("state")
        name = task.get("name")
        msg = task.get("message")
        started_at = task.get("startedAt")
        finished_at = task.get("finishedAt")
        progress = None
        tp = task.get("taskProgress") or {}
        if isinstance(tp, dict):
            progress = tp.get("progressInPercent")

        # Steps (optional)
        steps = task.get("steps") or []
        step_lines = []
        cloudinit_seen = False
        if isinstance(steps, list):
            for s in steps:
                sname = s.get("name")
                sstate = s.get("state")
                suuid = s.get("uuid")
                if sname and sstate:
                    if "Cloudinit" in sname and sstate in ("RUNNING", "FINISHED"):
                        cloudinit_seen = True
                    prev = last_step_states.get(suuid)
                    if prev != sstate:
                        last_step_states[suuid] = sstate
                        step_lines.append(f"  - {sstate:12s} {sname}")

        # (Attach is started early outside the polling loop.)

        changed = False
        if state != last_state:
            changed = True
        if progress != last_progress:
            changed = True
        if step_lines:
            changed = True

        if changed:
            now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            ptxt = f"{progress:.0f}%" if isinstance(progress, (int, float)) else "?%"
            out_lines: List[str] = []
            out_lines.append(f"[{now}] {state} {ptxt}  {name or ''}".rstrip())
            if msg:
                out_lines.append(f"  message: {msg}")
            if started_at:
                out_lines.append(f"  started:  {_fmt_ts(started_at)}")
            if finished_at:
                out_lines.append(f"  finished: {_fmt_ts(finished_at)}")
            out_lines.extend(step_lines)

            for ln in out_lines:
                print(ln)

            try:
                with open(monitor_log_path, "a", encoding="utf-8") as mf:
                    for ln in out_lines:
                        mf.write(ln + "\n")
            except Exception:
                pass

            last_state = state
            last_progress = progress

        if state in ("FINISHED", "ERROR", "CANCELED", "ROLLBACK"):
            if follower:
                follower.stop()
            # Print responseError if present
            resp_err = task.get("responseError")
            if resp_err:
                print("=" * 70)
                print("TASK RESPONSE ERROR")
                print(json.dumps(resp_err, indent=2))
            return task

        # Sleep
        try:
            import time
            time.sleep(max(0.5, float(poll_interval)))
        except KeyboardInterrupt:
            print("\nInterrupted; task continues server-side.")
            if follower:
                follower.stop()
            return task


def save_payload_with_comments(
    payload: Dict[str, Any],
    filepath: str,
    server_name: str,
    image_name: str,
    user_id: int,
    ssh_key_names: Optional[List[str]] = None,
    hostname_method: Optional[str] = None,
):
    """Save installation payload to JSONC file with helpful comments"""
    with open(filepath, "w") as f:
        f.write("{\n")
        for key, value in payload.items():
            # Add comments for IDs to make them more understandable
            if key == "serverId":
                f.write(f'  // Server ID for: {server_name}\n')
            elif key == "hostname":
                if hostname_method:
                    f.write(f'  // Hostname determined by: {hostname_method}\n')
            elif key == "imageFlavourId":
                f.write(f'  // Image: {image_name}\n')
            elif key == "sshKeyIds":
                f.write(f'  // SSH key IDs for user {user_id}\n')
                if ssh_key_names:
                    for key_name in ssh_key_names:
                        f.write(f'  //   - {key_name}\n')
            
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
    def __init__(self, access_token: str, refresh_token: Optional[str] = None):
        self.base_url = BASE_URL
        self.refresh_token = refresh_token
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {access_token}",
            "Accept":  "application/json",
            "Content-Type": "application/json",
        })

    def refresh_access_token(self) -> None:
        if not self.refresh_token:
            raise RuntimeError("No refresh token available for access token refresh")
        new_access_token = get_access_token(self.refresh_token)
        self.session.headers.update({"Authorization": f"Bearer {new_access_token}"})

    def get(self, endpoint: str, params: Optional[Dict] = None) -> Any:
        """Make GET request to API"""
        url = f"{self.base_url}{endpoint}"
        log_debug(f"GET {url} {params or ''}")
        response = self.session.get(url, params=params, timeout=30)
        if response.status_code == 401 and self.refresh_token:
            log_debug("401 Unauthorized; refreshing token and retrying once")
            self.refresh_access_token()
            response = self.session.get(url, params=params, timeout=30)
        response.raise_for_status()
        result = response.json()
        log_debug(f"Response: {json.dumps(_redact_for_log(result), indent=2)}")
        return result

    def post(self, endpoint: str, data: Dict) -> Any:
        """Make POST request to API"""
        url = f"{self.base_url}{endpoint}"
        log_debug(f"POST {url}")
        log_debug(f"Payload: {json.dumps(_redact_for_log(data), indent=2)}")
        response = self.session.post(url, json=data, timeout=30)
        if response.status_code == 401 and self.refresh_token:
            log_debug("401 Unauthorized; refreshing token and retrying once")
            self.refresh_access_token()
            response = self.session.post(url, json=data, timeout=30)
        response.raise_for_status()
        result = response.json()
        log_debug(f"Response: {json.dumps(_redact_for_log(result), indent=2)}")
        return result

    def get_user_info(self) -> Dict:
        """Get user information from OIDC userinfo endpoint"""
        log_debug(f"GET {KEYCLOAK_URL}/userinfo")
        response = self.session.get(f"{KEYCLOAK_URL}/userinfo", timeout=30)
        if response.status_code == 401 and self.refresh_token:
            log_debug("401 Unauthorized; refreshing token and retrying once")
            self.refresh_access_token()
            response = self.session.get(f"{KEYCLOAK_URL}/userinfo", timeout=30)
        response.raise_for_status()
        result = response.json()
        log_debug(f"Response: {json.dumps(_redact_for_log(result), indent=2)}")
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
    
    # Best-effort fetch server details so we can attach via SSH during monitoring.
    server_details = None
    ip_address = None
    try:
        server_details = client.get(f"/api/v1/servers/{server_id}")
        ip_address = _extract_primary_ipv4(server_details)
    except Exception:
        pass

    # Display payload summary
    print("=" * 70)
    print("PAYLOAD SUMMARY")
    print("=" * 70)
    print(json.dumps(installation_payload, indent=2))
    print()
    
    # Ask for confirmation (unless non-interactive)
    if not is_noninteractive(args):
        print("=" * 70)
        response = input("Do you want to start the installation now? (y/n): ")
        if response.lower() not in ("y", "yes"):
            print("Installation cancelled.")
            return
    else:
        print("=" * 70)
        print("Non-interactive mode: starting installation without prompt")
    
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
            print(f"  python3 monitor-task.py {task_uuid}")
            if getattr(args, "monitor", False) or is_noninteractive(args):
                ssh_identity = getattr(args, "ssh_identity_file", None)
                monitor_task(
                    client,
                    task_uuid,
                    poll_interval=getattr(args, "poll_interval", 5.0),
                    ssh_host=(getattr(args, "ssh_host", None) or ip_address),
                    ssh_user=getattr(args, "ssh_user", "root"),
                    ssh_identity_file=ssh_identity,
                    attach_bootstrap=getattr(args, "attach_bootstrap", True),
                )
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
    global args
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

    client = NetcupSCPClient(access_token, refresh_token=refresh_token)
    
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

        # 2. Get server details (for disk info and hostname)
        print("2. Getting server details...")
        server_details = client.get(f"/api/v1/servers/{server_id}")
        # Example response:
        # {
        #   "id": 804027,
        #   "name": "v2202511209318406253",
        #   "disabled": false,
        #   "hostname": "v1001.vxxu.de",
        #   "nickname": "v1001.vxxu.de",
        #   "template": {
        #     "id": 1538,
        #     "name": "VPS 1000 G12 Pro"
        #   },
        #   "architecture": "AMD64",
        #   "disksAvailableSpaceInMiB": 7864320,
        #   "firewallFeatureActive": true,
        #   "ipv4Addresses": [
        #     {
        #       "broadcast": "152.53.167.255",
        #       "gateway": "152.53.164.1",
        #       "id": 227115,
        #       "ip": "152.53.166.181",
        #       "netmask": "255.255.252.0"
        #     }
        #   ],
        #   "ipv6Addresses": [
        #     {
        #       "gateway": "fe80::1",
        #       "id": 990975,
        #       "networkPrefix": "2a0a:4cc0:2000:9798::",
        #       "networkPrefixLength": 64
        #     }
        #   ],
        #   "maxCpuCount": 4,
        #   "rescueSystemActive": false,
        #   "serverLiveInfo": {
        #     "autostart": true,
        #     "bootorder": [
        #       "HDD",
        #       "CDROM",
        #       "NETWORK"
        #     ],
        #     "cloudinitAttached": false,
        #     "configChanged": false,
        #     "coresPerSocket": 1,
        #     "cpuCount": 4,
        #     "cpuMaxCount": 4,
        #     "currentServerMemoryInMiB": 8192,
        #     "disks": [
        #       {
        #         "allocationInMiB": 1275,
        #         "capacityInMiB": 524288,
        #         "dev": "vda",
        #         "driver": "virtio"
        #       }
        #     ],
        #     "interfaces": [
        #       {
        #         "driver": "virtio",
        #         "ipv4Addresses": [
        #           "152.53.166.181"
        #         ],
        #         "ipv6LinkLocalAddresses": [
        #           "fe80::6820:60ff:fee8:068f"
        #         ],
        #         "ipv6NetworkPrefixes": [
        #           "2a0a:4cc0:2000:9798::/64"
        #         ],
        #         "mac": "6a:20:60:e8:06:8f",
        #         "mtu": 1500,
        #         "rxMonthlyInMiB": 1838,
        #         "speedInMBits": 2500,
        #         "trafficThrottled": false,
        #         "txMonthlyInMiB": 443,
        #         "vlanId": null,
        #         "vlanInterface": false
        #       }
        #     ],
        #     "keyboardLayout": "en-us",
        #     "latestQemu": true,
        #     "machineType": "pc-i440fx-9.2",
        #     "maxServerMemoryInMiB": 8192,
        #     "nestedGuest": false,
        #     "osOptimization": "LINUX",
        #     "requiredStorageOptimization": "NO",
        #     "sockets": 4,
        #     "state": "RUNNING",
        #     "template": "VPS 1000 G12 Pro",
        #     "uefi": true,
        #     "uptimeInSeconds": 235018
        #   },
        #   "site": {
        #     "city": "Manassas",
        #     "id": 6
        #   },
        #   "snapshotAllowed": true,
        #   "snapshotCount": 1
        # }        

        disk_dev = server_details["serverLiveInfo"]["disks"][0]["dev"]
        disk_capacity_gib = server_details["serverLiveInfo"]["disks"][0]["capacityInMiB"] / 1024
        
        # Get IP address and perform reverse DNS lookup
        # Try to get IPv4 address from either ipv4Addresses or interfaces
        ip_address = _extract_primary_ipv4(server_details)
        hostname_method = None
        
        if ip_address:
            try:
                hostname_result = socket.gethostbyaddr(ip_address)
                hostname = hostname_result[0]  # FQDN from reverse DNS
                hostname_method = f"reverse DNS lookup on {ip_address}"
                print(f"   ✓ IP Address: {ip_address}")
                print(f"   ✓ Hostname (reverse DNS): {hostname}")
            except (socket.herror, socket.gaierror) as e:
                # Fallback to configured hostname if reverse DNS fails
                hostname = server_details.get("hostname", SERVER_NAME)
                hostname_method = f"configured hostname (reverse DNS failed for {ip_address})"
                print(f"   ⚠ Reverse DNS failed for {ip_address}: {e}")
                print(f"   ✓ Using configured hostname: {hostname}")
        else:
            # No IP found, use configured hostname
            hostname = server_details.get("hostname", SERVER_NAME)
            hostname_method = "configured hostname (no IP address found)"
            print(f"   ⚠ No IP address found in server details")
            print(f"   ✓ Using configured hostname: {hostname}")
        
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

        ssh_key_names = []
        if not ssh_keys:
            print("   ⚠ WARNING: No SSH keys found!")
            ssh_key_ids = None
        else:
            for key in ssh_keys:
                print(f"   - ID: {key['id']:3d} | {key['name']}")
                ssh_key_names.append(key['name'])
            ssh_key_ids = [ssh_keys[0]["id"]]
            print(f"   ✓ Using SSH Key ID: {ssh_key_ids[0]}")
        print()

        # 6. Prepare installation payload
        installation_payload = {
            "serverId": server_id,  # Include for --payload mode
            "hostname": hostname,  # Use reverse DNS hostname from server info
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
            user_id,
            ssh_key_names=[ssh_key_names[0]] if ssh_key_names else None,
            hostname_method=hostname_method
        )
        print("✓ Installation payload saved to:  install-debian.json")
        print()

        # 9. Ask for confirmation (unless non-interactive)
        if not is_noninteractive(args):
            print("=" * 70)
            response = input("Do you want to start the installation now? (y/n): ")
            if response.lower() not in ("y", "yes"):
                print("Installation cancelled.")
                return
        else:
            print("=" * 70)
            print("Non-interactive mode: starting installation without prompt")

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
            print(f"  python3 monitor-task.py {task_uuid}")
            if getattr(args, "monitor", False) or is_noninteractive(args):
                ssh_identity = getattr(args, "ssh_identity_file", None)
                monitor_task(
                    client,
                    task_uuid,
                    poll_interval=getattr(args, "poll_interval", 5.0),
                    ssh_host=(getattr(args, "ssh_host", None) or ip_address),
                    ssh_user=getattr(args, "ssh_user", "root"),
                    ssh_identity_file=ssh_identity,
                    attach_bootstrap=getattr(args, "attach_bootstrap", True),
                )

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
