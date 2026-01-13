#!/usr/bin/env python3
"""
Telegram Client Module
Pure telegram messaging functionality with source attribution
"""

import os
import socket
import subprocess
import time
import json

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
        """Get system identification (FQDN + IP)"""
        # Get FQDN (fully qualified domain name)
        try:
            hostname = socket.getfqdn()
            # If getfqdn() returns localhost or similar, fall back to gethostname()
            if hostname in ('localhost', 'localhost.localdomain', ''):
                hostname = socket.gethostname()
        except:
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
    
    def send_message(self, text, parse_mode='HTML', prefix_source=True, max_retries=3, retry_delay=2):
        """
        Send text message with automatic source attribution and retry logic
        
        Args:
            text: Message text
            parse_mode: Telegram parse mode (HTML, Markdown, or None)
            prefix_source: Automatically prefix with system ID (default: True)
            max_retries: Maximum number of retry attempts (default: 3)
            retry_delay: Initial delay between retries in seconds (default: 2)
        
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
        
        last_error = None
        for attempt in range(max_retries):
            try:
                response = requests.post(url, data=data, timeout=10)
                response.raise_for_status()
                return True
            except requests.exceptions.ConnectionError as e:
                last_error = f"Connection error: {e}"
                if attempt < max_retries - 1:
                    wait_time = retry_delay * (2 ** attempt)  # Exponential backoff
                    print(f"Connection error, retrying in {wait_time}s... (attempt {attempt + 1}/{max_retries})")
                    time.sleep(wait_time)
                    continue
            except requests.exceptions.Timeout as e:
                last_error = f"Timeout error: {e}"
                if attempt < max_retries - 1:
                    wait_time = retry_delay * (2 ** attempt)
                    print(f"Timeout, retrying in {wait_time}s... (attempt {attempt + 1}/{max_retries})")
                    time.sleep(wait_time)
                    continue
            except requests.exceptions.RequestException as e:
                last_error = f"Request error: {e}"
                # Don't retry for other errors (like 4xx client errors)
                print(f"Error sending message: {e}")
                return False
        
        print(f"Failed to send message after {max_retries} attempts: {last_error}")
        return False
    
    def send_document(self, file_path, caption=None, prefix_source=True, max_retries=3, retry_delay=2):
        """
        Send document file with retry logic
        
        Args:
            file_path: Path to file to send
            caption: Optional caption
            prefix_source: Automatically prefix caption with system ID (default: True)
            max_retries: Maximum number of retry attempts (default: 3)
            retry_delay: Initial delay between retries in seconds (default: 2)
        
        Returns:
            bool: True if successful, False otherwise
        """
        if not os.path.exists(file_path):
            print(f"Error: File not found: {file_path}")
            return False
        
        if caption and prefix_source:
            caption = f"{self.system_id}\n{caption}"
        
        url = f"{self.api_url}/sendDocument"
        
        last_error = None
        for attempt in range(max_retries):
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
            except requests.exceptions.ConnectionError as e:
                last_error = f"Connection error: {e}"
                if attempt < max_retries - 1:
                    wait_time = retry_delay * (2 ** attempt)  # Exponential backoff
                    print(f"Connection error, retrying in {wait_time}s... (attempt {attempt + 1}/{max_retries})")
                    time.sleep(wait_time)
                    continue
            except requests.exceptions.Timeout as e:
                last_error = f"Timeout error: {e}"
                if attempt < max_retries - 1:
                    wait_time = retry_delay * (2 ** attempt)
                    print(f"Timeout, retrying in {wait_time}s... (attempt {attempt + 1}/{max_retries})")
                    time.sleep(wait_time)
                    continue
            except Exception as e:
                last_error = f"Error: {e}"
                # Don't retry for other errors
                print(f"Error sending document: {e}")
                return False
        
        print(f"Failed to send document after {max_retries} attempts: {last_error}")
        return False
    
    def send_media_group(self, file_paths, caption=None, prefix_source=True, max_retries=3, retry_delay=2):
        """
        Send multiple images as a media group (album) in a single message
        
        Args:
            file_paths: List of file paths to send (supports PNG, JPEG, WebP)
            caption: Optional caption for first image
            prefix_source: Automatically prefix caption with system ID (default: True)
            max_retries: Maximum number of retry attempts (default: 3)
            retry_delay: Initial delay between retries in seconds (default: 2)
        
        Returns:
            bool: True if successful, False otherwise
        """
        if not file_paths:
            print("Error: No files provided")
            return False
        
        # Filter out non-existent files
        valid_files = [f for f in file_paths if os.path.exists(f)]
        if not valid_files:
            print(f"Error: None of the provided files exist")
            return False
        
        if len(valid_files) < len(file_paths):
            missing = set(file_paths) - set(valid_files)
            print(f"Warning: Skipping missing files: {missing}")
        
        if caption and prefix_source:
            caption = f"{self.system_id}\n{caption}"
        
        url = f"{self.api_url}/sendMediaGroup"
        
        last_error = None
        for attempt in range(max_retries):
            try:
                # Build media array
                media = []
                files = {}
                
                for idx, file_path in enumerate(valid_files):
                    attach_name = f"file{idx}"

                    # IMPORTANT:
                    # - If we send as type=photo, Telegram will often recompress/convert (e.g., PNG/WebP -> JPEG).
                    # - Sending as type=document preserves the original file format and avoids quality loss.
                    media_type = 'document'
                    media_item = {
                        'type': media_type,
                        'media': f'attach://{attach_name}'
                    }
                    
                    # Add caption to first image only
                    if idx == 0 and caption:
                        media_item['caption'] = caption
                        media_item['parse_mode'] = 'HTML'
                    
                    media.append(media_item)
                    files[attach_name] = open(file_path, 'rb')
                
                try:
                    data = {
                        'chat_id': self.chat_id,
                        'media': json.dumps(media)
                    }
                    
                    response = requests.post(url, data=data, files=files, timeout=60)
                    
                    # Debug response
                    if response.status_code != 200:
                        error_data = response.json() if response.headers.get('content-type', '').startswith('application/json') else {}
                        print(f"Telegram API error (status {response.status_code}): {error_data}")
                        
                        # Common error cases for media groups
                        if response.status_code == 400:
                            error_desc = error_data.get('description', '')
                            if 'group send failed' in error_desc.lower():
                                print("Hint: Media group might be too large or contain too many items")
                                print(f"     Attempted to send {len(valid_files)} files")
                            elif 'wrong file identifier' in error_desc.lower():
                                print("Hint: File format might not be supported in media groups")
                            elif 'too many requests' in error_desc.lower() or response.status_code == 429:
                                print("Hint: Rate limited by Telegram. Reduce sending frequency")
                                # Extract retry_after if available
                                retry_after = error_data.get('parameters', {}).get('retry_after', 60)
                                print(f"     Retry after {retry_after} seconds")
                                if attempt < max_retries - 1:
                                    time.sleep(retry_after)
                                    continue
                    
                    response.raise_for_status()
                    return True
                    
                finally:
                    # Close all file handles
                    for f in files.values():
                        f.close()
                        
            except requests.exceptions.HTTPError as e:
                last_error = f"HTTP error: {e}"
                # Try to get more detailed error info
                try:
                    error_data = e.response.json() if e.response else {}
                    error_desc = error_data.get('description', 'No description')
                    last_error = f"HTTP {e.response.status_code}: {error_desc}"
                except:
                    pass
                print(f"HTTP error sending media group: {last_error}")
                # Don't retry HTTP 4xx errors (client errors)
                if e.response and 400 <= e.response.status_code < 500:
                    return False
                # Retry 5xx errors (server errors)
                if attempt < max_retries - 1:
                    wait_time = retry_delay * (2 ** attempt)
                    print(f"Server error, retrying in {wait_time}s... (attempt {attempt + 1}/{max_retries})")
                    time.sleep(wait_time)
                    continue
            except requests.exceptions.ConnectionError as e:
                last_error = f"Connection error: {e}"
                if attempt < max_retries - 1:
                    wait_time = retry_delay * (2 ** attempt)
                    print(f"Connection error, retrying in {wait_time}s... (attempt {attempt + 1}/{max_retries})")
                    time.sleep(wait_time)
                    continue
            except requests.exceptions.Timeout as e:
                last_error = f"Timeout error: {e}"
                if attempt < max_retries - 1:
                    wait_time = retry_delay * (2 ** attempt)
                    print(f"Timeout, retrying in {wait_time}s... (attempt {attempt + 1}/{max_retries})")
                    time.sleep(wait_time)
                    continue
            except Exception as e:
                last_error = f"Error: {e}"
                print(f"Error sending media group: {e}")
                return False
        
        print(f"Failed to send media group after {max_retries} attempts: {last_error}")
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
    parser.add_argument('--caption', metavar='TEXT', help='Caption for file (used with --file)')
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
        success = client.send_document(args.file, caption=args.caption)
        print("✓ File sent" if success else "✗ Failed to send file")
        return 0 if success else 1
    
    parser.print_help()
    return 0


if __name__ == '__main__':
    import sys
    sys.exit(main())
