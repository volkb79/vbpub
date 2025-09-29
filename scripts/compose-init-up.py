#!/usr/bin/env python3
"""
Docker Compose Initialization and Startup Script

Main responsibilities:
- Generate .env.active from .env.sample 
    - automatic password generation on xxx_PASSWORD, query on xxx_TOKEN
- Validate Docker Compose configuration and environment variables
- Check image availability before starting containers
- Create required host directories with proper permissions
- Start Docker Compose services with configurable modes


## Pre-Compose Hook Integration
- The pre-compose hook must be a Python script/class (not bash) with a standard interface (e.g., PreComposeHook with a run() method) so it can be imported and called from compose-init-up.py.
- All environment variables set by the hook must be logged and passed back to the main script.
- If secrets or tokens are generated, log their creation (but do not print the full secret/token in logs).

Usage:
    ./compose-init-up.py [options]
    
    Options:
        -d, --dir DIR     Working directory (default: current directory)
        -f, --file FILE   Docker compose file (default: docker-compose.yml)

Environment Configuration:
    The script expects a .env.sample file to generate .env.active from.
    On first run, it generates passwords and prompts for tokens, then exits.
    On subsequent runs, it loads the .env.active and starts services.

Error Handling:
    The script provides detailed error messages and stack traces for debugging.
    All library dependencies are checked before importing.
"""

import traceback
import sys
from typing import Dict, List, Tuple, Optional, Set, Any

# Check for required standard library modules before importing
def check_imports() -> None:
    """Check if all required standard library modules are available."""
    required_modules = [
        'os', 'sys', 're', 'subprocess', 'shutil', 'threading', 
        'concurrent.futures', 'queue', 'shlex', 'secrets', 'string'
    ]
    
    missing_modules = []
    for module in required_modules:
        try:
            __import__(module)
        except ImportError:
            missing_modules.append(module)
    
    if missing_modules:
        print(f"[ERROR] Missing required standard library modules: {', '.join(missing_modules)}", file=sys.stderr)
        print("[ERROR] This Python installation appears to be incomplete.", file=sys.stderr)
        sys.exit(1)

    # Check for non-standard library modules
    try:
        import yaml
    except ImportError:
        print("[ERROR] PyYAML library is required but not installed.", file=sys.stderr)
        print("[ERROR] Please install it with: pip install PyYAML", file=sys.stderr)
        sys.exit(1)

# Perform import check first
check_imports()

# Now import all required modules
import os
import re
import subprocess
import shutil
import threading
import concurrent.futures
import queue
import shlex
import yaml
from pathlib import Path

# --- Output helpers ---
COLOR_RED = '\033[0;31m'
COLOR_GREEN = '\033[0;32m'
COLOR_YELLOW = '\033[1;33m'
COLOR_BLUE = '\033[0;34m'
COLOR_UNSET = '\033[0m'

def step(msg: str) -> None:
    """Print a major step or milestone message."""
    print(f"{COLOR_BLUE}==>{COLOR_UNSET} {msg}")

def info(msg: str) -> None:
    """Print an informational message."""
    print(f"{COLOR_GREEN}[INFO]{COLOR_UNSET} {msg}")

def warn(msg: str) -> None:
    """Print a warning message."""
    print(f"{COLOR_YELLOW}[WARN]{COLOR_UNSET} {msg}")

def error(msg: str, show_stacktrace: bool = True) -> None:
    """Print an error message with optional stack trace and exit."""
    print(f"{COLOR_RED}[ERROR]{COLOR_UNSET} {msg}", file=sys.stderr)
    
    if show_stacktrace:
        print(f"{COLOR_RED}[ERROR]{COLOR_UNSET} Stack trace:", file=sys.stderr)
        # Get the current stack, excluding this error function
        stack = traceback.extract_stack()[:-1]
        for frame in stack:
            print(f"{COLOR_RED}[ERROR]{COLOR_UNSET}   at {frame.filename}:{frame.lineno} in {frame.name}()", file=sys.stderr)
            if frame.line:
                print(f"{COLOR_RED}[ERROR]{COLOR_UNSET}     {frame.line.strip()}", file=sys.stderr)
    
    sys.exit(1)

