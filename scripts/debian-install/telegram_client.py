#!/usr/bin/env python3
"""
Telegram Client Module
Pure telegram messaging functionality with source attribution
"""

import os
import socket
import subprocess

try:
    import requests
except ImportError:
    print("Error: requests module not found. Install with: pip3 install requests")
    import sys
    sys.exit(1)


class TelegramClient:
    """Telegram messaging client with automatic source attribution"""
    
    def __init__(self, bot_token=None, chat_id=None):
        self.bot_token = bot_token or os.environ.get('TELEGRAM_BOT_TOKEN')
        self.chat_id = chat_id or os.environ.get('TELEGRAM_CHAT_ID')
        
        if not self.bot_token or not self.chat_id:
            raise ValueError("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set")
        
        self.api_url = f"https://api.telegram.org/bot{self.bot_token}"
        self.system_id = self._get_system_id()
    
    def _get_system_id(self):
        """Get system identification (hostname + IP)"""
        hostname = socket.gethostname()
        try:
            # Get primary IP
            result = subprocess.run(
                ['hostname', '-I'],
                capture_output=True,
                text=True,
                timeout=5
            )
            ip = result.stdout.strip().split()[0] if result.stdout.strip() else "unknown"
        except:
            ip = "unknown"
        
        return f"{hostname} ({ip})"
    
    def send_message(self, text, parse_mode='HTML', prefix_source=True):
        """
        Send text message with automatic source attribution
        
        Args:
            text: Message text
            parse_mode: Telegram parse mode (HTML, Markdown, or None)
            prefix_source: Automatically prefix with system ID (default: True)
        
        Returns:
            bool: True if successful, False otherwise
        """
        if prefix_source:
            prefixed_text = f"<b>{self.system_id}</b>\n{text}"
        else:
            prefixed_text = text
        
        url = f"{self.api_url}/sendMessage"
        
        data = {
            'chat_id': self.chat_id,
            'text': prefixed_text,
            'parse_mode': parse_mode
        }
        
        try:
            response = requests.post(url, data=data, timeout=10)
            response.raise_for_status()
            return True
        except requests.exceptions.RequestException as e:
            print(f"Error sending message: {e}")
            return False
    
    def send_document(self, file_path, caption=None, prefix_source=True):
        """
        Send document file
        
        Args:
            file_path: Path to file to send
            caption: Optional caption
            prefix_source: Automatically prefix caption with system ID (default: True)
        
        Returns:
            bool: True if successful, False otherwise
        """
        if not os.path.exists(file_path):
            print(f"Error: File not found: {file_path}")
            return False
        
        if caption and prefix_source:
            caption = f"{self.system_id}\n{caption}"
        
        url = f"{self.api_url}/sendDocument"
        
        try:
            with open(file_path, 'rb') as f:
                files = {'document': f}
                data = {'chat_id': self.chat_id}
                if caption:
                    data['caption'] = caption
                    data['parse_mode'] = 'HTML'
                
                response = requests.post(url, data=data, files=files, timeout=30)
                response.raise_for_status()
                return True
        except Exception as e:
            print(f"Error sending document: {e}")
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
                print(f"  Source ID: {self.system_id}")
                return True
            else:
                print(f"✗ Bot connection failed: {data}")
                return False
        except requests.exceptions.RequestException as e:
            print(f"✗ Connection error: {e}")
            return False


def main():
    """CLI interface for testing"""
    import argparse
    
    parser = argparse.ArgumentParser(description='Telegram Client')
    parser.add_argument('--test', action='store_true', help='Test connection')
    parser.add_argument('--send', metavar='TEXT', help='Send message')
    parser.add_argument('--file', metavar='PATH', help='Send file')
    parser.add_argument('--bot-token', help='Bot token (or use TELEGRAM_BOT_TOKEN env)')
    parser.add_argument('--chat-id', help='Chat ID (or use TELEGRAM_CHAT_ID env)')
    
    args = parser.parse_args()
    
    try:
        client = TelegramClient(args.bot_token, args.chat_id)
    except ValueError as e:
        print(f"Error: {e}")
        return 1
    
    if args.test:
        return 0 if client.test_connection() else 1
    
    if args.send:
        success = client.send_message(args.send)
        print("✓ Message sent" if success else "✗ Failed to send message")
        return 0 if success else 1
    
    if args.file:
        success = client.send_document(args.file)
        print("✓ File sent" if success else "✗ Failed to send file")
        return 0 if success else 1
    
    parser.print_help()
    return 0


if __name__ == '__main__':
    import sys
    sys.exit(main())
