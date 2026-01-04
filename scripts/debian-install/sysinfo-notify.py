#!/usr/bin/env python3
"""
sysinfo-notify.py - System information collector and Telegram notifier

Collects system information, optionally runs Geekbench, and sends
formatted results to Telegram (personal chat or channel).

Usage:
    ./sysinfo-notify.py                    # Collect and send info
    ./sysinfo-notify.py --geekbench        # Include Geekbench results
    ./sysinfo-notify.py --test             # Test Telegram configuration
    ./sysinfo-notify.py --channel          # Send to channel instead of chat
"""

import os
import sys
import json
import time
import subprocess
import argparse
import platform
from pathlib import Path

try:
    import requests
except ImportError:
    print("Error: requests module not found. Install with: pip3 install requests")
    sys.exit(1)

class Colors:
    BLUE = '\033[0;34m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    NC = '\033[0m'

def log_info(msg):
    print(f"{Colors.BLUE}[INFO]{Colors.NC} {msg}")

def log_success(msg):
    print(f"{Colors.GREEN}[OK]{Colors.NC} {msg}")

def log_warn(msg):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")

def log_error(msg):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}")

def run_command(cmd, capture=True):
    """Run shell command and return output"""
    try:
        if capture:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=False)
            return result.stdout.strip()
        else:
            subprocess.run(cmd, shell=True, check=False)
            return None
    except Exception as e:
        log_warn(f"Command failed: {cmd} - {e}")
        return None

def get_system_info():
    """Collect comprehensive system information"""
    info = {}
    
    # Basic info
    info['hostname'] = platform.node()
    info['kernel'] = platform.release()
    info['os'] = run_command("cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'") or "Unknown"
    info['uptime'] = run_command("uptime -p") or "Unknown"
    
    # CPU
    info['cpu_count'] = os.cpu_count()
    cpu_model = run_command("lscpu | grep 'Model name:' | cut -d: -f2 | xargs")
    info['cpu_model'] = cpu_model or "Unknown"
    cpu_mhz = run_command("lscpu | grep 'CPU MHz:' | awk '{print $3}' | head -1")
    info['cpu_mhz'] = cpu_mhz or "Unknown"
    
    # Memory
    with open('/proc/meminfo') as f:
        for line in f:
            if line.startswith('MemTotal:'):
                mem_kb = int(line.split()[1])
                info['ram_gb'] = mem_kb // 1024 // 1024
                info['ram_kb'] = mem_kb
                break
    
    # Disk
    df_output = run_command("df -h / | tail -1")
    if df_output:
        parts = df_output.split()
        info['disk_total'] = parts[1]
        info['disk_used'] = parts[2]
        info['disk_free'] = parts[3]
        info['disk_usage_pct'] = parts[4]
    
    # Swap
    info['swap'] = {}
    swap_output = run_command("swapon --show --noheadings")
    if swap_output:
        lines = swap_output.split('\n')
        info['swap']['devices'] = len(lines)
        total_size = 0
        for line in lines:
            parts = line.split()
            if len(parts) >= 3:
                size_str = parts[2]
                # Parse size (e.g., "8G", "512M")
                if 'G' in size_str:
                    total_size += float(size_str.replace('G', ''))
                elif 'M' in size_str:
                    total_size += float(size_str.replace('M', '')) / 1024
        info['swap']['total_gb'] = round(total_size, 1)
    else:
        info['swap']['devices'] = 0
        info['swap']['total_gb'] = 0
    
    # ZRAM
    if os.path.exists('/sys/block/zram0/disksize'):
        info['zram'] = {
            'enabled': True,
            'algorithm': run_command("cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -o '\\[.*\\]' | tr -d '[]'") or "unknown"
        }
    else:
        info['zram'] = {'enabled': False}
    
    # ZSWAP
    if os.path.exists('/sys/module/zswap/parameters/enabled'):
        enabled = run_command("cat /sys/module/zswap/parameters/enabled") == "Y"
        info['zswap'] = {
            'enabled': enabled,
            'compressor': run_command("cat /sys/module/zswap/parameters/compressor 2>/dev/null") if enabled else None
        }
    else:
        info['zswap'] = {'enabled': False}
    
    # Network
    info['ip_addresses'] = []
    ip_output = run_command("ip -4 addr show | grep inet | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1")
    if ip_output:
        info['ip_addresses'] = ip_output.split('\n')
    
    return info

