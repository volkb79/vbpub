#!/usr/bin/env python3
"""
System Information and Telegram Notification Script
Supports personal chats and channels
"""

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    import requests
except ImportError:
    print("Error: requests module not found. Install with: pip3 install requests")
    sys.exit(1)

class SystemInfo:
    """Collect comprehensive system information"""
    
    def __init__(self):
        self.info = {}
    
    def collect(self):
        """Collect all system information"""
        self.info['timestamp'] = datetime.now().isoformat()
        self.info['hostname'] = platform.node()
        self.info['os'] = self.get_os_info()
        self.info['hardware'] = self.get_hardware_info()
        self.info['memory'] = self.get_memory_info()
        self.info['disk'] = self.get_disk_info()
        self.info['swap'] = self.get_swap_info()
        self.info['network'] = self.get_network_info()
        
        return self.info
    
    def get_os_info(self):
        """Get OS information"""
        info = {
            'system': platform.system(),
            'release': platform.release(),
            'version': platform.version()
        }
        
        # Try to get distribution info
        try:
            with open('/etc/os-release') as f:
                for line in f:
                    if line.startswith('PRETTY_NAME='):
                        info['distribution'] = line.split('=')[1].strip().strip('"')
                        break
        except:
            pass
        
        return info
    
    def get_hardware_info(self):
        """Get hardware information"""
        info = {
            'architecture': platform.machine(),
            'cpu_cores': os.cpu_count()
        }
        
        # Try to get CPU model
        try:
            with open('/proc/cpuinfo') as f:
                for line in f:
                    if 'model name' in line:
                        info['cpu_model'] = line.split(':')[1].strip()
                        break
        except:
            pass
        
        return info
    
    def get_memory_info(self):
        """Get memory information"""
        info = {}
        
        try:
            with open('/proc/meminfo') as f:
                for line in f:
                    if 'MemTotal' in line:
                        info['total_kb'] = int(line.split()[1])
                        info['total_gb'] = round(info['total_kb'] / 1024 / 1024, 2)
                    elif 'MemAvailable' in line:
                        info['available_kb'] = int(line.split()[1])
                        info['available_gb'] = round(info['available_kb'] / 1024 / 1024, 2)
        except:
            pass
        
        return info
    
    def get_disk_info(self):
        """Get disk information"""
        info = {}
        
        try:
            result = subprocess.run(
                ['df', '-k', '/'],
                capture_output=True,
                text=True,
                check=True
            )
            lines = result.stdout.strip().split('\n')
            if len(lines) > 1:
                parts = lines[1].split()
                info['total_kb'] = int(parts[1])
                info['used_kb'] = int(parts[2])
                info['available_kb'] = int(parts[3])
                info['total_gb'] = round(info['total_kb'] / 1024 / 1024, 2)
                info['available_gb'] = round(info['available_kb'] / 1024 / 1024, 2)
                info['used_percent'] = int(parts[4].rstrip('%'))
        except:
            pass
        
        return info
    
    def get_swap_info(self):
        """Get swap information"""
        info = {}
        
        try:
            result = subprocess.run(
                ['swapon', '--show', '--noheadings'],
                capture_output=True,
                text=True
            )
            
            if result.returncode == 0 and result.stdout.strip():
                lines = result.stdout.strip().split('\n')
                info['devices'] = []
                total_size = 0
                
                for line in lines:
                    parts = line.split()
                    if len(parts) >= 3:
                        device_info = {
                            'device': parts[0],
                            'size': parts[2],
                            'priority': parts[3] if len(parts) > 3 else 'unknown'
                        }
                        info['devices'].append(device_info)
                
                info['count'] = len(info['devices'])
            else:
                info['enabled'] = False
        except:
            pass
        
        return info
    
    def get_network_info(self):
        """Get network information"""
        info = {}
        
        # Try to get public IP
        try:
            result = subprocess.run(
                ['curl', '-s', '--max-time', '5', 'https://api.ipify.org'],
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                info['public_ip'] = result.stdout.strip()
        except:
            pass
        
        return info

class TelegramNotifier:
    """Send notifications to Telegram"""
    
    def __init__(self, bot_token, chat_id):
        self.bot_token = bot_token
        self.chat_id = chat_id
        self.api_url = f"https://api.telegram.org/bot{bot_token}"
    
    def send_message(self, text, parse_mode='HTML'):
        """Send text message"""
        url = f"{self.api_url}/sendMessage"
        
        data = {
            'chat_id': self.chat_id,
            'text': text,
            'parse_mode': parse_mode
        }
        
        try:
            response = requests.post(url, data=data, timeout=10)
            response.raise_for_status()
            return True
        except requests.exceptions.RequestException as e:
            print(f"Error sending message: {e}")
            return False
    
    def test_connection(self):
        """Test bot connection"""
        url = f"{self.api_url}/getMe"
        
        try:
            response = requests.get(url, timeout=10)
            response.raise_for_status()
            data = response.json()
            
            if data.get('ok'):
                bot_info = data.get('result', {})
                print(f"✓ Bot connected: @{bot_info.get('username')}")
                print(f"  Bot name: {bot_info.get('first_name')}")
                return True
            else:
                print(f"✗ Bot connection failed: {data}")
                return False
        except requests.exceptions.RequestException as e:
            print(f"✗ Connection error: {e}")
            return False

def format_system_info_html(info):
    """Format system info as HTML for Telegram"""
    html = f"<b>🖥 System Information</b>\n"
    html += f"<b>Hostname:</b> {info['hostname']}\n"
    html += f"<b>Time:</b> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n"
    
    # OS
    html += f"<b>📀 Operating System</b>\n"
    if 'distribution' in info['os']:
        html += f"  {info['os']['distribution']}\n"
    html += f"  Kernel: {info['os']['release']}\n\n"
    
    # Hardware
    html += f"<b>⚙️ Hardware</b>\n"
    html += f"  CPU: {info['hardware'].get('cpu_model', 'Unknown')}\n"
    html += f"  Cores: {info['hardware']['cpu_cores']}\n"
    html += f"  Architecture: {info['hardware']['architecture']}\n\n"
    
    # Memory
    if 'memory' in info and 'total_gb' in info['memory']:
        html += f"<b>💾 Memory</b>\n"
        html += f"  Total: {info['memory']['total_gb']} GB\n"
        html += f"  Available: {info['memory']['available_gb']} GB\n\n"
    
    # Disk
    if 'disk' in info and 'total_gb' in info['disk']:
        html += f"<b>💿 Disk</b>\n"
        html += f"  Total: {info['disk']['total_gb']} GB\n"
        html += f"  Available: {info['disk']['available_gb']} GB\n"
        html += f"  Used: {info['disk'].get('used_percent', 0)}%\n\n"
    
    # Swap
    if 'swap' in info and 'devices' in info['swap']:
        html += f"<b>💱 Swap</b>\n"
        html += f"  Devices: {info['swap']['count']}\n"
        for dev in info['swap']['devices']:
            html += f"    • {dev['device']} ({dev['size']}, pri: {dev['priority']})\n"
    elif 'swap' in info:
        html += f"<b>💱 Swap</b>\n  Not configured\n"
    
    # Network
    if 'network' in info and 'public_ip' in info['network']:
        html += f"\n<b>🌐 Network</b>\n"
        html += f"  Public IP: {info['network']['public_ip']}\n"
    
    return html

def run_geekbench(version=6):
    """Run Geekbench benchmark (optional)"""
    print(f"Running Geekbench {version}...")
    
    # This is optional and requires Geekbench to be installed
    try:
        result = subprocess.run(
            [f'geekbench{version}'],
            capture_output=True,
            text=True,
            timeout=300
        )
        
        if result.returncode == 0:
            # Parse results (simplified)
            print("Geekbench completed!")
            return result.stdout
        else:
            print("Geekbench not available or failed")
            return None
    except:
        print("Geekbench not installed (optional)")
        return None

def main():
    parser = argparse.ArgumentParser(
        description='System information and Telegram notifications',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --collect
  %(prog)s --notify
  %(prog)s --test-mode
  %(prog)s --notify --geekbench

Environment Variables:
  TELEGRAM_BOT_TOKEN    Bot token from @BotFather
  TELEGRAM_CHAT_ID      Your chat ID or channel ID

Getting Chat ID:
  1. Send message to @userinfobot
  2. Or use: curl https://api.telegram.org/botYOUR_TOKEN/getUpdates
  3. For channels: Use @yourchannel or numeric ID (-1001234567890)

IMPORTANT: Send a message to your bot first before it can message you!
        """
    )
    
    parser.add_argument('--collect', action='store_true',
                       help='Collect and display system information')
    parser.add_argument('--notify', action='store_true',
                       help='Send notification to Telegram')
    parser.add_argument('--test-mode', action='store_true',
                       help='Test Telegram connection only')
    parser.add_argument('--geekbench', action='store_true',
                       help='Run Geekbench (optional, requires installation)')
    parser.add_argument('--bot-token', metavar='TOKEN',
                       default=os.environ.get('TELEGRAM_BOT_TOKEN'),
                       help='Telegram bot token')
    parser.add_argument('--chat-id', metavar='ID',
                       default=os.environ.get('TELEGRAM_CHAT_ID'),
                       help='Telegram chat ID or channel username')
    parser.add_argument('--output', '-o', metavar='FILE',
                       help='Save system info to JSON file')
    
    args = parser.parse_args()
    
    # Collect system info if needed
    if args.collect or args.notify or args.output:
        print("Collecting system information...")
        collector = SystemInfo()
        info = collector.collect()
        
        if args.collect:
            print(json.dumps(info, indent=2))
        
        if args.output:
            with open(args.output, 'w') as f:
                json.dump(info, f, indent=2)
            print(f"System info saved to {args.output}")
        
        # Geekbench (optional)
        if args.geekbench:
            geekbench_result = run_geekbench()
            if geekbench_result:
                info['geekbench'] = geekbench_result
        
        if args.notify:
            if not args.bot_token or not args.chat_id:
                print("Error: Bot token and chat ID required for notifications")
                print("Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID environment variables")
                print("Or use --bot-token and --chat-id arguments")
                sys.exit(1)
            
            notifier = TelegramNotifier(args.bot_token, args.chat_id)
            message = format_system_info_html(info)
            
            print("Sending notification to Telegram...")
            if notifier.send_message(message):
                print("✓ Notification sent successfully!")
            else:
                print("✗ Failed to send notification")
                sys.exit(1)
    
    # Test mode
    if args.test_mode:
        if not args.bot_token or not args.chat_id:
            print("Error: Bot token and chat ID required for testing")
            print("Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID environment variables")
            sys.exit(1)
        
        print("Testing Telegram connection...")
        notifier = TelegramNotifier(args.bot_token, args.chat_id)
        
        if notifier.test_connection():
            print("\nSending test message...")
            test_msg = f"<b>✓ Test Message</b>\n\nBot is working correctly!\nHostname: {platform.node()}\nTime: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
            
            if notifier.send_message(test_msg):
                print("✓ Test message sent successfully!")
            else:
                print("✗ Failed to send test message")
                sys.exit(1)
        else:
            print("✗ Bot connection test failed")
            sys.exit(1)
    
    if not (args.collect or args.notify or args.test_mode):
        parser.print_help()

if __name__ == '__main__':
    main()
