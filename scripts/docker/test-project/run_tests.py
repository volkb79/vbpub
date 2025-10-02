#!/usr/bin/env python3
"""
Automated Test Runner for compose-init-up.py

This script runs comprehensive tests against compose-init-up to validate:
- All PASSWORD/TOKEN variations
- Command substitution and variable expansion
- Pre-compose and post-compose hooks
- Directory creation (_HOSTDIR_ variables)
- Error handling and validation
- Non-interactive operation

Test scenarios:
1. First run: Generate .env from .env.sample
2. Verify all passwords/tokens were generated correctly
3. Verify hooks executed and returned variables
4. Second run: Verify idempotency (no regeneration of existing values)
5. Reset scenarios: Test COMPINIT_RESET_BEFORE_START options
"""

import os
import sys
import json
import subprocess
import re
import shutil
from pathlib import Path
from typing import Dict, List, Tuple, Optional

# ANSI colors for output
COLOR_GREEN = '\033[0;32m'
COLOR_RED = '\033[0;31m'
COLOR_YELLOW = '\033[1;33m'
COLOR_BLUE = '\033[0;34m'
COLOR_RESET = '\033[0m'

class TestRunner:
    def __init__(self, test_dir: str):
        self.test_dir = Path(test_dir)
        self.compose_init_script = Path(__file__).parent.parent / 'compose-init-up.py'
        self.env_active = self.test_dir / '.env'
        self.env_sample = self.test_dir / '.env.sample'
        self.test_results: List[Tuple[str, bool, str]] = []
        
    def log(self, msg: str, level: str = 'INFO'):
        colors = {
            'INFO': COLOR_BLUE,
            'SUCCESS': COLOR_GREEN,
            'ERROR': COLOR_RED,
            'WARN': COLOR_YELLOW
        }
        color = colors.get(level, '')
        print(f"{color}[{level}]{COLOR_RESET} {msg}")
    
    def test(self, name: str, passed: bool, details: str = ''):
        """Record a test result"""
        self.test_results.append((name, passed, details))
        status = f"{COLOR_GREEN}✓ PASS{COLOR_RESET}" if passed else f"{COLOR_RED}✗ FAIL{COLOR_RESET}"
        self.log(f"{status}: {name}", 'SUCCESS' if passed else 'ERROR')
        if details and not passed:
            self.log(f"  Details: {details}", 'ERROR')
    
    def run_compose_init(self, extra_env: Optional[Dict[str, str]] = None) -> Tuple[int, str, str]:
        """Run compose-init-up.py and return (exit_code, stdout, stderr)"""
        env = os.environ.copy()
        if extra_env:
            env.update(extra_env)
        # Ensure non-interactive behavior for automated tests
        env.setdefault('COMPINIT_ASSUME_YES', '1')

        cmd = [sys.executable, str(self.compose_init_script), '-d', str(self.test_dir), '-y']
        self.log(f"Running: {' '.join(cmd)}")

        try:
            # Increase timeout to allow docker-compose health polling to complete in CI
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=360,
                env=env,
                cwd=str(self.test_dir)
            )
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            return -1, '', 'Command timed out after 360 seconds'
        except Exception as e:
            return -1, '', str(e)
    
    def load_env_file(self, path: Path) -> Dict[str, str]:
        """Load environment file into dict"""
        env_vars = {}
        if not path.exists():
            return env_vars
        
        with open(path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if '=' in line:
                    # Simple parsing, handles comments
                    if '#' in line:
                        line = line.split('#')[0].strip()
                    key, val = line.split('=', 1)
                    env_vars[key.strip()] = val.strip()
        
        return env_vars
    
    def cleanup(self):
        """Clean up test artifacts"""
        self.log("Cleaning up test artifacts...")
        
        # Remove generated .env file
        if self.env_active.exists():
            self.env_active.unlink()
            self.log(f"Removed {self.env_active}")
        
        # Remove generated host directories
        for vol_dir in self.test_dir.glob('vol-*'):
            if vol_dir.is_dir():
                shutil.rmtree(vol_dir)
                self.log(f"Removed {vol_dir}")
        
        # Remove generated config directory
        config_dir = self.test_dir / 'generated-config'
        if config_dir.exists():
            shutil.rmtree(config_dir)
            self.log(f"Removed {config_dir}")

    def set_env_var_in_file(self, key: str, value: str):
        """Set or update a key=value in the active .env file (simple replace)."""
        if not self.env_active.exists():
            self.log(f".env file not present to set {key}", 'WARN')
            return
        lines = []
        found = False
        with open(self.env_active, 'r') as f:
            for line in f:
                if line.strip().startswith('#') or '=' not in line:
                    lines.append(line)
                    continue
                k = line.split('=', 1)[0].strip()
                if k == key:
                    lines.append(f"{key}={value}\n")
                    found = True
                else:
                    lines.append(line)
        if not found:
            lines.append(f"{key}={value}\n")
        with open(self.env_active, 'w') as f:
            f.writelines(lines)
    
    def test_scenario_1_first_generation(self):
        """Test Scenario 1: First generation of .env from .env.sample"""
        self.log("\n" + "="*80)
        self.log("SCENARIO 1: First generation of .env from .env.sample")
        self.log("="*80)
        
        # Ensure clean state
        self.cleanup()
        
        # Run compose-init
        exit_code, stdout, stderr = self.run_compose_init()
        
        # Test 1: Script should succeed
        self.test(
            "S1.1: compose-init-up exits successfully",
            exit_code == 0,
            f"Exit code: {exit_code}, stderr: {stderr[:200]}"
        )
        
        # Test 2: .env file should be created
        self.test(
            "S1.2: .env file created",
            self.env_active.exists(),
            f"Expected file: {self.env_active}"
        )
        
        if not self.env_active.exists():
            self.log("Cannot continue without .env file", 'ERROR')
            return
        
        # Load generated environment
        env_vars = self.load_env_file(self.env_active)
        
        # Test 3: Simple PASSWORD generation
        password_tests = [
            ('DB_ADMIN_PASSWORD', 'Simple empty password'),
            ('API_SECRET_PASSWORD_ALNUM32', 'ALNUM32 descriptor password'),
            ('ENCRYPTION_KEY_PASSWORD_HEX64', 'HEX64 descriptor password'),
        ]
        
        for var_name, desc in password_tests:
            var_value = env_vars.get(var_name, '')
            self.test(
                f"S1.3: {var_name} generated ({desc})",
                len(var_value) > 0,
                f"Value: '{var_value}'"
            )
        
        # Test 4: TOKEN_INTERNAL generation
        token_internal_tests = [
            ('SERVICE_AUTH_TOKEN_INTERNAL', 'Simple internal token'),
            ('WEBHOOK_SECRET_TOKEN_ALNUM48_INTERNAL', 'ALNUM48 internal token'),
            ('SESSION_KEY_TOKEN_HEX32_INTERNAL', 'HEX32 internal token'),
        ]
        
        for var_name, desc in token_internal_tests:
            var_value = env_vars.get(var_name, '')
            self.test(
                f"S1.4: {var_name} generated ({desc})",
                len(var_value) > 0,
                f"Value: '{var_value}'"
            )
        
        # Test 5: Existing values preserved
        preserved_tests = [
            ('DB_USER_PASSWORD', 'predefined_password_12345'),
            ('CACHE_TOKEN_INTERNAL', 'predefined_internal_token_xyz'),
            ('DOCKER_REGISTRY_TOKEN_EXTERNAL', 'ghp_predefined_external_token_abc123'),
        ]
        
        for var_name, expected in preserved_tests:
            var_value = env_vars.get(var_name, '')
            self.test(
                f"S1.5: {var_name} preserved",
                var_value == expected,
                f"Expected: '{expected}', Got: '{var_value}'"
            )
        
        # Test 6: Command substitution expanded
        uid = env_vars.get('UID', '')
        gid = env_vars.get('GID', '')
        self.test(
            "S1.6: UID command substitution expanded",
            uid.isdigit() and int(uid) > 0,
            f"UID: '{uid}'"
        )
        self.test(
            "S1.7: GID command substitution expanded",
            gid.isdigit() and int(gid) > 0,
            f"GID: '{gid}'"
        )
        
        # Test 7: Variable expansion
        user_cache = env_vars.get('USER_CACHE_DIR', '')
        self.test(
            "S1.8: Variable expansion works",
            '/home/testuser/.cache' in user_cache,
            f"USER_CACHE_DIR: '{user_cache}'"
        )
        
        # Test 8: Pre-compose hook variables set
        precompose_vars = [
            'PRECOMPOSE_RUNNER_TOKEN',
            'PRECOMPOSE_WEBHOOK_SECRET',
            'PRECOMPOSE_EXTERNAL_API_KEY',
            'PRECOMPOSE_TIMESTAMP',
        ]
        
        for var_name in precompose_vars:
            var_value = env_vars.get(var_name, '')
            self.test(
                f"S1.9: {var_name} set by pre-compose hook",
                len(var_value) > 0,
                f"Value: '{var_value[:30]}...'"
            )
        
        # Test 9: Host directories created
        expected_dirs = [
            'vol-db-data',
            'vol-redis-data',
            'vol-app-logs',
            'vol-app-cache',
            'vol-nginx-config',
        ]
        
        for dir_name in expected_dirs:
            dir_path = self.test_dir / dir_name
            self.test(
                f"S1.10: {dir_name} directory created",
                dir_path.exists() and dir_path.is_dir(),
                f"Path: {dir_path}"
            )
        
        # Test 10: DEFERED variables empty (not generated yet)
        deferred_vars = [
            'PORTUS_ADMIN_PASSWORD_DEFERED',
            'DELAYED_SERVICE_PASSWORD_ALNUM16_DEFERED',
            'ROBOT_TOKEN_INTERNAL_DEFERED',
        ]
        
        for var_name in deferred_vars:
            var_value = env_vars.get(var_name, 'NOT_FOUND')
            self.test(
                f"S1.11: {var_name} deferred (empty)",
                var_value == '' or var_value == 'NOT_FOUND',
                f"Value should be empty, got: '{var_value}'"
            )
        
        # Test 11: Descriptor length validation
        alnum32 = env_vars.get('API_SECRET_PASSWORD_ALNUM32', '')
        self.test(
            "S1.12: ALNUM32 descriptor generates 32 chars",
            len(alnum32) == 32,
            f"Length: {len(alnum32)}, Value: '{alnum32}'"
        )
        
        hex64 = env_vars.get('ENCRYPTION_KEY_PASSWORD_HEX64', '')
        self.test(
            "S1.13: HEX64 descriptor generates 64 chars",
            len(hex64) == 64 and all(c in '0123456789abcdef' for c in hex64),
            f"Length: {len(hex64)}, Value: '{hex64}'"
        )
    
    def test_scenario_2_idempotency(self):
        """Test Scenario 2: Re-running should not regenerate existing secrets"""
        self.log("\n" + "="*80)
        self.log("SCENARIO 2: Idempotency - no regeneration on second run")
        self.log("="*80)
        
        if not self.env_active.exists():
            self.log("Skipping: .env file not found from previous scenario", 'WARN')
            return
        
        # Load current state
        env_before = self.load_env_file(self.env_active)
        
        # Run compose-init again
        exit_code, stdout, stderr = self.run_compose_init()
        
        self.test(
            "S2.1: Second run exits successfully",
            exit_code == 0,
            f"Exit code: {exit_code}"
        )
        
        # Load state after second run
        env_after = self.load_env_file(self.env_active)
        
        # Test: Passwords/tokens should be identical
        critical_vars = [
            'DB_ADMIN_PASSWORD',
            'API_SECRET_PASSWORD_ALNUM32',
            'SERVICE_AUTH_TOKEN_INTERNAL',
            'WEBHOOK_SECRET_TOKEN_ALNUM48_INTERNAL',
        ]
        
        for var_name in critical_vars:
            before_val = env_before.get(var_name, 'MISSING')
            after_val = env_after.get(var_name, 'MISSING')
            self.test(
                f"S2.2: {var_name} unchanged",
                before_val == after_val and before_val != 'MISSING',
                f"Before: '{before_val[:20]}...', After: '{after_val[:20]}...'"
            )
    
    def test_scenario_3_hook_integration(self):
        """Test Scenario 3: Hook execution and variable persistence"""
        self.log("\n" + "="*80)
        self.log("SCENARIO 3: Hook integration and variable persistence")
        self.log("="*80)
        
        # This was already tested in scenario 1, but let's verify the config file
        config_file = self.test_dir / 'generated-config' / 'precompose-config.json'
        
        self.test(
            "S3.1: Pre-compose hook created config file",
            config_file.exists(),
            f"Expected: {config_file}"
        )
        
        if config_file.exists():
            try:
                with open(config_file, 'r') as f:
                    config = json.load(f)
                
                required_keys = ['project', 'environment', 'generated_at', 'fqdn']
                all_present = all(k in config for k in required_keys)
                
                self.test(
                    "S3.2: Config file contains required keys",
                    all_present,
                    f"Keys: {list(config.keys())}"
                )
            except Exception as e:
                self.test(
                    "S3.2: Config file parsing",
                    False,
                    f"Error: {e}"
                )
    
    def test_scenario_4_error_handling(self):
        """Test Scenario 4: Error handling and validation"""
        self.log("\n" + "="*80)
        self.log("SCENARIO 4: Error handling and validation")
        self.log("="*80)
        
        # Test with missing .env.sample
        backup_sample = self.env_sample.with_suffix('.sample.backup')
        try:
            self.env_sample.rename(backup_sample)
            
            exit_code, stdout, stderr = self.run_compose_init()
            
            self.test(
                "S4.1: Missing .env.sample handled gracefully",
                exit_code != 0,
                f"Exit code: {exit_code} (should be non-zero)"
            )
            
            self.test(
                "S4.2: Error message mentions missing sample file",
                'sample' in stderr.lower() or 'not found' in stderr.lower(),
                f"Stderr: {stderr[:200]}"
            )
        finally:
            # Restore .env.sample
            if backup_sample.exists():
                backup_sample.rename(self.env_sample)

    def test_scenario_5_reset_behavior(self):
        """Test Scenario 5: COMPINIT_RESET_BEFORE_START behavior"""
        self.log("\n" + "="*80)
        self.log("SCENARIO 5: Reset behavior for COMPINIT_RESET_BEFORE_START")
        self.log("="*80)

        # Ensure .env exists from previous runs
        if not self.env_active.exists():
            self.log("Skipping: .env file not found from previous scenario", 'WARN')
            return

        # Create some hostdirs to be removed
        for d in ['vol-db-data', 'vol-redis-data']:
            p = self.test_dir / d
            p.mkdir(exist_ok=True)
            # create a dummy file to ensure rmtree would remove it
            (p / 'dummy.txt').write_text('x')

        # Ensure the loaded .env contains the reset flag so compose-init processes it
        self.set_env_var_in_file('COMPINIT_RESET_BEFORE_START', 'hostdirs')
        # Run compose-init which will read the .env and perform reset actions
        exit_code, stdout, stderr = self.run_compose_init()
        self.test(
            "S5.1: compose-init exits successfully with reset hostdirs",
            exit_code == 0,
            f"Exit code: {exit_code}"
        )

        # Directories should have been cleared and then recreated by the helper
        for d in ['vol-db-data', 'vol-redis-data']:
            dir_path = self.test_dir / d
            # Directory should exist (recreated)
            self.test(
                f"S5.2: {d} recreated after reset",
                dir_path.exists() and dir_path.is_dir(),
                f"Path: {dir_path} missing"
            )
            # Dummy file should have been removed
            dummy = dir_path / 'dummy.txt'
            self.test(
                f"S5.2b: {d} cleared of previous contents",
                not dummy.exists(),
                f"Dummy file still present: {dummy}"
            )

        # Test env-active reset: ask script to remove env-active and ensure it restarts
        # We simulate by setting COMPINIT_RESET_BEFORE_START=env-active and running
        if self.env_active.exists():
            exit_code, stdout, stderr = self.run_compose_init(extra_env={'COMPINIT_RESET_BEFORE_START': 'env-active'})
            self.test(
                "S5.3: env-active reset run exits (script may restart)",
                exit_code == 0,
                f"Exit code: {exit_code}"
            )
    
    def print_summary(self):
        """Print test summary"""
        self.log("\n" + "="*80)
        self.log("TEST SUMMARY")
        self.log("="*80)
        
        total = len(self.test_results)
        passed = sum(1 for _, p, _ in self.test_results if p)
        failed = total - passed
        
        self.log(f"Total tests: {total}")
        self.log(f"Passed: {COLOR_GREEN}{passed}{COLOR_RESET}")
        self.log(f"Failed: {COLOR_RED}{failed}{COLOR_RESET}")
        
        if failed > 0:
            self.log("\nFailed tests:", 'ERROR')
            for name, passed, details in self.test_results:
                if not passed:
                    self.log(f"  - {name}", 'ERROR')
                    if details:
                        self.log(f"    {details}", 'ERROR')
        
        success_rate = (passed / total * 100) if total > 0 else 0
        self.log(f"\nSuccess rate: {success_rate:.1f}%")
        
        return failed == 0

def main():
    print(f"{COLOR_BLUE}{'='*80}{COLOR_RESET}")
    print(f"{COLOR_BLUE}Compose-Init-Up Test Suite{COLOR_RESET}")
    print(f"{COLOR_BLUE}{'='*80}{COLOR_RESET}\n")
    
    # Determine test directory
    test_dir = Path(__file__).parent
    
    print(f"Test directory: {test_dir}")
    print(f"Compose-init script: {test_dir.parent / 'compose-init-up.py'}\n")
    
    # Create test runner
    runner = TestRunner(str(test_dir))
    
    # Run test scenarios
    try:
        runner.test_scenario_1_first_generation()
        runner.test_scenario_2_idempotency()
        runner.test_scenario_3_hook_integration()
        runner.test_scenario_4_error_handling()
        runner.test_scenario_5_reset_behavior()
    except KeyboardInterrupt:
        print(f"\n{COLOR_YELLOW}Tests interrupted by user{COLOR_RESET}")
        return 1
    except Exception as e:
        print(f"\n{COLOR_RED}Fatal error during testing: {e}{COLOR_RESET}")
        import traceback
        traceback.print_exc()
        return 1
    finally:
        # Print summary
        success = runner.print_summary()
        
        # Ask about cleanup
        print(f"\n{COLOR_BLUE}Test artifacts (vol-* dirs, .env) are still present.{COLOR_RESET}")
        print("You can inspect them or run cleanup manually.")
        
        return 0 if success else 1

if __name__ == '__main__':
    sys.exit(main())
