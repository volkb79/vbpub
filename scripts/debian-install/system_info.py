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
from pathlib import Path


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
        self.info['kernel_params'] = self.get_kernel_params()
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

        # Always collect a human-friendly lsblk output (useful for concise Telegram messages).
        try:
            lsblk_pretty = subprocess.run(
                ['lsblk', '-o', 'NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT'],
                capture_output=True,
                text=True,
                check=True,
            )
            info['lsblk_output'] = lsblk_pretty.stdout.strip()
        except Exception:
            pass
        
        # Get lsblk JSON output for comprehensive disk information
        try:
            lsblk_result = subprocess.run(
                ['lsblk', '--json', '-o', 'NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE'],
                capture_output=True,
                text=True,
                check=True
            )
            info['lsblk'] = json.loads(lsblk_result.stdout)
        except:
            # JSON collection failed; lsblk_output may still be present from the pretty collector.
            pass
        
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
                            'type': parts[1] if len(parts) > 1 else 'unknown',
                            'size': parts[2] if len(parts) > 2 else 'unknown',
                            'used': parts[3] if len(parts) > 3 else 'unknown',
                            'priority': parts[4] if len(parts) > 4 else 'unknown'
                        }
                        info['devices'].append(device_info)
                
                info['count'] = len(info['devices'])
            else:
                info['enabled'] = False
        except:
            pass
        
        return info
    
    def get_kernel_params(self):
        """Get comprehensive kernel parameters related to swap, memory, and THP"""
        params = {}

        # Optional: defaults captured by setup-swap.sh prior to tuning.
        # Format: KEY=VALUE (one per line)
        defaults = {}
        try:
            defaults_path = Path('/var/lib/vbpub/bootstrap/sysctl-defaults.env')
            if defaults_path.exists():
                for line in defaults_path.read_text().splitlines():
                    line = line.strip()
                    if not line or line.startswith('#') or '=' not in line:
                        continue
                    k, v = line.split('=', 1)
                    k = k.strip()
                    v = v.strip()
                    if k:
                        defaults[k] = v
        except Exception:
            defaults = {}
        
        # List of kernel parameters to collect (comprehensive for swap/memory tuning)
        param_names = [
            # Core swap parameters
            'vm.swappiness',
            'vm.page-cluster',
            'vm.vfs_cache_pressure',
            
            # Memory management
            'vm.watermark_scale_factor',
            'vm.min_free_kbytes',
            'vm.overcommit_memory',
            'vm.overcommit_ratio',
            
            # Dirty page writeback
            'vm.dirty_ratio',
            'vm.dirty_background_ratio',
            'vm.dirty_expire_centisecs',
            'vm.dirty_writeback_centisecs',
            
            # Additional memory tuning
            'vm.compact_unevictable_allowed',
            'vm.zone_reclaim_mode'
        ]
        
        for param in param_names:
            try:
                result = subprocess.run(
                    ['sysctl', '-n', param],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if result.returncode == 0:
                    val = result.stdout.strip()
                    if defaults and param in defaults and defaults[param] not in ('', 'N/A') and val not in ('', 'N/A'):
                        params[param] = f"{val} (default {defaults[param]})"
                    else:
                        params[param] = val
            except Exception:
                params[param] = 'N/A'
        
        # Get Transparent Huge Pages (THP) status
        try:
            with open('/sys/kernel/mm/transparent_hugepage/enabled', 'r') as f:
                thp_enabled = f.read().strip()
                # Extract the selected option (marked with [])
                import re
                match = re.search(r'\[([^\]]+)\]', thp_enabled)
                if match:
                    params['transparent_hugepage.enabled'] = match.group(1)
                else:
                    params['transparent_hugepage.enabled'] = thp_enabled
        except Exception:
            params['transparent_hugepage.enabled'] = 'N/A'
        
        try:
            with open('/sys/kernel/mm/transparent_hugepage/defrag', 'r') as f:
                thp_defrag = f.read().strip()
                import re
                match = re.search(r'\[([^\]]+)\]', thp_defrag)
                if match:
                    params['transparent_hugepage.defrag'] = match.group(1)
                else:
                    params['transparent_hugepage.defrag'] = thp_defrag
        except Exception:
            params['transparent_hugepage.defrag'] = 'N/A'
        
        # Get ZSWAP status if available
        try:
            with open('/sys/module/zswap/parameters/enabled', 'r') as f:
                params['zswap.enabled'] = f.read().strip()
        except Exception:
            params['zswap.enabled'] = 'N/A'
        
        try:
            with open('/sys/module/zswap/parameters/compressor', 'r') as f:
                params['zswap.compressor'] = f.read().strip()
        except Exception:
            params['zswap.compressor'] = 'N/A'
        
        try:
            with open('/sys/module/zswap/parameters/max_pool_percent', 'r') as f:
                params['zswap.max_pool_percent'] = f.read().strip()
        except Exception:
            params['zswap.max_pool_percent'] = 'N/A'
        
        try:
            with open('/sys/module/zswap/parameters/zpool', 'r') as f:
                params['zswap.zpool'] = f.read().strip()
        except Exception:
            params['zswap.zpool'] = 'N/A'
        
        try:
            with open('/sys/module/zswap/parameters/shrinker_enabled', 'r') as f:
                params['zswap.shrinker_enabled'] = f.read().strip()
        except Exception:
            params['zswap.shrinker_enabled'] = 'N/A'
        
        return params
    
    def get_network_info(self):
        """Get network information including interface and DNS"""
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
                
                # Get reverse DNS for public IP
                rdns = self._get_reverse_dns(info['public_ip'])
                if rdns:
                    info['reverse_dns'] = rdns
        except:
            pass
        
        # Get hostname
        try:
            info['hostname'] = subprocess.run(
                ['hostname', '-f'],
                capture_output=True,
                text=True
            ).stdout.strip()
        except:
            pass
        
        return info
    
    def _get_reverse_dns(self, ip):
        """Get reverse DNS for an IP address"""
        if not ip:
            return None
        
        # Try dig first
        try:
            result = subprocess.run(
                ['dig', '+short', '-x', ip],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                rdns = result.stdout.strip().rstrip('.')
                if rdns:
                    return rdns
        except:
            pass
        
        # Fallback to host command
        try:
            result = subprocess.run(
                ['host', ip],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0:
                # Parse "X.X.X.X domain name pointer hostname.example.com."
                for line in result.stdout.split('\n'):
                    if 'domain name pointer' in line:
                        rdns = line.split('domain name pointer')[1].strip().rstrip('.')
                        if rdns:
                            return rdns
        except:
            pass
        
        return None
    
    def to_dict(self):
        """Return system info as dictionary"""
        return self.info
    
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
        
        # Disk (including root partition details)
        if 'disk' in self.info:
            html += f"<b>💿 Disk</b>\n"
            
            # Show disk total if available
            if 'total_gb' in self.info['disk']:
                html += f"  Total: {self.info['disk']['total_gb']} GB\n"
                html += f"  Available: {self.info['disk']['available_gb']} GB\n"
                html += f"  Used: {self.info['disk'].get('used_percent', 0)}%\n"
            
            # Show root partition details if different from disk
            if 'root_partition' in self.info['disk'] and 'root_total_kb' in self.info['disk']:
                root_total_gb = round(self.info['disk']['root_total_kb'] / 1024 / 1024, 2)
                root_avail_gb = round(self.info['disk']['root_available_kb'] / 1024 / 1024, 2)
                html += f"\n  <b>Root Partition</b> ({self.info['disk']['root_partition']})\n"
                html += f"    Total: {root_total_gb} GB\n"
                html += f"    Available: {root_avail_gb} GB\n"
                html += f"    Used: {self.info['disk']['root_used_percent']}%\n"
            
            # Add lsblk output if available
            if 'lsblk_output' in self.info['disk']:
                html += f"\n<pre>{self.info['disk']['lsblk_output']}</pre>\n"
            html += "\n"
        
        # Swap
        if 'swap' in self.info and 'devices' in self.info['swap']:
            html += f"<b>💱 Swap</b>\n"
            html += f"  Devices: {self.info['swap']['count']}\n"
            for dev in self.info['swap']['devices']:
                html += f"    • {dev['device']} ({dev['size']}, pri: {dev['priority']})\n"
            html += "\n"
        elif 'swap' in self.info:
            html += f"<b>💱 Swap</b>\n  Not configured\n\n"
        
        # Kernel Parameters (if available)
        if 'kernel_params' in self.info and self.info['kernel_params']:
            html += f"<b>⚙️ Kernel Parameters</b>\n"
            html += f"  <i>(Applied values, persist after reboot)</i>\n"
            for param, value in self.info['kernel_params'].items():
                html += f"  {param} = {value}\n"
            html += "\n"
        
        # Network
        if 'network' in self.info:
            html += f"\n<b>🌐 Network</b>\n"
            if 'interface' in self.info['network']:
                html += f"  Interface: {self.info['network']['interface']}\n"
            if 'public_ip' in self.info['network']:
                html += f"  Public IP: {self.info['network']['public_ip']}\n"
            if 'dns_servers' in self.info['network']:
                html += f"  DNS: {', '.join(self.info['network']['dns_servers'])}\n"
        
        return html

    def format_html_before_setup(self):
        """Compact HTML formatter for the 'BEFORE setup' Telegram message.

        Focus: core identity + lsblk output; avoids verbose disk/swap summaries.
        """

        html = ""
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

        # lsblk
        lsblk_out = self.info.get('disk', {}).get('lsblk_output')
        if lsblk_out:
            html += f"<b>💿 lsblk</b>\n<pre>{lsblk_out}</pre>\n"

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
