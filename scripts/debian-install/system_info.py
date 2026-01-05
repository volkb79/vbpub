#!/usr/bin/env python3
"""
System Information Module
Collect comprehensive system information
"""

import json
import os
import platform
import subprocess
from datetime import datetime


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
        """Get disk information - reports full disk size, not just root partition"""
        info = {}
        
        try:
            # Get root partition info
            result = subprocess.run(
                ['df', '-k', '/'],
                capture_output=True,
                text=True,
                check=True
            )
            lines = result.stdout.strip().split('\n')
            if len(lines) > 1:
                parts = lines[1].split()
                root_device = parts[0]  # e.g., /dev/vda3
                info['root_partition'] = root_device
                info['root_total_kb'] = int(parts[1])
                info['root_used_kb'] = int(parts[2])
                info['root_available_kb'] = int(parts[3])
                info['root_used_percent'] = int(parts[4].rstrip('%'))
                
                # Get the disk name from the partition (e.g., vda3 -> vda)
                import re
                disk_match = re.match(r'(/dev/)?([a-z]+)\d*', root_device)
                if disk_match:
                    disk_name = disk_match.group(2)
                    
                    # Try to get full disk size from lsblk
                    try:
                        lsblk_result = subprocess.run(
                            ['lsblk', '-b', '-d', '-n', '-o', 'NAME,SIZE', f'/dev/{disk_name}'],
                            capture_output=True,
                            text=True,
                            check=True
                        )
                        if lsblk_result.stdout.strip():
                            lsblk_parts = lsblk_result.stdout.strip().split()
                            if len(lsblk_parts) >= 2:
                                disk_size_bytes = int(lsblk_parts[1])
                                info['disk_total_kb'] = disk_size_bytes // 1024
                                info['disk_total_gb'] = round(disk_size_bytes / (1024**3), 2)
                                # Calculate used space on the entire disk
                                info['disk_used_kb'] = info['root_used_kb']
                                info['disk_available_kb'] = info['disk_total_kb'] - info['disk_used_kb']
                                info['disk_available_gb'] = round(info['disk_available_kb'] / (1024**2), 2)
                    except:
                        # Fallback to root partition info if lsblk fails
                        pass
                
                # If we couldn't get disk info, use root partition as fallback
                if 'disk_total_gb' not in info:
                    info['total_kb'] = info['root_total_kb']
                    info['used_kb'] = info['root_used_kb']
                    info['available_kb'] = info['root_available_kb']
                    info['total_gb'] = round(info['total_kb'] / 1024 / 1024, 2)
                    info['available_gb'] = round(info['available_kb'] / 1024 / 1024, 2)
                    info['used_percent'] = info['root_used_percent']
                else:
                    # Use disk info for reporting
                    info['total_kb'] = info['disk_total_kb']
                    info['used_kb'] = info['disk_used_kb']
                    info['available_kb'] = info['disk_available_kb']
                    info['total_gb'] = info['disk_total_gb']
                    info['available_gb'] = info['disk_available_gb']
                    info['used_percent'] = int((info['used_kb'] / info['total_kb']) * 100) if info['total_kb'] > 0 else 0
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
    
    def format_html(self):
        """Format system info as HTML for Telegram"""
        html = f"<b>🖥 System Information</b>\n"
        html += f"<b>Hostname:</b> {self.info['hostname']}\n"
        html += f"<b>Time:</b> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n"
        
        # OS
        html += f"<b>📀 Operating System</b>\n"
        if 'distribution' in self.info['os']:
            html += f"  {self.info['os']['distribution']}\n"
        html += f"  Kernel: {self.info['os']['release']}\n\n"
        
        # Hardware
        html += f"<b>⚙️ Hardware</b>\n"
        html += f"  CPU: {self.info['hardware'].get('cpu_model', 'Unknown')}\n"
        html += f"  Cores: {self.info['hardware']['cpu_cores']}\n"
        html += f"  Architecture: {self.info['hardware']['architecture']}\n\n"
        
        # Memory
        if 'memory' in self.info and 'total_gb' in self.info['memory']:
            html += f"<b>💾 Memory</b>\n"
            html += f"  Total: {self.info['memory']['total_gb']} GB\n"
            html += f"  Available: {self.info['memory']['available_gb']} GB\n\n"
        
        # Disk
        if 'disk' in self.info and 'total_gb' in self.info['disk']:
            html += f"<b>💿 Disk</b>\n"
            html += f"  Total: {self.info['disk']['total_gb']} GB\n"
            html += f"  Available: {self.info['disk']['available_gb']} GB\n"
            html += f"  Used: {self.info['disk'].get('used_percent', 0)}%\n\n"
        
        # Swap
        if 'swap' in self.info and 'devices' in self.info['swap']:
            html += f"<b>💱 Swap</b>\n"
            html += f"  Devices: {self.info['swap']['count']}\n"
            for dev in self.info['swap']['devices']:
                html += f"    • {dev['device']} ({dev['size']}, pri: {dev['priority']})\n"
        elif 'swap' in self.info:
            html += f"<b>💱 Swap</b>\n  Not configured\n"
        
        # Network
        if 'network' in self.info and 'public_ip' in self.info['network']:
            html += f"\n<b>🌐 Network</b>\n"
            html += f"  Public IP: {self.info['network']['public_ip']}\n"
        
        return html
    
    def format_text(self):
        """Format system info as plain text"""
        text = "# System Summary\n"
        text += f"Hostname: {self.info['hostname']}\n"
        
        # Network
        if 'network' in self.info and 'public_ip' in self.info['network']:
            text += f"IP:       {self.info['network']['public_ip']}\n"
        text += "\n"
        
        # Hardware
        text += f"CPU:   {self.info['hardware'].get('cpu_model', 'Unknown')}\n"
        text += f"Cores: {self.info['hardware']['cpu_cores']}\n"
        
        # Memory
        if 'memory' in self.info and 'total_gb' in self.info['memory']:
            text += f"RAM:   {self.info['memory']['total_gb']} GB\n"
        text += "\n"
        
        # OS
        if 'distribution' in self.info['os']:
            text += f"OS:     {self.info['os']['distribution']}\n"
        text += f"Kernel: {self.info['os']['release']}\n"
        
        # Disk
        if 'disk' in self.info and 'total_gb' in self.info['disk']:
            text += f"\nDisk:   {self.info['disk']['total_gb']} GB total, "
            text += f"{self.info['disk']['available_gb']} GB available "
            text += f"({self.info['disk'].get('used_percent', 0)}% used)\n"
        
        return text


def main():
    """CLI interface"""
    import argparse
    
    parser = argparse.ArgumentParser(description='System Information Collector')
    parser.add_argument('--format', choices=['json', 'html', 'text'], default='json',
                       help='Output format (default: json)')
    parser.add_argument('--output', '-o', metavar='FILE', help='Save to file')
    
    args = parser.parse_args()
    
    collector = SystemInfo()
    info = collector.collect()
    
    # Determine output format
    if args.format == 'html':
        output = collector.format_html()
    elif args.format == 'text':
        output = collector.format_text()
    else:
        output = json.dumps(info, indent=2)
    
    if args.output:
        with open(args.output, 'w') as f:
            f.write(output)
        print(f"System info saved to {args.output}")
    else:
        print(output)
    
    return 0


if __name__ == '__main__':
    import sys
    sys.exit(main())
