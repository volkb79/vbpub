#!/usr/bin/env python3
"""
Geekbench Runner Module
Download, install, run Geekbench and extract results
"""

import json
import os
import platform
import re
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime
from pathlib import Path


class GeekbenchRunner:
    """Download, install and run Geekbench benchmarks"""
    
    # Constants
    URL_CHECK_TIMEOUT = 5  # Seconds to wait for URL validation
    
    def __init__(self, version=6, work_dir=None):
        self.version = version
        self.work_dir = work_dir or tempfile.mkdtemp(prefix='geekbench_')
        self.geekbench_path = None
        self.results = {}
    
    def _get_download_url(self):
        """Get Geekbench download URL based on system architecture
        
        Dynamically finds the latest minor version by trying common patterns.
        Downloads from https://www.geekbench.com/download/ or https://cdn.geekbench.com/
        """
        arch = platform.machine()
        system = platform.system()
        
        if system != 'Linux':
            raise ValueError(f"Unsupported system: {system}")
        
        if arch == 'x86_64':
            base_filename = f"Geekbench-{self.version}"
            suffix = "-Linux.tar.gz"
        elif arch == 'aarch64' or arch == 'arm64':
            base_filename = f"Geekbench-{self.version}"
            suffix = "-LinuxARMPreview.tar.gz"
        else:
            raise ValueError(f"Unsupported architecture: {arch}")
        
        # Try to find the latest version by attempting common version patterns
        # Check recent versions first (most likely to be current)
        # Based on problem statement, current version is 6.4.0
        version_candidates = [
            (4, 0), (3, 0), (5, 0), (4, 1), (3, 1),  # Recent versions
            (2, 0), (1, 0), (0, 0)  # Older fallbacks
        ]
        
        for minor, patch in version_candidates:
            version_str = f"{self.version}.{minor}.{patch}"
            url = f"https://cdn.geekbench.com/{base_filename}.{minor}.{patch}{suffix}"
            
            # Quick check if URL is valid with HEAD request
            try:
                result = subprocess.run(
                    ['curl', '-sI', '--max-time', str(self.URL_CHECK_TIMEOUT), '-o', '/dev/null', '-w', '%{http_code}', url],
                    capture_output=True,
                    text=True,
                    timeout=self.URL_CHECK_TIMEOUT + 1  # Allow 1 extra second for subprocess overhead
                )
                if result.returncode == 0 and result.stdout.strip() == '200':
                    print(f"Found Geekbench version {version_str}")
                    return url
            except subprocess.TimeoutExpired:
                continue
            except Exception:
                continue
        
        # Fallback to base version without minor/patch (e.g., Geekbench-6-Linux.tar.gz)
        fallback_url = f"https://cdn.geekbench.com/{base_filename}{suffix}"
        print(f"Using fallback URL (will be validated during download): {fallback_url}")
        return fallback_url
    
    def download_and_extract(self):
        """Download and extract Geekbench"""
        print(f"Downloading Geekbench {self.version}...")
        
        url = self._get_download_url()
        tarball = os.path.join(self.work_dir, f"geekbench{self.version}.tar.gz")
        
        # Download
        try:
            subprocess.run(
                ['curl', '-fsSL', '-o', tarball, url],
                check=True,
                timeout=300
            )
            print(f"✓ Downloaded to {tarball}")
        except subprocess.CalledProcessError as e:
            print(f"✗ Download failed: {e}")
            return False
        
        # Extract
        try:
            print("Extracting...")
            with tarfile.open(tarball, 'r:gz') as tar:
                tar.extractall(self.work_dir)
            
            # Find geekbench executable
            for root, dirs, files in os.walk(self.work_dir):
                for file in files:
                    if file == f'geekbench{self.version}' or file == 'geekbench_x86_64':
                        self.geekbench_path = os.path.join(root, file)
                        os.chmod(self.geekbench_path, 0o755)
                        print(f"✓ Extracted to {self.geekbench_path}")
                        return True
            
            print("✗ Geekbench executable not found after extraction")
            return False
            
        except Exception as e:
            print(f"✗ Extraction failed: {e}")
            return False
    
    def run_benchmark(self):
        """Run Geekbench benchmark"""
        if not self.geekbench_path:
            print("✗ Geekbench not installed. Run download_and_extract() first.")
            return False
        
        print(f"\nRunning Geekbench {self.version} benchmark...")
        print("This may take 5-10 minutes...\n")
        
        try:
            # Run benchmark with JSON output
            result = subprocess.run(
                [self.geekbench_path, '--export-json', '--no-upload'],
                cwd=os.path.dirname(self.geekbench_path),
                capture_output=True,
                text=True,
                timeout=900  # 15 minutes max
            )
            
            print(result.stdout)
            
            # Find JSON result file
            result_file = None
            for root, dirs, files in os.walk(os.path.dirname(self.geekbench_path)):
                for file in files:
                    if file.endswith('.gb' + str(self.version)):
                        result_file = os.path.join(root, file)
                        break
                if result_file:
                    break
            
            if result_file and os.path.exists(result_file):
                with open(result_file, 'r') as f:
                    self.results = json.load(f)
                print(f"✓ Results saved to {result_file}")
                return True
            else:
                print("✗ Result file not found")
                return False
                
        except subprocess.TimeoutExpired:
            print("✗ Benchmark timed out after 15 minutes")
            return False
        except Exception as e:
            print(f"✗ Benchmark failed: {e}")
            return False
    
    def upload_results(self):
        """Upload results to Geekbench Browser and get claim URL"""
        if not self.geekbench_path:
            print("✗ Geekbench not installed")
            return None
        
        if not self.results:
            print("✗ No results to upload. Run benchmark first.")
            return None
        
        print("\nUploading results to Geekbench Browser...")
        
        try:
            # Run geekbench with upload
            result = subprocess.run(
                [self.geekbench_path],
                cwd=os.path.dirname(self.geekbench_path),
                capture_output=True,
                text=True,
                timeout=900
            )
            
            # Extract URL from output
            url_pattern = r'https://browser\.geekbench\.com/v\d+/cpu/\d+'
            match = re.search(url_pattern, result.stdout)
            
            if match:
                url = match.group(0)
                print(f"✓ Results uploaded: {url}")
                
                # Extract claim URL if present
                claim_pattern = r'claim.*?(https://[^\s]+)'
                claim_match = re.search(claim_pattern, result.stdout, re.IGNORECASE)
                if claim_match:
                    claim_url = claim_match.group(1)
                    print(f"✓ Claim URL: {claim_url}")
                    return {'result_url': url, 'claim_url': claim_url}
                
                return {'result_url': url}
            else:
                print("✗ Could not extract URL from output")
                return None
                
        except Exception as e:
            print(f"✗ Upload failed: {e}")
            return None
    
    def get_summary(self):
        """Get formatted summary of results"""
        if not self.results:
            return "No results available"
        
        summary = f"<b>🏆 Geekbench {self.version} Results</b>\n\n"
        
        # System info
        if 'system' in self.results:
            system = self.results['system']
            summary += f"<b>System:</b> {system.get('model', 'Unknown')}\n"
            summary += f"<b>OS:</b> {system.get('operating_system', 'Unknown')}\n"
            summary += f"<b>Processor:</b> {system.get('processor', 'Unknown')}\n"
            summary += f"<b>Memory:</b> {system.get('memory', 'Unknown')}\n\n"
        
        # Scores
        if 'score' in self.results:
            score = self.results['score']
            summary += f"<b>📊 Scores:</b>\n"
            summary += f"  Single-Core: {score.get('singlecore_score', 'N/A')}\n"
            summary += f"  Multi-Core: {score.get('multicore_score', 'N/A')}\n"
        
        return summary
    
    def cleanup(self):
        """Clean up temporary files"""
        try:
            import shutil
            if os.path.exists(self.work_dir):
                shutil.rmtree(self.work_dir)
                print(f"✓ Cleaned up {self.work_dir}")
        except Exception as e:
            print(f"⚠ Cleanup failed: {e}")