def handle_exception(exc_type: type, exc_value: Exception, exc_traceback: Any) -> None:
    """Global exception handler that provides detailed error information."""
    if issubclass(exc_type, KeyboardInterrupt):
        print(f"\n{COLOR_YELLOW}[WARN]{COLOR_UNSET} Operation interrupted by user", file=sys.stderr)
        sys.exit(1)
    
    print(f"{COLOR_RED}[ERROR]{COLOR_UNSET} Unhandled exception occurred:", file=sys.stderr)
    print(f"{COLOR_RED}[ERROR]{COLOR_UNSET} {exc_type.__name__}: {exc_value}", file=sys.stderr)
    print(f"{COLOR_RED}[ERROR]{COLOR_UNSET} Stack trace:", file=sys.stderr)
    
    tb_lines = traceback.format_exception(exc_type, exc_value, exc_traceback)
    for line in tb_lines:
        for subline in line.rstrip().split('\n'):
            if subline.strip():
                print(f"{COLOR_RED}[ERROR]{COLOR_UNSET}   {subline}", file=sys.stderr)
    
    sys.exit(1)

# Set up global exception handler
sys.excepthook = handle_exception

# --- Utility functions ---
def gen_pw(length: int = 16) -> str:
    """
    Generate a secure random password.
    
    Args:
        length: Length of the password to generate (default: 16)
        
    Returns:
        A secure random password containing letters and digits
        
    Raises:
        ValueError: If length is less than 1
    """
    if length < 1:
        raise ValueError("Password length must be at least 1")
    
    try:
        import secrets
        import string
        alphabet = string.ascii_letters + string.digits
        return ''.join(secrets.choice(alphabet) for _ in range(length))
    except ImportError:
        error("Required modules 'secrets' or 'string' not available for password generation")

def expand_vars(val: str, env: Dict[str, str]) -> str:
    """
    Expand $(...) command substitution and $VAR environment variables in a string.
    
    Args:
        val: The string containing variables to expand
        env: Environment dictionary for variable substitution
        
    Returns:
        The string with variables expanded
        
    Note:
        Command substitution $(...) is executed in a shell subprocess.
        Environment variables $VAR are replaced from the env dictionary.
    """
    if not isinstance(val, str):
        return str(val)
    
    # Expand $(...) command substitutions
    def repl(m: re.Match[str]) -> str:
        cmd = m.group(1)
        try:
            result = subprocess.check_output(cmd, shell=True, env=env, stderr=subprocess.DEVNULL)
            return result.decode().strip()
        except subprocess.CalledProcessError as e:
            warn(f"Command substitution failed for '{cmd}': {e}")
            return ""
        except Exception as e:
            warn(f"Error in command substitution '{cmd}': {e}")
            return ""
    
    val = re.sub(r'\$\(([^)]+)\)', repl, val)
    
    # Expand $VAR environment variables
    val = re.sub(r'\$([A-Za-z_][A-Za-z0-9_]*)', lambda m: env.get(m.group(1), ""), val)
    
    return val

def parse_env_sample(sample_path: str, env_path: str) -> None:
    """
    Parse .env.sample file and generate .env.active with auto-generated passwords.
    
    This function reads a sample environment file and creates an active environment
    file by:
    - Auto-generating secure passwords for variables ending with '_PASSWORD'
    - Prompting for user input on variables ending with '_TOKEN' that are empty
    - Copying all other variables as-is
    
    Args:
        sample_path: Path to the .env.sample file
        env_path: Path to the .env.active file to create
        
    Raises:
        FileNotFoundError: If sample_path doesn't exist
        PermissionError: If unable to write to env_path
        IOError: If file operations fail
    """
    if not os.path.isfile(sample_path):
        error(f"Sample environment file '{sample_path}' not found")
    
    # Check if we can write to the target directory
    target_dir = os.path.dirname(env_path) or '.'
    if not os.access(target_dir, os.W_OK):
        error(f"Cannot write to directory '{target_dir}' for file '{env_path}'")
    
    env = dict(os.environ)
    
    try:
        with open(sample_path, 'r', encoding='utf-8') as fin, \
             open(env_path, 'w', encoding='utf-8') as fout:
            
            for line_num, line in enumerate(fin, 1):
                orig = line.rstrip('\n')
                
                # Copy empty lines and comments as-is
                if not orig.strip() or orig.strip().startswith('#'):
                    fout.write(orig + '\n')
                    continue
                
                # Match password variables: VAR_PASSWORD=value # comment
                m_pw = re.match(r'^([A-Za-z0-9_]+_PASSWORD)=(.*?)([ \t#].*)?$', orig)
                # Match token variables: VAR_TOKEN=value # comment  
                m_token = re.match(r'^([A-Za-z0-9_]+_TOKEN)=(.*?)([ \t#].*)?$', orig)
                
                try:
                    if m_pw:
                        key, val, comment = m_pw.group(1), m_pw.group(2).strip(), m_pw.group(3) or ''
                        if not val:
                            info(f"Generating random password for {key}")
                            val = gen_pw(20)
                        elif 'set password manually later' in val.lower():
                            warn(f"{key} contains a placeholder. Please set a secure password!")
                        fout.write(f"{key}={val}{comment}\n")
                        
                    elif m_token:
                        key, val, comment = m_token.group(1), m_token.group(2).strip(), m_token.group(3) or ''
                        if not val:
                            warn(f"{key} requires a token. Please enter the value:")
                            try:
                                val = input(f"{key}=").strip()
                            except (EOFError, KeyboardInterrupt):
                                error(f"User input required for {key} but not provided")
                        fout.write(f"{key}={val}{comment}\n")
                        
                    else:
                        # Copy other variables as-is
                        fout.write(orig + '\n')
                        
                except Exception as e:
                    error(f"Error processing line {line_num} in {sample_path}: {e}")
                    
    except FileNotFoundError:
        error(f"Sample file '{sample_path}' not found")
    except PermissionError:
        error(f"Permission denied writing to '{env_path}'")
    except IOError as e:
        error(f"I/O error processing environment files: {e}")
    except Exception as e:
        error(f"Unexpected error parsing environment file: {e}")

