#!/usr/bin/env python3
"""
sysinfo-notify.py - System Information with Geekbench and Telegram Notifications

Purpose: Collect system info, run Geekbench (optional), send results via Telegram
"""

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, Optional
import urllib.request
import urllib.parse


def log_info(msg: str):
    print(f"[INFO] {msg}")


def log_warn(msg: str):
    print(f"[WARN] {msg}")


def log_error(msg: str):
    print(f"[ERROR] {msg}")


def run_command(cmd: list, check=True) -> tuple:
    """Run command and return (returncode, stdout, stderr)"""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=check
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.CalledProcessError as e:
        return e.returncode, e.stdout, e.stderr
    except FileNotFoundError:
        return 1, "", f"Command not found: {cmd[0]}"


def get_system_info() -> Dict:
    """Collect comprehensive system information"""
    info = {}
    
    # Basic system info
    info["hostname"] = platform.node()
    info["os"] = platform.system()
    info["os_release"] = platform.release()
    info["architecture"] = platform.machine()
    
    # Try to get distribution info
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    info["distribution"] = line.split("=")[1].strip().strip('"')
                    break
    except:
        info["distribution"] = "Unknown"
    
    # CPU info
    try:
        with open("/proc/cpuinfo") as f:
            cpuinfo = f.read()
            
        # Count processors
        info["cpu_count"] = cpuinfo.count("processor")
        
        # Get model name
        for line in cpuinfo.split("\n"):
            if "model name" in line:
                info["cpu_model"] = line.split(":")[1].strip()
                break
    except:
        info["cpu_count"] = os.cpu_count()
        info["cpu_model"] = "Unknown"
    
    # Memory info
    try:
        with open("/proc/meminfo") as f:
            meminfo = f.read()
            
        for line in meminfo.split("\n"):
            if line.startswith("MemTotal:"):
                mem_kb = int(line.split()[1])
                info["memory_gb"] = round(mem_kb / 1024 / 1024, 2)
                break
    except:
        info["memory_gb"] = 0
    
    # Disk info
    _, stdout, _ = run_command(["df", "-BG", "/"], check=False)
    try:
        lines = stdout.strip().split("\n")
        if len(lines) > 1:
            parts = lines[1].split()
            info["disk_total_gb"] = parts[1].rstrip("G")
            info["disk_used_gb"] = parts[2].rstrip("G")
            info["disk_available_gb"] = parts[3].rstrip("G")
    except:
        info["disk_total_gb"] = "Unknown"
    
    # Swap info
    _, stdout, _ = run_command(["swapon", "--show", "--noheadings"], check=False)
    if stdout.strip():
        swap_lines = stdout.strip().split("\n")
        info["swap_devices"] = len(swap_lines)
        
        # Parse total swap size
        total_swap_kb = 0
        for line in swap_lines:
            parts = line.split()
            if len(parts) >= 3:
                size_str = parts[2]
                # Convert to KB
                if size_str.endswith("G"):
                    total_swap_kb += float(size_str[:-1]) * 1024 * 1024
                elif size_str.endswith("M"):
                    total_swap_kb += float(size_str[:-1]) * 1024
                elif size_str.endswith("K"):
                    total_swap_kb += float(size_str[:-1])
        
        info["swap_total_gb"] = round(total_swap_kb / 1024 / 1024, 2)
    else:
        info["swap_devices"] = 0
        info["swap_total_gb"] = 0
    
    # Check ZRAM
    if Path("/dev/zram0").exists():
        info["zram_enabled"] = True
    else:
        info["zram_enabled"] = False
    
    # Check ZSWAP
    zswap_enabled_path = Path("/sys/module/zswap/parameters/enabled")
    if zswap_enabled_path.exists():
        enabled = zswap_enabled_path.read_text().strip()
        info["zswap_enabled"] = enabled == "Y"
    else:
        info["zswap_enabled"] = False
    
    return info


