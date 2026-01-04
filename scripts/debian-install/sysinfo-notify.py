#!/usr/bin/env python3
"""
sysinfo-notify.py - System information and Geekbench notification via Telegram

Collects system information and optionally runs Geekbench, then sends
results via Telegram bot.
"""

import os
import sys
import subprocess
import argparse
import json
import time
from typing import Dict, Optional, Tuple
import urllib.request
import urllib.parse
import platform

# Configuration (can be overridden by environment variables)
TELEGRAM_BOT_TOKEN = os.environ.get('TELEGRAM_BOT_TOKEN', '')
TELEGRAM_CHAT_ID = os.environ.get('TELEGRAM_CHAT_ID', '')

def get_system_info() -> Dict:
    """Collect system information"""
    info = {}
    
    # Basic system info
    info['hostname'] = platform.node()
    info['kernel'] = platform.release()
    info['os'] = get_os_info()
    info['cpu'] = get_cpu_info()
    info['memory'] = get_memory_info()
    info['swap'] = get_swap_info()
    info['disk'] = get_disk_info()
    
    return info

def get_os_info() -> str:
    """Get OS information"""
    try:
        with open('/etc/os-release', 'r') as f:
            for line in f:
                if line.startswith('PRETTY_NAME'):
                    return line.split('=')[1].strip().strip('"')
    except Exception:
        pass
    return platform.system()

def get_cpu_info() -> Dict:
    """Get CPU information"""
    info = {}
    
    try:
        # CPU model
        with open('/proc/cpuinfo', 'r') as f:
            for line in f:
                if line.startswith('model name'):
                    info['model'] = line.split(':')[1].strip()
                    break
        
        # CPU count
        info['cores'] = os.cpu_count()
        
        # CPU frequency
        try:
            with open('/proc/cpuinfo', 'r') as f:
                for line in f:
                    if 'cpu MHz' in line:
                        info['mhz'] = line.split(':')[1].strip()
                        break
        except Exception:
            pass
            
    except Exception as e:
        info['error'] = str(e)
    
    return info

def get_memory_info() -> Dict:
    """Get memory information"""
    info = {}
    
    try:
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                if line.startswith('MemTotal:'):
                    info['total_kb'] = int(line.split()[1])
                    info['total_gb'] = round(info['total_kb'] / 1024 / 1024, 2)
                elif line.startswith('MemAvailable:'):
                    info['available_kb'] = int(line.split()[1])
                    info['available_gb'] = round(info['available_kb'] / 1024 / 1024, 2)
                elif line.startswith('MemFree:'):
                    info['free_kb'] = int(line.split()[1])
    except Exception as e:
        info['error'] = str(e)
    
    return info

def get_swap_info() -> Dict:
    """Get swap configuration information"""
    info = {}
    
    try:
        # Total swap
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                if line.startswith('SwapTotal:'):
                    info['total_kb'] = int(line.split()[1])
                    info['total_gb'] = round(info['total_kb'] / 1024 / 1024, 2)
                elif line.startswith('SwapFree:'):
                    info['free_kb'] = int(line.split()[1])
        
        # Swap devices
        result = subprocess.run(['swapon', '--show', '--noheadings'],
                              capture_output=True, text=True)
        if result.returncode == 0:
            info['devices'] = result.stdout.strip().split('\n') if result.stdout.strip() else []
        
        # Check for ZSWAP
        try:
            with open('/sys/module/zswap/parameters/enabled', 'r') as f:
                zswap_enabled = f.read().strip()
                info['zswap_enabled'] = (zswap_enabled == 'Y')
                
            if info['zswap_enabled']:
                with open('/sys/module/zswap/parameters/compressor', 'r') as f:
                    info['zswap_compressor'] = f.read().strip()
                with open('/sys/module/zswap/parameters/zpool', 'r') as f:
                    info['zswap_zpool'] = f.read().strip()
        except Exception:
            info['zswap_enabled'] = False
        
        # Check for ZRAM
        info['zram_configured'] = os.path.exists('/sys/block/zram0')
        
    except Exception as e:
        info['error'] = str(e)
    
    return info