def run_geekbench():
    """Run Geekbench if available"""
    log_info("Checking for Geekbench...")
    
    # Check if Geekbench is installed
    gb_paths = [
        '/usr/local/bin/geekbench6',
        '/usr/bin/geekbench6',
        './geekbench6',
        os.path.expanduser('~/geekbench6')
    ]
    
    geekbench_path = None
    for path in gb_paths:
        if os.path.exists(path) and os.access(path, os.X_OK):
            geekbench_path = path
            break
    
    if not geekbench_path:
        log_warn("Geekbench not found. Skipping benchmark.")
        log_info("To install: Download from https://www.geekbench.com/download/linux/")
        return None
    
    log_info(f"Found Geekbench at {geekbench_path}")
    log_info("Running Geekbench (this may take a few minutes)...")
    
    try:
        result = subprocess.run(
            [geekbench_path, '--no-upload'],
            capture_output=True,
            text=True,
            timeout=600  # 10 minute timeout
        )
        
        output = result.stdout
        
        # Parse results
        scores = {}
        for line in output.split('\n'):
            if 'Single-Core Score' in line:
                scores['single_core'] = line.split()[-1]
            elif 'Multi-Core Score' in line:
                scores['multi_core'] = line.split()[-1]
        
        if scores:
            log_success(f"Geekbench completed: Single={scores.get('single_core', 'N/A')}, Multi={scores.get('multi_core', 'N/A')}")
            return scores
        else:
            log_warn("Could not parse Geekbench results")
            return None
            
    except subprocess.TimeoutExpired:
        log_error("Geekbench timed out")
        return None
    except Exception as e:
        log_error(f"Geekbench failed: {e}")
        return None

def format_message(info, geekbench_scores=None):
    """Format system info as HTML message for Telegram"""
    lines = [
        "<b>🖥 System Information</b>",
        "",
        f"<b>Hostname:</b> {info['hostname']}",
        f"<b>OS:</b> {info['os']}",
        f"<b>Kernel:</b> {info['kernel']}",
        f"<b>Uptime:</b> {info['uptime']}",
        "",
        "<b>💻 Hardware</b>",
        f"<b>CPU:</b> {info['cpu_model']}",
        f"<b>Cores:</b> {info['cpu_count']}",
        f"<b>Speed:</b> {info['cpu_mhz']} MHz",
        f"<b>RAM:</b> {info['ram_gb']}GB",
        "",
        "<b>💾 Storage</b>",
        f"<b>Total:</b> {info.get('disk_total', 'N/A')}",
        f"<b>Used:</b> {info.get('disk_used', 'N/A')} ({info.get('disk_usage_pct', 'N/A')})",
        f"<b>Free:</b> {info.get('disk_free', 'N/A')}",
    ]
    
    # Swap info
    if info['swap']['devices'] > 0:
        lines.extend([
            "",
            "<b>🔄 Swap</b>",
            f"<b>Devices:</b> {info['swap']['devices']}",
            f"<b>Total:</b> {info['swap']['total_gb']}GB"
        ])
        
        if info['zram']['enabled']:
            lines.append(f"<b>ZRAM:</b> Yes ({info['zram']['algorithm']})")
        
        if info['zswap']['enabled']:
            lines.append(f"<b>ZSWAP:</b> Yes ({info['zswap'].get('compressor', 'unknown')})")
    
    # Network
    if info['ip_addresses']:
        lines.extend([
            "",
            "<b>🌐 Network</b>",
            f"<b>IPs:</b> {', '.join(info['ip_addresses'])}"
        ])
    
    # Geekbench
    if geekbench_scores:
        lines.extend([
            "",
            "<b>⚡️ Geekbench 6</b>",
            f"<b>Single-Core:</b> {geekbench_scores.get('single_core', 'N/A')}",
            f"<b>Multi-Core:</b> {geekbench_scores.get('multi_core', 'N/A')}"
        ])
    
    return "\n".join(lines)