def load_env_file(env_file: str) -> Tuple[Dict[str, str], List[str]]:
    """
    Load environment variables from a .env file.
    
    Args:
        env_file: Path to the environment file
        
    Returns:
        Tuple of (env_vars dict, loaded_keys list)
        
    Raises:
        FileNotFoundError: If env_file doesn't exist
        IOError: If file cannot be read
    """
    if not os.path.isfile(env_file):
        error(f"Environment file '{env_file}' not found")
    
    env_vars = {}
    loaded_keys = []
    
    try:
        with open(env_file, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                
                # Skip empty lines and comments
                if not line or line.startswith('#'):
                    continue
                
                # Remove inline comments (but preserve # in values)
                if '#' in line:
                    # Find the first # that's not inside quotes
                    in_quotes = False
                    quote_char = None
                    for i, char in enumerate(line):
                        if char in ('"', "'") and (i == 0 or line[i-1] != '\\'):
                            if not in_quotes:
                                in_quotes = True
                                quote_char = char
                            elif char == quote_char:
                                in_quotes = False
                                quote_char = None
                        elif char == '#' and not in_quotes:
                            line = line[:i].strip()
                            break
                
                if '=' not in line:
                    warn(f"Skipping invalid line {line_num} in {env_file}: '{line}'")
                    continue
                
                key, val = line.split('=', 1)
                key = key.strip()
                val = val.strip()
                
                # Remove quotes from values if present
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                elif val.startswith("'") and val.endswith("'"):
                    val = val[1:-1]
                
                env_vars[key] = val
                loaded_keys.append(key)
                
    except FileNotFoundError:
        error(f"Environment file '{env_file}' not found")
    except PermissionError:
        error(f"Permission denied reading '{env_file}'")  
    except IOError as e:
        error(f"I/O error reading environment file '{env_file}': {e}")
    except Exception as e:
        error(f"Unexpected error loading environment file '{env_file}': {e}")
    
    return env_vars, loaded_keys

def run(cmd: str, check: bool = True, capture_output: bool = False, 
        env: Optional[Dict[str, str]] = None, suppress_output: bool = False) -> Optional[str]:
    """
    Run a shell command with improved error handling.
    
    Args:
        cmd: Command to execute
        check: Whether to raise exception on non-zero exit codes
        capture_output: Whether to capture and return stdout
        env: Environment variables for the command
        suppress_output: Whether to suppress logging the command
        
    Returns:
        Command stdout if capture_output=True, None otherwise
        
    Raises:
        subprocess.CalledProcessError: If command fails and check=True
    """
    if not suppress_output:
        info(f"Running: {cmd}")
    
    try:
        result = subprocess.run(
            shlex.split(cmd), 
            check=check, 
            capture_output=capture_output, 
            text=True, 
            env=env,
            timeout=300  # 5 minute timeout to prevent hanging
        )
        
        if capture_output:
            return result.stdout
        return None
        
    except subprocess.TimeoutExpired:
        error(f"Command timed out after 5 minutes: {cmd}")
    except subprocess.CalledProcessError as e:
        if check:
            error(f"Command failed with exit code {e.returncode}: {cmd}\nStderr: {e.stderr}")
        else:
            warn(f"Command failed with exit code {e.returncode}: {cmd}")
            return None
    except FileNotFoundError:
        error(f"Command not found: {cmd.split()[0]}")
    except Exception as e:
        error(f"Unexpected error running command '{cmd}': {e}")

def reset_state(env: Dict[str, str], reset_flags: str, env_file: str) -> bool:
    """
    Reset Docker state based on configuration flags.
    Returns True if env-active was deleted and script should restart.
    """
    flags = [f.strip() for f in reset_flags.split(',') if f.strip() and f.strip() != 'none']
    
    if not flags:
        step("Perform reset actions before start: skipping")
        return False
    
    step("Perform reset actions before start")
    
    # 'all' is shorthand for common reset actions
    if 'all' in flags:
        flags = ['containers', 'named-volumes', 'hostdirs']
    
    for action in flags:
        try:
            if action == 'containers':
                info("Reset: removing containers/networks...")
                run("docker compose down --remove-orphans", check=False)
            elif action == 'named-volumes':
                info("Reset: removing named volumes and containers...")
                run("docker compose down -v --remove-orphans", check=False)
            elif action == 'networks':
                info("Reset: pruning unused docker networks...")
                run("docker network prune -f", check=False)
            elif action == 'hostdirs':
                info("Reset: removing host-mounted data directories referenced by *_HOSTDIR_* variables...")
                for k, v in env.items():
                    if '_HOSTDIR_' in k or k.endswith('_HOSTDIR') or k.endswith('_HOSTDIRS'):
                        if v and os.path.isdir(v):
                            info(f"Removing host data dir: {v}")
                            try:
                                shutil.rmtree(v, ignore_errors=True)
                            except Exception as e:
                                warn(f"Failed to remove directory {v}: {e}")
            elif action == 'env-active':
                info(f"Reset: deleting active environment file {env_file} ...")
                try:
                    os.remove(env_file)
                    info(f"Deleted {env_file}. Restarting script...")
                    return True
                except Exception as e:
                    error(f"Failed to delete {env_file}: {e}")
            else:
                warn(f"Unknown reset action: {action}")
        except Exception as e:
            warn(f"Error during reset action '{action}': {e}")
    
    return False

def check_compose_yaml(compose_file: str, env_vars: Dict[str, str], env_file: str) -> str:
    """
    Validate Docker Compose configuration and check environment variable usage.
    
    Args:
        compose_file: Path to docker-compose.yml file
        env_vars: Environment variables dictionary
        env_file: Path to the environment file
        
    Returns:
        The docker-compose config YAML output
        
    Raises:
        SystemExit: If validation fails or required variables are missing
    """
    step(f"Validating docker compose configuration for {compose_file}")
    
    if not os.path.isfile(compose_file):
        error(f"Docker compose file '{compose_file}' not found")
    
    # Run docker compose config and parse YAML
    try:
        config_yaml = run(f"docker compose -f {compose_file} config", 
                         capture_output=True, env=env_vars, suppress_output=True)
        if not config_yaml:
            error("docker-compose config returned empty output")
    except Exception as e:
        error(f"docker-compose validation failed: {e}")
    
    # Parse YAML for variable usage analysis
    referenced_vars = set()
    
    try:
        # Read the raw compose file to find ${VAR} references
        with open(compose_file, 'r', encoding='utf-8') as f:
            raw_compose_content = f.read()
        
        # Find all ${VAR} and ${VAR:-default} references in the raw compose file
        for match in re.finditer(r'\${([A-Za-z_][A-Za-z0-9_]*)[^}]*?}', raw_compose_content):
            referenced_vars.add(match.group(1))
            
    except Exception as e:
        warn(f"Error analyzing variable references: {e}")
        # Fallback to the processed config if raw file reading fails
        try:
            for match in re.finditer(r'\${([A-Za-z_][A-Za-z0-9_]*)}', config_yaml):
                referenced_vars.add(match.group(1))
        except Exception as e2:
            warn(f"Error analyzing processed config: {e2}")
    
    # Find all env vars defined
    defined_vars = set(env_vars.keys())
    
    # Warn for defined but unused variables (not necessarily an error)
    unused = defined_vars - referenced_vars
    for var in sorted(unused):
        if var.startswith('STARTWRAP_'):
            continue  # Exclude script control variables from warning
        warn(f"Variable defined in {env_file} but not used in compose YAML: {var}")
    
    # Error for referenced but undefined variables (this is a real problem)
    # Only error if the variable is referenced in an active (uncommented) line, warn if only in commented lines
    missing = referenced_vars - defined_vars
    if missing:
        # Read compose file lines for context
        with open(compose_file, 'r', encoding='utf-8') as f:
            compose_lines = f.readlines()
        for var in sorted(missing):
            found_in_active = False
            found_in_commented = False
            for line in compose_lines:
                # Look for ${VAR} or ${VAR:-...} in the line
                if re.search(r'\${' + re.escape(var) + r'([}:]|:-)', line):
                    if line.lstrip().startswith('#') or line.lstrip().startswith('//'):
                        found_in_commented = True
                    else:
                        found_in_active = True
                        break
            if found_in_active:
                error(f"Variable referenced in compose YAML but not defined in {env_file}: {var}", show_stacktrace=False)
            elif found_in_commented:
                warn(f"Variable referenced in commented line in compose YAML but not defined in {env_file}: {var}")
    
    return config_yaml

def get_images_from_compose(compose_file: str, env_vars: Dict[str, str]) -> List[str]:
    """
    Extract Docker image names from compose configuration.
    
    Args:
        compose_file: Path to docker-compose.yml file
        env_vars: Environment variables for config rendering
        
    Returns:
        List of Docker image names referenced in the compose file
    """
    try:
        config = run(f"docker compose -f {compose_file} config", 
                    capture_output=True, env=env_vars, suppress_output=True)
        if not config:
            warn("docker-compose config returned empty output for image extraction")
            return []
    except Exception as e:
        warn(f"Failed to get compose config for image extraction: {e}")
        return []
    
    images = set()
    for line in config.splitlines():
        m = re.match(r'\s*image:\s*([\w./:-]+)', line)
        if m:
            images.add(m.group(1))
    
    return list(images)

def check_for_image_updates(images: List[str]) -> None:
    """
    Check for major version updates of used images.
    
    This function examines Docker images to see if there are newer major versions
    available. For example, if using 'postgres:17', it will check if 'postgres:18'
    or later versions are available.
    
    Args:
        images: List of Docker image names to check for updates
    """
    step("Checking for potential image updates...")
    
    found_any_updates = False
    
    for image in images:
        try:
            # Skip local images
            if ':local' in image or ('/' not in image and ':' not in image):
                continue
                
            # Parse image name and tag
            if ':' in image:
                base_image, current_tag = image.rsplit(':', 1)
            else:
                base_image = image
                current_tag = 'latest'
            
            # Skip if current tag is 'latest' or not numeric
            if current_tag == 'latest' or not re.match(r'^\d+', current_tag):
                continue
            
            # Extract major version number
            version_match = re.match(r'^(\d+)', current_tag)
            if not version_match:
                continue
                
            current_major = int(version_match.group(1))
            
            # Check for next major version (simple heuristic)
            for next_major in range(current_major + 1, current_major + 3):
                next_tag = str(next_major)
                next_image = f"{base_image}:{next_tag}"
                
                try:
                    # Check if the newer version exists
                    if os.environ.get('DST_DEBUG_UPDATES') == '1':
                        info(f"Checking for update: {image} -> {next_image}")
                        
                    result = subprocess.run(
                        ["docker", "manifest", "inspect", next_image],
                        capture_output=True,
                        text=True,
                        timeout=15  # Increased timeout
                    )
                    
                    if result.returncode == 0:
                        warn(f"Image update available: '{image}' -> '{next_image}'")
                        found_any_updates = True
                        break  # Found an update, don't check further
                    elif os.environ.get('DST_DEBUG_UPDATES') == '1':
                        info(f"No update found for {next_image}")
                        
                except subprocess.TimeoutExpired:
                    if os.environ.get('DST_DEBUG_UPDATES') == '1':
                        warn(f"Timeout checking {next_image}")
                    pass
                except Exception as e:
                    if os.environ.get('DST_DEBUG_UPDATES') == '1':
                        warn(f"Error checking {next_image}: {e}")
                    pass
                    
        except Exception as e:
            # Don't fail the entire process for update checking errors
            pass
    
    if not found_any_updates:
        info("No major image updates detected")

def check_images_parallel(images: List[str]) -> Tuple[List[str], List[str]]:
    """
    Check availability of Docker images in parallel.
    
    Args:
        images: List of Docker image names to check
        
    Returns:
        Tuple of (available_images, missing_images)
    """
    if not images:
        return [], []
    
    missing = []
    available = []
    q = queue.Queue()
    
    # Read control variable from environment
    continue_on_error = os.environ.get('STARTWRAP_CONTINUE_ON_IMAGE_CHECK_ERROR', '0') == '1'
    
    def worker(image: str) -> None:
        """Worker function to check a single image."""
        try:
            result = subprocess.run(
                ["docker", "manifest", "inspect", image], 
                capture_output=True, 
                text=True,
                timeout=30  # 30 second timeout per image
            )
            if result.returncode == 0:
                info(f"Image available: {image}")
                q.put((image, True, None))
            else:
                # Try to provide more specific error information
                error_msg = result.stderr.strip() if result.stderr else f"Exit code {result.returncode}"
                # Docker Hub rate limit: treat as warning, not error
                if 'toomanyrequests' in error_msg.lower():
                    warn(f"Image NOT available: {image} ({error_msg}) [rate limit: inconclusive, continuing]")
                    q.put((image, True, None))
                # Local image denied/unauthorized: treat as error unless continue_on_error
                elif (':local' in image or image.endswith(':local')) and (
                    'denied' in error_msg.lower() or 'unauthorized' in error_msg.lower()):
                    msg = f"Image NOT available: {image} ({error_msg}) [local image access denied]"
                    if continue_on_error:
                        warn(msg + " [continuing due to STARTWRAP_CONTINUE_ON_IMAGE_CHECK_ERROR=1]")
                        q.put((image, True, None))
                    else:
                        q.put((image, False, msg, 'fatal'))
                else:
                    warn(f"Image NOT available: {image} ({error_msg})")
                    q.put((image, False, error_msg))
        except subprocess.TimeoutExpired:
            error_msg = "Timeout after 30 seconds"
            warn(f"Timeout checking image: {image}")
            q.put((image, False, error_msg))
        except Exception as e:
            error_msg = str(e)
            warn(f"Error checking image {image}: {e}")
            q.put((image, False, error_msg))
    
    # Start worker threads
    threads = []
    for image in images:
        t = threading.Thread(target=worker, args=(image,))
        t.daemon = True  # Don't prevent program exit
        t.start()
        threads.append(t)
    
    # Wait for all threads to complete
    for t in threads:
        try:
            t.join(timeout=60)  # Wait up to 60 seconds for each thread
        except Exception as e:
            warn(f"Error waiting for image check thread: {e}")
    
    # Collect results
    error_details = {}
    fatal_error = None
    while not q.empty():
        try:
            item = q.get_nowait()
            if len(item) == 4 and item[3] == 'fatal':
                # Fatal error from worker
                fatal_error = item[2]
                continue
            image, ok, error_msg = item[:3]
            if ok:
                available.append(image)
            else:
                missing.append(image)
                if error_msg:
                    error_details[image] = error_msg
        except queue.Empty:
            break
    
    # Log detailed error information if requested
    if error_details and os.environ.get('DST_DEBUG_IMAGES') == '1':
        step("Detailed image check errors:")
        for image, error in error_details.items():
            info(f"  {image}: {error}")
    
    # Use the global error function
    if fatal_error:
        globals()['error'](fatal_error)

    return available, missing

def create_hostdirs_from_env(env_vars: Dict[str, str]) -> None:
    """
    Create host directories specified in environment variables.
    
    Creates directories for variables matching *_HOSTDIR_* pattern and sets
    appropriate permissions based on UID/GID environment variables.
    
    Args:
        env_vars: Environment variables dictionary
    """
    for var, value in env_vars.items():
        if '_HOSTDIR_' in var or var.endswith('_HOSTDIR') or var.endswith('_HOSTDIRS'):
            if not value:
                continue
            try:
                uid = int(env_vars.get('UID', '0'))
                gid = int(env_vars.get('GID', '0'))
                created = False
                fixed = False
                if os.path.exists(value):
                    st = os.stat(value)
                    # Check ownership
                    if st.st_uid != uid or st.st_gid != gid:
                        warn(f"Ownership of {value} is {st.st_uid}:{st.st_gid}, expected {uid}:{gid}. Attempting to fix...")
                        try:
                            os.chown(value, uid, gid)
                            fixed = True
                        except Exception as e:
                            warn(f"Could not set ownership for {value}: {e}")
                    # Check permissions
                    mode = st.st_mode & 0o777
                    if mode != 0o770:
                        warn(f"Permissions of {value} are {oct(mode)}, expected 0o770. Attempting to fix...")
                        try:
                            os.chmod(value, 0o770)
                            fixed = True
                        except Exception as e:
                            warn(f"Could not set permissions for {value}: {e}")
                    # Check writability for current user
                    if not os.access(value, os.W_OK):
                        error(f"Directory {value} is not writable for the current user.")
                    if fixed:
                        info(f"Setting up directory {value} for variable {var}")
                    else:
                        info(f"Directory {value} for variable {var}: check OK")
                else:
                    os.makedirs(value, exist_ok=True)
                    os.chown(value, uid, gid)
                    os.chmod(value, 0o770)
                    info(f"Setting up directory {value} for variable {var}")
            except Exception as e:
                error(f"Failed to set up directory {value}: {e}")

def start_compose(compose_file: str, mode: str) -> None:
    """
    Start Docker Compose services with the specified mode.
    
    Args:
        compose_file: Path to the docker-compose.yml file
        mode: Start mode - one of: detached, abort-on-failure, foreground
        
    Raises:
        SystemExit: If invalid mode specified or docker compose fails
    """
    step("Starting containers with Docker Compose")
    
    valid_modes = {
        'detached': ('detach',),
        'abort-on-failure': ('abort',),
        'foreground': ('fg',)
    }
    
    # Normalize mode name
    normalized_mode = None
    for main_mode, aliases in valid_modes.items():
        if mode == main_mode or mode in aliases:
            normalized_mode = main_mode
            break
    
    if not normalized_mode:
        error(f"Invalid COMPOSE_START_MODE: {mode}. Valid values: {', '.join(valid_modes.keys())}")
    
    try:
        if normalized_mode == 'detached':
            info("Starting containers in detached mode")
            run(f"docker compose -f {compose_file} up -d")
        elif normalized_mode == 'abort-on-failure':
            info("Starting containers and aborting on container failure")
            run(f"docker compose -f {compose_file} up --abort-on-container-failure")
        elif normalized_mode == 'foreground':
            info("Starting containers in foreground")
            run(f"docker compose -f {compose_file} up")
    except Exception as e:
        error(f"Failed to start Docker Compose services: {e}")

def main() -> None:
    """
    Main function that orchestrates the infrastructure initialization process.
    
    This function:
    1. Parses command line arguments
    2. Validates required files exist
    3. Generates .env.active from .env.sample (first run only)  
    4. Loads environment variables and performs validation
    5. Resets Docker state if configured
    6. Creates required host directories
    7. Validates Docker Compose configuration
    8. Checks Docker image availability
    9. Starts Docker Compose services
    
    Exits with code 0 on first run after generating .env.active,
    or on successful completion of container startup.
    """
    import argparse
    
    # Parse command line arguments
    parser = argparse.ArgumentParser(
        description="Python replacement for start-init.sh",
        epilog="""
This script initializes the DST-DNS infrastructure by setting up environment
files, validating configuration, and starting Docker Compose services.

On first run, it generates .env.active from .env.sample and exits.
On subsequent runs, it validates the configuration and starts services.
        """,
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        '-d', '--dir', 
        help="Working directory (default: current directory)", 
        default=os.getcwd(),
        metavar='DIR'
    )
    parser.add_argument(
        '-f', '--file', 
        help="Docker compose file (default: docker-compose.yml)", 
        default="docker-compose.yml",
        metavar='FILE'
    )
    parser.add_argument(
        '-e', '--env', 
        help="Environment file name (default: .env.active)", 
        default=".env.active",
        metavar='ENV_FILE'
    )
    
    try:
        args = parser.parse_args()
    except SystemExit:
        # argparse already printed help/error message
        sys.exit(1)
    
    # Validate and change to working directory
    if not os.path.isdir(args.dir):
        error(f"Working directory '{args.dir}' does not exist")
    
    info(f"PATH is {os.environ.get('PATH', 'NOT_SET')}")
    info(f"Determined script directory: {os.path.dirname(os.path.abspath(__file__))}")
    
    try:
        os.chdir(args.dir)
        info(f"Changing to working directory: {args.dir}")
    except OSError as e:
        error(f"Cannot change to working directory '{args.dir}': {e}")
    
    # Define file paths
    sample_file = ".env.sample"
    env_file = args.env
    compose_file = args.file
    
    # Validate required files exist
    if not os.path.isfile(sample_file):
        error(f"{sample_file} file not found. Cannot continue.")
    
    if not os.path.isfile(compose_file):
        error(f"Intended docker-compose file '{compose_file}' not found. Cannot continue.")
    
    # First run: generate .env.active from .env.sample
    if not os.path.isfile(env_file):
        step(f"Generating '{env_file}' from '{sample_file}'")
        parse_env_sample(sample_file, env_file)
        info(f"Check and edit the generated {env_file}, then press any key to continue.")
        input("Press any key to continue...")
        # Continue as if .env.active was present from the start
    
    while True:
        # Subsequent runs: load environment and start services
        step(f"Sourcing environment from {env_file} file (allow variable expansion)...")
        env_vars, loaded_keys = load_env_file(env_file)
        info(f"Loaded {len(loaded_keys)} environment variables")
        step("Displaying all loaded environment variables:")
        for key in sorted(loaded_keys):
            info(f"  {key}={env_vars[key]}")
        
        # Expand command substitutions and environment variables in loaded values
        step("Expanding command substitutions and variables...")
        expanded_vars = {}
        for key, value in env_vars.items():
            expanded_value = expand_vars(value, env_vars)
            expanded_vars[key] = expanded_value
            if expanded_value != value:
                info(f"Expanded {key}: '{value}' -> '{expanded_value}'")
        
        # Update env_vars with expanded values
        env_vars = expanded_vars
        
        # Update current process environment
        os.environ.update(env_vars)
        
        # Perform any configured reset actions before creating volumes/directories
        reset_flags = env_vars.get('STARTWRAP_RESET_BEFORE_START', 'none')
        if reset_state(env_vars, reset_flags, env_file):
            # env-active was deleted, restart script from the beginning
            python = sys.executable
            os.execv(python, [python] + sys.argv)
        
        # Create required host directories with proper permissions
        step("Creating required directories/volumes with permissions for containers")
        create_hostdirs_from_env(env_vars)
        
        # Prepare for Docker Compose operations
        step("Starting containers with Docker Compose")
        # Run pre-compose script if specified
        pre_compose_script = env_vars.get('STARTWRAP_SCRIPT_BEFORE_COMPOSE_START')
        if pre_compose_script:
            info(f"Running pre-compose script: {pre_compose_script}")
            try:
                if pre_compose_script.endswith('.py'):
                    import importlib.util
                    import importlib.machinery
                    import types
                    script_path = pre_compose_script
                    module_name = os.path.splitext(os.path.basename(script_path))[0]
                    spec = importlib.util.spec_from_file_location(module_name, script_path)
                    module = importlib.util.module_from_spec(spec)
                    sys.modules[module_name] = module
                    spec.loader.exec_module(module)
                    if hasattr(module, 'PreComposeHook'):
                        hook = module.PreComposeHook(env=os.environ.copy())
                        export_vars = hook.run()
                        for var, val in export_vars.items():
                            os.environ[var] = val
                            env_vars[var] = val
                            info(f"Pre-compose hook set variable: {var}={val}")
                        info(f"Pre-compose Python hook {pre_compose_script} executed and environment updated.")
                    else:
                        error(f"Python pre-compose script {pre_compose_script} does not define PreComposeHook class.")
                else:
                    # 1. Run the script interactively so prompts and echo work
                    subprocess.run(["bash", pre_compose_script], env=os.environ.copy(), text=True)
                    # 2. Run the script again to capture HOOK_EXPORT_VAR lines (no input required)
                    result = subprocess.run(["bash", pre_compose_script], env=os.environ.copy(), text=True, capture_output=True)
                    if result.returncode != 0:
                        error(f"Pre-compose script {pre_compose_script} failed with exit code {result.returncode}")
                    for line in result.stdout.splitlines():
                        if line.startswith("HOOK_EXPORT_VAR:"):
                            export_line = line[len("HOOK_EXPORT_VAR:"):].strip()
                            if '=' in export_line:
                                var, val = export_line.split('=', 1)
                                var = var.strip()
                                val = val.strip()
                                os.environ[var] = val
                                env_vars[var] = val
                                info(f"Pre-compose script set variable: {var}={val}")
                    info(f"Pre-compose script {pre_compose_script} executed and environment updated.")
            except Exception as e:
                error(f"Failed to execute pre-compose script {pre_compose_script}: {e}")
        compose_mode = env_vars.get('STARTWRAP_COMPOSE_START_MODE', 'abort-on-failure')
        info(f"STARTWRAP_COMPOSE_START_MODE set to: {compose_mode}")
        
        # Validate compose config and check env var usage
        config_yaml = check_compose_yaml(compose_file, env_vars, env_file)
        
        # Check image availability before attempting to start
        step(f"Checking image availability for all referenced images in {compose_file}...")
        images = get_images_from_compose(compose_file, env_vars)
        
        if images:
            info(f"Found {len(images)} images to check: {', '.join(images)}")
            available, missing = check_images_parallel(images)
            
            # Check for potential updates
            check_for_image_updates(images)
            
            if missing:
                error(f"Some images are missing or inaccessible: {', '.join(missing)}\n"
                      f"Please ensure Docker is running and images are available.",
                      show_stacktrace=False)
            
            info(f"All {len(available)} required images are available")
        else:
            warn("No images found in docker-compose configuration")
        
        # Start Docker Compose services
        start_compose(compose_file, compose_mode)
        
        info("Infrastructure initialization completed successfully!")
        break

if __name__ == "__main__":
    main()