def get_disk_info() -> Dict:
    """Get disk information"""
    info = {}
    
    try:
        result = subprocess.run(['df', '-h', '/'], capture_output=True, text=True)
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            if len(lines) > 1:
                parts = lines[1].split()
                info['total'] = parts[1]
                info['used'] = parts[2]
                info['available'] = parts[3]
                info['use_percent'] = parts[4]
    except Exception as e:
        info['error'] = str(e)
    
    return info

def run_geekbench() -> Optional[Dict]:
    """Run Geekbench and return results"""
    print("Checking for Geekbench...")
    
    # Check if geekbench is installed
    gb_paths = [
        '/usr/local/bin/geekbench6',
        '/opt/geekbench6/geekbench6',
        os.path.expanduser('~/geekbench6/geekbench6')
    ]
    
    geekbench_path = None
    for path in gb_paths:
        if os.path.exists(path):
            geekbench_path = path
            break
    
    if not geekbench_path:
        print("Geekbench not found. Skipping benchmark.")
        print("Install from: https://www.geekbench.com/download/")
        return None
    
    print(f"Running Geekbench from: {geekbench_path}")
    print("This may take a few minutes...")
    
    try:
        result = subprocess.run([geekbench_path], capture_output=True, text=True, timeout=600)
        
        if result.returncode == 0:
            output = result.stdout
            
            # Parse results
            results = {}
            for line in output.split('\n'):
                if 'Single-Core Score' in line:
                    try:
                        results['single_core'] = int(line.split()[-1])
                    except (ValueError, IndexError):
                        pass
                elif 'Multi-Core Score' in line:
                    try:
                        results['multi_core'] = int(line.split()[-1])
                    except (ValueError, IndexError):
                        pass
                elif 'https://browser.geekbench.com/' in line:
                    results['url'] = line.strip()
            
            return results if results else None
        else:
            print(f"Geekbench failed: {result.stderr}")
            return None
            
    except subprocess.TimeoutExpired:
        print("Geekbench timed out")
        return None
    except Exception as e:
        print(f"Error running Geekbench: {e}")
        return None

def format_message(sysinfo: Dict, geekbench: Optional[Dict] = None) -> str:
    """Format information as message"""
    lines = []
    
    lines.append("🖥️ *System Information*")
    lines.append("")
    lines.append(f"*Hostname:* {sysinfo['hostname']}")
    lines.append(f"*OS:* {sysinfo['os']}")
    lines.append(f"*Kernel:* {sysinfo['kernel']}")
    lines.append("")
    
    # CPU
    cpu = sysinfo['cpu']
    lines.append("*CPU:*")
    if 'model' in cpu:
        lines.append(f"  • Model: {cpu['model']}")
    if 'cores' in cpu:
        lines.append(f"  • Cores: {cpu['cores']}")
    if 'mhz' in cpu:
        lines.append(f"  • Frequency: {cpu['mhz']} MHz")
    lines.append("")
    
    # Memory
    mem = sysinfo['memory']
    lines.append("*Memory:*")
    if 'total_gb' in mem:
        lines.append(f"  • Total: {mem['total_gb']} GB")
    if 'available_gb' in mem:
        lines.append(f"  • Available: {mem['available_gb']} GB")
    lines.append("")
    
    # Swap
    swap = sysinfo['swap']
    lines.append("*Swap:*")
    if 'total_gb' in swap and swap['total_gb'] > 0:
        lines.append(f"  • Total: {swap['total_gb']} GB")
        if swap.get('zswap_enabled'):
            lines.append(f"  • ZSWAP: Enabled ({swap.get('zswap_compressor', 'unknown')} + {swap.get('zswap_zpool', 'unknown')})")
        if swap.get('zram_configured'):
            lines.append(f"  • ZRAM: Configured")
    else:
        lines.append("  • Not configured")
    lines.append("")
    
    # Disk
    disk = sysinfo['disk']
    if 'total' in disk:
        lines.append("*Disk (/)*")
        lines.append(f"  • Total: {disk['total']}")
        lines.append(f"  • Used: {disk['used']} ({disk.get('use_percent', 'N/A')})")
        lines.append(f"  • Available: {disk['available']}")
        lines.append("")
    
    # Geekbench results
    if geekbench:
        lines.append("📊 *Geekbench 6 Results*")
        lines.append("")
        if 'single_core' in geekbench:
            lines.append(f"*Single-Core:* {geekbench['single_core']}")
        if 'multi_core' in geekbench:
            lines.append(f"*Multi-Core:* {geekbench['multi_core']}")
        if 'url' in geekbench:
            lines.append("")
            lines.append(f"🔗 [View Full Results]({geekbench['url']})")
        lines.append("")
    
    return '\n'.join(lines)