def main():
    """CLI interface"""
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Geekbench Runner',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --run            # Download, install and run benchmark
  %(prog)s --run --upload   # Run and upload results
        """
    )
    
    parser.add_argument('--version', type=int, default=6, choices=[5, 6],
                       help='Geekbench version (default: 6)')
    parser.add_argument('--run', action='store_true',
                       help='Run benchmark')
    parser.add_argument('--upload', action='store_true',
                       help='Upload results to Geekbench Browser')
    parser.add_argument('--work-dir', metavar='DIR',
                       help='Working directory (default: temp dir)')
    parser.add_argument('--no-cleanup', action='store_true',
                       help='Do not cleanup temp files')
    
    args = parser.parse_args()
    
    runner = GeekbenchRunner(version=args.version, work_dir=args.work_dir)
    
    try:
        if args.run:
            # Download and extract
            if not runner.download_and_extract():
                return 1
            
            # Run benchmark
            if not runner.run_benchmark():
                return 1
            
            # Show summary
            print("\n" + "="*60)
            print(runner.get_summary())
            print("="*60)
            
            # Upload if requested
            if args.upload:
                urls = runner.upload_results()
                if urls:
                    print(f"\nResult URL: {urls.get('result_url')}")
                    if 'claim_url' in urls:
                        print(f"Claim URL: {urls['claim_url']}")
        else:
            parser.print_help()
        
        return 0
        
    finally:
        if not args.no_cleanup:
            runner.cleanup()


if __name__ == '__main__':
    sys.exit(main())