def send_telegram_message(message, bot_token, chat_id):
    """Send message to Telegram"""
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    
    data = {
        'chat_id': chat_id,
        'text': message,
        'parse_mode': 'HTML'
    }
    
    try:
        response = requests.post(url, data=data, timeout=10)
        response.raise_for_status()
        log_success("Message sent to Telegram successfully")
        return True
    except requests.exceptions.RequestException as e:
        log_error(f"Failed to send message: {e}")
        if hasattr(e, 'response') and e.response is not None:
            log_error(f"Response: {e.response.text}")
        return False

def test_telegram_config(bot_token, chat_id):
    """Test Telegram configuration"""
    log_info("Testing Telegram configuration...")
    
    # Test bot token by getting bot info
    url = f"https://api.telegram.org/bot{bot_token}/getMe"
    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        bot_info = response.json()
        
        if bot_info['ok']:
            log_success(f"Bot token valid: @{bot_info['result']['username']}")
        else:
            log_error("Bot token invalid")
            return False
    except Exception as e:
        log_error(f"Failed to validate bot token: {e}")
        return False
    
    # Test sending a message
    test_message = "✅ <b>Test message</b>\n\nYour Telegram notification is configured correctly!"
    if send_telegram_message(test_message, bot_token, chat_id):
        log_success("Test message sent successfully")
        return True
    else:
        log_error("Failed to send test message")
        log_info("\nTroubleshooting:")
        log_info("1. Make sure you've sent a message to your bot first")
        log_info("2. Get your chat ID using @userinfobot or @getidsbot")
        log_info("3. For channels, use the channel username with @ (e.g., @my_channel)")
        return False

def main():
    parser = argparse.ArgumentParser(description='Collect system info and send to Telegram')
    parser.add_argument('--geekbench', action='store_true', help='Run Geekbench benchmark')
    parser.add_argument('--test', action='store_true', help='Test Telegram configuration')
    parser.add_argument('--no-send', action='store_true', help='Collect info but don\'t send')
    parser.add_argument('--output', help='Save JSON output to file')
    
    args = parser.parse_args()
    
    # Get configuration from environment
    bot_token = os.environ.get('TELEGRAM_BOT_TOKEN', '')
    chat_id = os.environ.get('TELEGRAM_CHAT_ID', '')
    
    if not bot_token or not chat_id:
        if not args.no_send:
            log_error("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set")
            log_info("Export them as environment variables:")
            log_info("  export TELEGRAM_BOT_TOKEN='your_token'")
            log_info("  export TELEGRAM_CHAT_ID='your_chat_id'")
            sys.exit(1)
    
    # Test mode
    if args.test:
        test_telegram_config(bot_token, chat_id)
        return
    
    # Collect system info
    log_info("Collecting system information...")
    info = get_system_info()
    log_success("System information collected")
    
    # Run Geekbench if requested
    geekbench_scores = None
    if args.geekbench:
        geekbench_scores = run_geekbench()
    
    # Save to file if requested
    if args.output:
        output_data = {
            'system_info': info,
            'geekbench': geekbench_scores,
            'timestamp': time.time()
        }
        with open(args.output, 'w') as f:
            json.dump(output_data, f, indent=2)
        log_success(f"Data saved to {args.output}")
    
    # Send to Telegram
    if not args.no_send:
        message = format_message(info, geekbench_scores)
        send_telegram_message(message, bot_token, chat_id)
    else:
        log_info("Skipping Telegram send (--no-send)")
        print("\nFormatted message:")
        print(format_message(info, geekbench_scores))

if __name__ == '__main__':
    main()