def send_telegram_message(token: str, chat_id: str, message: str) -> Tuple[bool, str]:
    """Send message via Telegram Bot API"""
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    
    data = {
        'chat_id': chat_id,
        'text': message,
        'parse_mode': 'Markdown',
        'disable_web_page_preview': False
    }
    
    try:
        # Encode data
        data_encoded = urllib.parse.urlencode(data).encode('utf-8')
        
        # Make request
        req = urllib.request.Request(url, data=data_encoded, method='POST')
        with urllib.request.urlopen(req, timeout=30) as response:
            result = json.loads(response.read().decode('utf-8'))
            
            if result.get('ok'):
                return True, "Message sent successfully"
            else:
                return False, f"API error: {result.get('description', 'Unknown error')}"
                
    except Exception as e:
        return False, f"Failed to send message: {str(e)}"

def test_telegram_config(token: str, chat_id: str) -> bool:
    """Test Telegram configuration"""
    print("Testing Telegram configuration...")
    
    if not token:
        print("❌ TELEGRAM_BOT_TOKEN not set")
        return False
    
    if not chat_id:
        print("❌ TELEGRAM_CHAT_ID not set")
        return False
    
    # Try to send test message
    success, message = send_telegram_message(token, chat_id, "✅ Telegram notification test successful!")
    
    if success:
        print("✅ Telegram configuration is working")
        return True
    else:
        print(f"❌ Telegram test failed: {message}")
        print()
        print("Troubleshooting:")
        print("1. Make sure you've sent a message to your bot first")
        print("2. Verify your bot token is correct")
        print("3. Verify your chat ID is correct")
        print()
        print("To get your chat ID:")
        print("  1. Send a message to your bot")
        print("  2. Visit: https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates")
        print("  3. Look for 'chat':{'id':YOUR_CHAT_ID}")
        print()
        print("Alternative: Use @userinfobot or @getidsbot on Telegram")
        return False

def main():
    parser = argparse.ArgumentParser(description='System information and Geekbench notification')
    parser.add_argument('--geekbench', action='store_true',
                       help='Run Geekbench benchmark')
    parser.add_argument('--test', action='store_true',
                       help='Test Telegram configuration')
    parser.add_argument('--no-send', action='store_true',
                       help='Collect info but do not send (print only)')
    parser.add_argument('--token', help='Telegram bot token (overrides env)')
    parser.add_argument('--chat-id', help='Telegram chat ID (overrides env)')
    
    args = parser.parse_args()
    
    # Override with command line arguments if provided
    token = args.token or TELEGRAM_BOT_TOKEN
    chat_id = args.chat_id or TELEGRAM_CHAT_ID
    
    # Test mode
    if args.test:
        success = test_telegram_config(token, chat_id)
        sys.exit(0 if success else 1)
    
    # Collect system information
    print("Collecting system information...")
    sysinfo = get_system_info()
    
    # Run Geekbench if requested
    geekbench = None
    if args.geekbench:
        geekbench = run_geekbench()
    
    # Format message
    message = format_message(sysinfo, geekbench)
    
    print()
    print("=" * 60)
    print(message)
    print("=" * 60)
    print()
    
    # Send via Telegram
    if not args.no_send:
        if not token or not chat_id:
            print("❌ Telegram credentials not configured")
            print()
            print("Set environment variables:")
            print("  export TELEGRAM_BOT_TOKEN='your_bot_token'")
            print("  export TELEGRAM_CHAT_ID='your_chat_id'")
            print()
            print("Or use command line:")
            print("  ./sysinfo-notify.py --token YOUR_TOKEN --chat-id YOUR_CHAT_ID")
            print()
            print("Run './sysinfo-notify.py --test' to test configuration")
            sys.exit(1)
        
        print("Sending to Telegram...")
        success, msg = send_telegram_message(token, chat_id, message)
        
        if success:
            print("✅ Message sent successfully!")
        else:
            print(f"❌ Failed to send message: {msg}")
            sys.exit(1)
    else:
        print("Skipping Telegram send (--no-send flag)")

if __name__ == '__main__':
    main()