def download_geekbench(version: str = "6") -> Optional[str]:
    """Download Geekbench if not present"""
    log_info("Checking for Geekbench...")
    
    # Check if already downloaded
    gb_dir = Path(f"/tmp/geekbench{version}")
    gb_binary = gb_dir / f"geekbench{version}"
    
    if gb_binary.exists():
        log_info(f"Geekbench {version} already downloaded")
        return str(gb_binary)
    
    # Download URL (Linux x86_64)
    if version == "6":
        url = "https://cdn.geekbench.com/Geekbench-6.3.0-Linux.tar.gz"
    elif version == "5":
        url = "https://cdn.geekbench.com/Geekbench-5.5.1-Linux.tar.gz"
    else:
        log_error(f"Unsupported Geekbench version: {version}")
        return None
    
    log_info(f"Downloading Geekbench {version}...")
    
    try:
        # Download
        tar_file = f"/tmp/geekbench{version}.tar.gz"
        urllib.request.urlretrieve(url, tar_file)
        
        # Extract
        log_info("Extracting...")
        run_command(["tar", "-xzf", tar_file, "-C", "/tmp"])
        
        # Find extracted directory
        for item in Path("/tmp").iterdir():
            if item.is_dir() and f"Geekbench-{version}" in item.name:
                item.rename(gb_dir)
                break
        
        # Clean up
        Path(tar_file).unlink()
        
        if gb_binary.exists():
            log_info(f"Geekbench {version} ready at {gb_binary}")
            return str(gb_binary)
        else:
            log_error("Failed to find Geekbench binary after extraction")
            return None
            
    except Exception as e:
        log_error(f"Failed to download Geekbench: {e}")
        return None


def run_geekbench(binary_path: str) -> Optional[Dict]:
    """Run Geekbench and return results"""
    log_info("Running Geekbench (this will take several minutes)...")
    
    try:
        # Run benchmark
        returncode, stdout, stderr = run_command([binary_path, "--no-upload"], check=False)
        
        if returncode != 0:
            log_error(f"Geekbench failed: {stderr}")
            return None
        
        # Parse output
        results = {}
        for line in stdout.split("\n"):
            line = line.strip()
            if "Single-Core Score" in line:
                results["single_core"] = line.split()[-1]
            elif "Multi-Core Score" in line:
                results["multi_core"] = line.split()[-1]
        
        if results:
            log_info(f"Geekbench complete: Single={results.get('single_core')}, Multi={results.get('multi_core')}")
            return results
        else:
            log_warn("Could not parse Geekbench results")
            return None
            
    except Exception as e:
        log_error(f"Error running Geekbench: {e}")
        return None


def send_telegram_message(bot_token: str, chat_id: str, message: str, parse_mode: str = "HTML"):
    """Send message via Telegram"""
    try:
        url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
        
        data = urllib.parse.urlencode({
            "chat_id": chat_id,
            "text": message,
            "parse_mode": parse_mode
        }).encode()
        
        req = urllib.request.Request(url, data=data)
        with urllib.request.urlopen(req, timeout=10) as response:
            result = json.loads(response.read().decode())
            
        if result.get("ok"):
            log_info("Telegram notification sent successfully")
            return True
        else:
            log_error(f"Telegram API error: {result}")
            return False
            
    except Exception as e:
        log_error(f"Failed to send Telegram message: {e}")
        return False


def format_message(sysinfo: Dict, geekbench_results: Optional[Dict] = None) -> str:
    """Format system info and Geekbench results as message"""
    lines = ["<b>📊 System Information Report</b>", ""]
    
    # System info
    lines.append(f"<b>Hostname:</b> {sysinfo.get('hostname', 'Unknown')}")
    lines.append(f"<b>OS:</b> {sysinfo.get('distribution', 'Unknown')}")
    lines.append(f"<b>Kernel:</b> {sysinfo.get('os_release', 'Unknown')}")
    lines.append("")
    
    # CPU
    lines.append(f"<b>CPU:</b> {sysinfo.get('cpu_model', 'Unknown')}")
    lines.append(f"<b>Cores:</b> {sysinfo.get('cpu_count', 'Unknown')}")
    lines.append("")
    
    # Memory
    lines.append(f"<b>RAM:</b> {sysinfo.get('memory_gb', 0)} GB")
    lines.append(f"<b>Swap:</b> {sysinfo.get('swap_total_gb', 0)} GB ({sysinfo.get('swap_devices', 0)} devices)")
    
    # Swap technologies
    swap_tech = []
    if sysinfo.get("zram_enabled"):
        swap_tech.append("ZRAM")
    if sysinfo.get("zswap_enabled"):
        swap_tech.append("ZSWAP")
    if swap_tech:
        lines.append(f"<b>Swap Tech:</b> {', '.join(swap_tech)}")
    lines.append("")
    
    # Disk
    lines.append(f"<b>Disk Total:</b> {sysinfo.get('disk_total_gb', 'Unknown')} GB")
    lines.append(f"<b>Disk Available:</b> {sysinfo.get('disk_available_gb', 'Unknown')} GB")
    lines.append("")
    
    # Geekbench results
    if geekbench_results:
        lines.append("<b>🚀 Geekbench Results</b>")
        lines.append(f"<b>Single-Core:</b> {geekbench_results.get('single_core', 'N/A')}")
        lines.append(f"<b>Multi-Core:</b> {geekbench_results.get('multi_core', 'N/A')}")
        lines.append("")
    
    lines.append(f"<i>Generated at {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}</i>")
    
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="System info with Geekbench and Telegram notifications",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument(
        "--geekbench",
        action="store_true",
        help="Run Geekbench benchmark"
    )
    
    parser.add_argument(
        "--geekbench-version",
        choices=["5", "6"],
        default="6",
        help="Geekbench version to use (default: 6)"
    )
    
    parser.add_argument(
        "--telegram",
        action="store_true",
        help="Send results via Telegram (requires TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)"
    )
    
    parser.add_argument(
        "--output",
        help="Save results to JSON file"
    )
    
    args = parser.parse_args()
    
    # Collect system info
    log_info("Collecting system information...")
    sysinfo = get_system_info()
    
    # Print to console
    print("\n" + "="*70)
    print("SYSTEM INFORMATION")
    print("="*70)
    for key, value in sysinfo.items():
        print(f"{key:20s}: {value}")
    print("="*70 + "\n")
    
    # Run Geekbench if requested
    geekbench_results = None
    if args.geekbench:
        gb_binary = download_geekbench(args.geekbench_version)
        if gb_binary:
            geekbench_results = run_geekbench(gb_binary)
            
            if geekbench_results:
                print("\n" + "="*70)
                print("GEEKBENCH RESULTS")
                print("="*70)
                for key, value in geekbench_results.items():
                    print(f"{key:20s}: {value}")
                print("="*70 + "\n")
    
    # Send Telegram notification
    if args.telegram:
        bot_token = os.environ.get("TELEGRAM_BOT_TOKEN")
        chat_id = os.environ.get("TELEGRAM_CHAT_ID")
        
        if not bot_token or not chat_id:
            log_error("Telegram credentials not found")
            log_error("Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID environment variables")
            log_error("Remember: Send a message to your bot FIRST before getUpdates works!")
            sys.exit(1)
        
        message = format_message(sysinfo, geekbench_results)
        send_telegram_message(bot_token, chat_id, message)
    
    # Save to file if requested
    if args.output:
        output_data = {
            "system_info": sysinfo,
            "geekbench_results": geekbench_results,
            "timestamp": time.time()
        }
        
        with open(args.output, "w") as f:
            json.dump(output_data, f, indent=2)
        
        log_info(f"Results saved to {args.output}")


if __name__ == "__main__":
    main()
