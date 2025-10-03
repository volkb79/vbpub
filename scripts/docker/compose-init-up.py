#!/usr/bin/env python3
"""Minimal shim → canonical compose-init-up.

Expected real symlink target:
  ../../../vbpub/scripts/docker/compose-init-up.py

If you see this file with contents (not a symlink), convert it to a symlink
or leave as-is; it simply forwards execution. Do NOT add logic here.
"""
from __future__ import annotations
import pathlib, runpy, sys

def main() -> None:  # pragma: no cover
    canonical = pathlib.Path(__file__).resolve().parents[3] / 'vbpub' / 'scripts' / 'docker' / 'compose-init-up.py'
    if not canonical.is_file():
        print(f"[ERROR] canonical compose-init-up not found at {canonical}", file=sys.stderr)
        sys.exit(1)
    runpy.run_path(str(canonical), run_name='__main__')

if __name__ == '__main__':
    main()
    {
        "name": "COMPINIT_STRICT_MODE",
        "default": "",
        "description": "Global strict mode toggle (1 to enable)",
        "type": "int"
    },
    {
        "name": "COMPINIT_ENABLE_ENV_EXPANSION",
        "default": "false",
        "description": "Enable $VAR and $(cmd) expansion in env values at runtime",
        "type": "bool"
    },
    {
        "name": "PUBLIC_FQDN",
        "default": "example.local",
        "description": "Public DNS name for service",
        "type": "string"
    },
    {
        "name": "PUBLIC_TLS_KEY_PEM",
        "default": "/etc/letsencrypt/live/$PUBLIC_FQDN/privkey.pem",
        "description": "Path to TLS private key PEM",
        "type": "string"
    },
    {
        "name": "PUBLIC_TLS_CRT_PEM",
        "default": "/etc/letsencrypt/live/$PUBLIC_FQDN/fullchain.pem",
        "description": "Path to TLS certificate PEM",
        "type": "string"
    },
    {
        "name": "HEALTHCHECK_INTERVAL",
        "default": "10s",
        "description": "Healthcheck interval",
        "type": "string"
    },
    {
        "name": "HEALTHCHECK_TIMEOUT",
        "default": "5s",
        "description": "Healthcheck timeout",
        "type": "string"
    },
    {
        "name": "HEALTHCHECK_RETRIES",
        "default": "3",
        "description": "Healthcheck retries",
        "type": "int"
    },
    {
        "name": "HEALTHCHECK_START_PERIOD",
        "default": "30s",
        "description": "Healthcheck start period",
        "type": "string"
    },
    {
        "name": "LABEL_PROJECT_NAME",
        "default": "my-project",
        "description": "Project name label",
        "type": "string"
    },
    {
        "name": "LABEL_ENV_TAG",
        "default": "dev",
        "description": "Environment tag (dev/staging/prod)",
        "type": "string"
    },
    {
        "name": "LABEL_PREFIX",
        "default": "example.com",
        "description": "Label prefix for project",
        "type": "string"
    },
    {
        "name": "UID",
        "default": "$(id -u)",
        "description": "User ID for container",
        "type": "string"
    },
    {
        "name": "GID",
        "default": "$(id -g)",
        "description": "Group ID for container",
        "type": "string"
    },
    # Add more variables as needed
]


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
def gen_pw(length: int = 16, charset: str = 'ALNUM') -> str:
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
        cs = (charset or 'ALNUM').upper()
        if cs == 'ALNUM':
            alphabet = string.ascii_letters + string.digits
            return ''.join(secrets.choice(alphabet) for _ in range(length))
        elif cs == 'HEX':
            # token_hex returns 2*nbytes hex chars, so compute nbytes and trim
            nbytes = (length + 1) // 2
            return secrets.token_hex(nbytes)[:length]
        else:
            error(f"Unsupported charset for gen_pw: {charset}")
    except ImportError:
        error("Required modules 'secrets' or 'string' not available for password generation")


def strict_flag(env: Dict[str, str], name: str) -> bool:
    """
    Check whether a strict flag is enabled using the canonical
    COMPINIT_STRICT_<NAME> environment variable. Legacy
    COMPINIT_<NAME>_STRICT variables are no longer supported.

    Args:
        env: environment mapping to check
        name: uppercase flag name, e.g. 'EXTERNAL' or 'EXPANSION'

    Returns:
        True if the strict flag is enabled, False otherwise
    """
    key = f'COMPINIT_STRICT_{name}'
    val = env.get(key, None)
    if val is None:
        return False
    return str(val).lower() in ('1', 'true', 'yes')

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
            # In strict expansion mode, treat command substitution failures as fatal
            if strict_flag(env, 'EXPANSION'):
                error(f"Command substitution failed for '{cmd}': {e}")
            warn(f"Command substitution failed for '{cmd}': {e}")
            return ""
        except Exception as e:
            if strict_flag(env, 'EXPANSION'):
                error(f"Error in command substitution '{cmd}': {e}")
            warn(f"Error in command substitution '{cmd}': {e}")
            return ""
    
    val = re.sub(r'\$\(([^)]+)\)', repl, val)
    
    # Expand $VAR environment variables
    # Support both ${VAR} and $VAR styles
    # Replace ${VAR} style first, then $VAR. If a variable is missing and
    # COMPINIT_EXPANSION_STRICT is set, raise a fatal error; otherwise warn
    # and substitute an empty string.
    def var_repl_braced(m: re.Match[str]) -> str:
        name = m.group(1)
        if name in env:
            return env[name]
        if strict_flag(env, 'EXPANSION'):
            error(f"Undefined variable '{{{name}}}' during expansion (COMPINIT_EXPANSION_STRICT=1)")
        warn(f"Undefined variable '{{{name}}}' during expansion; substituting empty string")
        return ""

    def var_repl_plain(m: re.Match[str]) -> str:
        name = m.group(1)
        if name in env:
            return env[name]
        if strict_flag(env, 'EXPANSION'):
            error(f"Undefined variable '${name}' during expansion (COMPINIT_EXPANSION_STRICT=1)")
        warn(f"Undefined variable '${name}' during expansion; substituting empty string")
        return ""

    val = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', var_repl_braced, val)
    val = re.sub(r'\$([A-Za-z_][A-Za-z0-9_]*)', var_repl_plain, val)
    
    return val


def expand_cmds_only(val: str, env: Dict[str, str]) -> str:
    """
    Expand only command substitutions $(...) in the string using the provided env.
    Do NOT perform $VAR environment variable replacement here; that preserves
    literal $VAR tokens in generated env files.
    """
    if not isinstance(val, str):
        return str(val)

    def repl(m: re.Match[str]) -> str:
        cmd = m.group(1)
        try:
            result = subprocess.check_output(cmd, shell=True, env=env, stderr=subprocess.DEVNULL)
            return result.decode().strip()
        except subprocess.CalledProcessError as e:
            if strict_flag(env, 'EXPANSION'):
                error(f"Command substitution failed for '{cmd}': {e}")
            warn(f"Command substitution failed for '{cmd}': {e}")
            return ""
        except Exception as e:
            if strict_flag(env, 'EXPANSION'):
                error(f"Error in command substitution '{cmd}': {e}")
            warn(f"Error in command substitution '{cmd}': {e}")
            return ""

    return re.sub(r'\$\(([^)]+)\)', repl, val)

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
    # By default do not expand $VAR or $(...) in sample values unless explicitly enabled
    expansion_enabled = os.environ.get('COMPINIT_ENABLE_ENV_EXPANSION', '').lower() in ('1', 'true', 'yes')

    def _maybe_expand(val: str, local_env: Dict[str, str]) -> str:
        """
        Expand command substitutions $(...) always (so generated files don't
        contain literal $(...) or backticks). Only expand $VAR / ${VAR}
        when COMPINIT_ENABLE_ENV_EXPANSION is enabled. This preserves
        literal $VAR tokens in generated .env files by default (test
        expectation).
        """
        try:
            # First, expand command substitutions only to produce literal
            # outputs for things like UID=$(id -u) while preserving $VAR tokens.
            res = expand_cmds_only(val, local_env)
        except Exception:
            res = val

        if expansion_enabled:
            # Expand only variable references (${VAR} and $VAR) using local_env
            # without re-running command substitutions.
            def var_repl_braced(m: re.Match[str]) -> str:
                name = m.group(1)
                return local_env.get(name, '')

            def var_repl_plain(m: re.Match[str]) -> str:
                name = m.group(1)
                return local_env.get(name, '')

            try:
                res = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', var_repl_braced, res)
                res = re.sub(r'\$([A-Za-z_][A-Za-z0-9_]*)', var_repl_plain, res)
            except Exception:
                pass

        return res
    
    try:
        with open(sample_path, 'r', encoding='utf-8') as fin, \
             open(env_path, 'w', encoding='utf-8') as fout:
            
            local_env = dict(os.environ)
            for line_num, line in enumerate(fin, 1):
                orig = line.rstrip('\n')
                
                # Copy empty lines and comments as-is
                if not orig.strip() or orig.strip().startswith('#'):
                    fout.write(orig + '\n')
                    continue
                
                # Match password variables: VAR_PASSWORD=value # comment
                m_pw = re.match(r'^([A-Za-z0-9_]+_PASSWORD)=(.*?)([ \t#].*)?$', orig)
                # Accept both historical misspelling 'DEFERED' and the common 'DEFERRED'
                m_pw_defer = re.match(r'^([A-Za-z0-9_]+_PASSWORD_(?:DEFERED|DEFERRED))=(.*?)([ \t#].*)?$', orig)
                m_token_internal = re.match(r'^([A-Za-z0-9_]+_TOKEN_INTERNAL)=(.*?)([ \t#].*)?$', orig)
                m_token_external = re.match(r'^([A-Za-z0-9_]+_TOKEN_EXTERNAL)=(.*?)([ \t#].*)?$', orig)
                m_token_defer = re.match(r'^([A-Za-z0-9_]+_TOKEN_(?:DEFERED|DEFERRED))=(.*?)([ \t#].*)?$', orig)
                # New descriptor patterns: NAME_TOKEN_ALNUM64 or NAME_TOKEN_HEX32, optional trailing
                # suffix _INTERNAL/_EXTERNAL/_DEFERED or _DEFERRED (accept both spellings)
                m_token_desc = re.match(r'^([A-Za-z0-9_]+_TOKEN_(ALNUM|HEX)(\d+))(?:_(INTERNAL|EXTERNAL|DEFERED|DEFERRED))?=(.*?)([ \t#].*)?$', orig)
                m_pw_desc = re.match(r'^([A-Za-z0-9_]+_PASSWORD_(ALNUM|HEX)(\d+))(?:_(?:DEFERED|DEFERRED))?=(.*?)([ \t#].*)?$', orig)
                # SECRET_KEY_BASE is not treated specially by descriptor parsing anymore.
                # Use NAME_PASSWORD_*/NAME_TOKEN_* descriptor forms to request generation.
                # Legacy VAR_TOKEN is no longer supported; use _TOKEN_EXTERNAL or _TOKEN_INTERNAL or the descriptor forms
                
                try:
                    if m_pw:
                        key, val, comment = m_pw.group(1), m_pw.group(2).strip(), m_pw.group(3) or ''
                        if not val:
                            info(f"Generating random password for {key}")
                            val = gen_pw(20)
                        elif 'set password manually later' in val.lower():
                            warn(f"{key} contains a placeholder. Please set a secure password!")
                        # Expand any command substitutions or variable refs so the generated
                        # live env file contains literal values (e.g., UID=$(id -u) -> 1000)
                        write_val = _maybe_expand(val, local_env)
                        fout.write(f"{key}={write_val}{comment}\n")
                        local_env[key] = write_val
                    # SECRET_KEY_BASE descriptor handling removed: use NAME_PASSWORD_* or NAME_TOKEN_* descriptors instead
                    elif m_token_desc:
                        # Descriptor token, e.g. NAME_TOKEN_ALNUM64 or NAME_TOKEN_HEX32, optional trailing INTERNAL/EXTERNAL/DEFERED
                        base_key = m_token_desc.group(1)  # e.g. NAME_TOKEN_ALNUM64
                        charset = m_token_desc.group(2)
                        length = int(m_token_desc.group(3))
                        trailing = m_token_desc.group(4)  # INTERNAL|EXTERNAL|DEFERED or None
                        val = m_token_desc.group(5).strip()
                        comment = m_token_desc.group(6) or ''
                        # construct the actual key name including trailing suffix if present
                        actual_key = base_key + (f"_{trailing}" if trailing else '')
                        if trailing == 'DEFERED':
                            fout.write(f"{actual_key}={val}{comment}\n")
                            local_env[actual_key] = ''
                        else:
                            if not val:
                                info(f"Generating token for {actual_key} ({charset}, len={length})")
                                if charset == 'ALNUM':
                                    gen_val = gen_pw(length)
                                else:
                                    import secrets as _secrets
                                    gen_val = _secrets.token_hex((length + 1) // 2)[:length]
                                val = gen_val
                            try:
                                write_val = _maybe_expand(val, local_env)
                            except Exception:
                                write_val = val
                            fout.write(f"{actual_key}={write_val}{comment}\n")
                            local_env[actual_key] = write_val
                            # Do NOT write the base descriptor name when a trailing suffix
                            # (INTERNAL/EXTERNAL/DEFERED) is present. Compose files should
                            # reference the fully-suffixed variable name (e.g. VAR_TOKEN_HEX32_INTERNAL).

                    elif m_pw_desc:
                        # Descriptor password e.g. NAME_PASSWORD_ALNUM64 (DEFERED allowed)
                        full_key = m_pw_desc.group(1)
                        charset = m_pw_desc.group(2)
                        length = int(m_pw_desc.group(3))
                        val = m_pw_desc.group(4).strip()
                        comment = m_pw_desc.group(5) or ''
                        if val == '' and not full_key.endswith('_DEFERED'):
                            info(f"Generating password for {full_key} ({charset}, len={length})")
                            if charset == 'ALNUM':
                                gen_val = gen_pw(length)
                            else:
                                import secrets as _secrets
                                gen_val = _secrets.token_hex((length + 1) // 2)[:length]
                            val = gen_val
                        try:
                            write_val = _maybe_expand(val, local_env)
                        except Exception:
                            write_val = val
                        fout.write(f"{full_key}={write_val}{comment}\n")
                        local_env[full_key] = write_val

                    elif m_token_internal:
                        # Plain VAR_TOKEN_INTERNAL -> generate a default internal token if empty
                        key, val, comment = m_token_internal.group(1), m_token_internal.group(2).strip(), m_token_internal.group(3) or ''
                        if not val:
                            info(f"Generating internal token for {key}")
                            val = gen_pw(40)
                        try:
                            write_val = _maybe_expand(val, local_env)
                        except Exception:
                            write_val = val
                        fout.write(f"{key}={write_val}{comment}\n")
                        local_env[key] = write_val
                    elif m_token_defer:
                        key, val, comment = m_token_defer.group(1), m_token_defer.group(2).strip(), m_token_defer.group(3) or ''
                        fout.write(f"{key}={val}{comment}\n")
                        local_env[key] = ''
                    elif m_token_external:
                        key, val, comment = m_token_external.group(1), m_token_external.group(2).strip(), m_token_external.group(3) or ''
                        if not val:
                            # First prefer a value supplied in the process environment
                            env_fallback = os.environ.get(key)
                            if env_fallback:
                                info(f"Using provided environment value for external token {key}")
                                val = env_fallback
                            else:
                                # If configured to be strict, abort with an error in non-interactive mode
                                strict = strict_flag(os.environ, 'EXTERNAL')
                                if os.environ.get('COMPINIT_ASSUME_YES', '').lower() in ('1', 'true', 'yes') and strict:
                                    error(f"External token {key} requires input and COMPINIT_STRICT_EXTERNAL=1 enforces strict behavior in non-interactive runs")
                                # If running non-interactive and not strict, warn and leave empty
                                if os.environ.get('COMPINIT_ASSUME_YES', '').lower() in ('1', 'true', 'yes'):
                                    warn(f"{key} is marked EXTERNAL but no value provided; continuing in non-interactive mode with empty value")
                                    val = ''
                                else:
                                    warn(f"{key} is marked EXTERNAL and requires a secret. Please enter the value:")
                                    try:
                                        val = input(f"{key}=").strip()
                                    except (EOFError, KeyboardInterrupt):
                                        error(f"User input required for {key} but not provided")
                        try:
                            write_val = expand_vars(val, local_env)
                        except Exception:
                            write_val = val
                        fout.write(f"{key}={write_val}{comment}\n")
                        local_env[key] = write_val

                    # NOTE: SECRET_KEY_BASE-specific descriptor support has been removed.
                    # Use NAME_PASSWORD_* or NAME_TOKEN_* descriptor forms to request generation.

                    # Legacy VAR_TOKEN is no longer supported; please use VAR_TOKEN_INTERNAL or VAR_TOKEN_EXTERNAL
                        
                    else:
                        if '=' in orig:
                            key, val = orig.split('=', 1)
                            key = key.strip()
                            val = val.strip()
                            # Detect surrounding quotes and preserve them in the generated file.
                            quote_char = None
                            inner = val
                            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                                quote_char = val[0]
                                inner = val[1:-1]

                            # Expand any $(...) or $VAR references now so the generated env
                            # contains literal values instead of runtime substitutions.
                            try:
                                write_val = _maybe_expand(inner, local_env)
                            except Exception:
                                write_val = inner

                            # If the original value was quoted, re-wrap it with the same quote
                            # and escape any inner occurrence of that quote character.
                            if quote_char:
                                esc = write_val.replace(quote_char, '\\' + quote_char)
                                fout.write(f"{key}={quote_char}{esc}{quote_char}\n")
                                local_env[key] = esc
                            else:
                                fout.write(f"{key}={write_val}\n")
                                local_env[key] = write_val
                        else:
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

def parse_toml_sample(toml_path: str, env_path: str) -> None:
    """
    Parse .env.toml file and generate .env with auto-generated passwords and tokens.
    
    This function reads a TOML configuration file and creates a traditional .env
    file by:
    - Auto-generating secure passwords for variables with type="password"
    - Prompting for user input on variables with source="external" that are empty
    - Processing hooks and dependencies
    - Copying all other variables as-is
    
    Args:
        toml_path: Path to the .env.toml file
        env_path: Path to the .env file to create
        
    Raises:
        FileNotFoundError: If toml_path doesn't exist
        ValueError: If TOML configuration is invalid
        IOError: If file operations fail
    """
    if not os.path.isfile(toml_path):
        error(f"TOML configuration file '{toml_path}' not found")
    
    # Check if we can write to the target directory
    target_dir = os.path.dirname(env_path) or '.'
    if not os.access(target_dir, os.W_OK):
        error(f"Cannot write to directory '{target_dir}' for file '{env_path}'")
    
    try:
        # Parse TOML configuration
        config = parse_toml_config(toml_path)
        
        # Validate configuration
        validation_errors = validate_config(config)
        if validation_errors:
            error(f"TOML configuration validation failed:\n  - " + "\n  - ".join(validation_errors))
        
        info(f"Parsed TOML configuration for project: {config.project_name}")
        
        # Generate values for variables that need generation
        generated_values = {}
        local_env = dict(os.environ)
        
        for name, var_config in config.variables.items():
            if var_config.source == "deferred":
                generated_values[name] = ""  # Will be set by hooks
                continue
            
            if var_config.type == "password" and not var_config.value:
                info(f"Generating password for {name} (type={var_config.type}, length={var_config.length})")
                generated_values[name] = gen_pw(var_config.length or 32, var_config.charset)
            elif var_config.type == "token" and not var_config.value:
                if var_config.source == "external":
                    # Handle external tokens
                    env_fallback = os.environ.get(name)
                    if env_fallback:
                        info(f"Using provided environment value for external token {name}")
                        generated_values[name] = env_fallback
                    else:
                        # Prompt for external token or use strict mode handling
                        strict = strict_flag(os.environ, 'EXTERNAL')
                        if os.environ.get('COMPINIT_ASSUME_YES', '').lower() in ('1', 'true', 'yes') and strict:
                            error(f"External token {name} requires input and COMPINIT_STRICT_EXTERNAL=1 enforces strict behavior")
                        if os.environ.get('COMPINIT_ASSUME_YES', '').lower() in ('1', 'true', 'yes'):
                            warn(f"{name} is marked external but no value provided; continuing with empty value")
                            generated_values[name] = ''
                        else:
                            desc = var_config.description or f"External {var_config.type}"
                            warn(f"{name} ({desc}) requires a value. Please enter:")
                            try:
                                generated_values[name] = input(f"{name}=").strip()
                            except (EOFError, KeyboardInterrupt):
                                error(f"User input required for {name} but not provided")
                elif var_config.source == "internal":
                    info(f"Generating internal token for {name} (length={var_config.length})")
                    generated_values[name] = gen_pw(var_config.length or 64, var_config.charset)
                else:
                    generated_values[name] = var_config.value or ""
            elif var_config.value is not None:
                # Use provided value, potentially with expansion
                try:
                    expanded = expand_vars(var_config.value, local_env)
                    generated_values[name] = expanded
                    local_env[name] = expanded
                except Exception:
                    generated_values[name] = var_config.value
                    local_env[name] = var_config.value
            else:
                generated_values[name] = ""
        
        # Convert config to env dict
        env_dict = config_to_env_dict(config, generated_values)
        
        # Write .env file
        with open(env_path, 'w', encoding='utf-8') as f:
            f.write(f"# Generated from {toml_path}\n")
            f.write(f"# Project: {config.project_name} ({config.env_tag})\n\n")
            
            # Write variables in logical groups
            f.write("# Control flow\n")
            for key in ['COMPINIT_COMPOSE_START_MODE', 'COMPINIT_RESET_BEFORE_START', 
                       'COMPINIT_CHECK_IMAGE_ENABLED', 'COMPINIT_IMAGE_CHECK_CONTINUE_ON_ERROR']:
                if key in env_dict:
                    f.write(f"{key}={env_dict[key]}\n")
            
            f.write("\n# Project metadata\n")
            for key in ['LABEL_PROJECT_NAME', 'LABEL_ENV_TAG', 'LABEL_PREFIX']:
                if key in env_dict:
                    f.write(f"{key}={env_dict[key]}\n")
            
            f.write("\n# Infrastructure\n")
            for key in ['PUBLIC_FQDN', 'PUBLIC_TLS_KEY_PEM', 'PUBLIC_TLS_CRT_PEM']:
                if key in env_dict:
                    f.write(f"{key}={env_dict[key]}\n")
            
            f.write("\n# Dependencies and hooks\n")
            for key in ['COMPINIT_DEPENDENCIES', 'COMPINIT_HOOK_PRE_COMPOSE', 'COMPINIT_HOOK_POST_COMPOSE']:
                if key in env_dict:
                    f.write(f"{key}={env_dict[key]}\n")
            
            f.write("\n# Health monitoring\n")
            for key in ['HEALTHCHECK_INTERVAL', 'HEALTHCHECK_TIMEOUT', 'HEALTHCHECK_RETRIES', 'HEALTHCHECK_START_PERIOD']:
                if key in env_dict:
                    f.write(f"{key}={env_dict[key]}\n")
            
            f.write("\n# User variables\n")
            for key in ['UID', 'GID']:
                if key in env_dict:
                    f.write(f"{key}={env_dict[key]}\n")
            
            f.write("\n# Project variables\n")
            for name, var_config in config.variables.items():
                value = generated_values.get(name, var_config.value or "")
                if var_config.description:
                    f.write(f"# {var_config.description}\n")
                
                # Preserve quotes for string values that need them
                if var_config.type == "string" and value and (' ' in value or "'" in value):
                    escaped = value.replace('"', '\\"')
                    f.write(f'{name}="{escaped}"\n')
                else:
                    f.write(f"{name}={value}\n")
            
            f.write("\n# Additional variables\n")
            for key, value in env_dict.items():
                if key not in config.variables and not any(key.startswith(prefix) for prefix in 
                    ['COMPINIT_', 'LABEL_', 'PUBLIC_', 'HEALTHCHECK_', 'UID', 'GID']):
                    f.write(f"{key}={value}\n")
        
        info(f"Generated .env file from TOML configuration: {env_path}")
        
    except Exception as e:
        error(f"Failed to process TOML configuration: {e}")


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


def persist_env_vars(env_file: str, new_vars: Dict[str, str]) -> None:
    """
    Persist or update key=value pairs into the env_file. If a key exists, replace its value.
    Otherwise, append the new key=value at the end.
    """
    try:
        # Read existing lines
        lines = []
        if os.path.isfile(env_file):
            with open(env_file, 'r', encoding='utf-8') as f:
                lines = f.readlines()

        # Build map of existing keys to line index
        key_line_map = {}
        for idx, raw in enumerate(lines):
            s = raw.strip()
            if not s or s.startswith('#') or '=' not in s:
                continue
            k = s.split('=', 1)[0].strip()
            key_line_map[k] = idx

        # Update existing keys or append
        for k, v in new_vars.items():
            entry = f"{k}={v}\n"
            if k in key_line_map:
                lines[key_line_map[k]] = entry
            else:
                lines.append(entry)

        # Write back atomically
        tmp = env_file + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.writelines(lines)
        os.replace(tmp, env_file)
        info(f"Persisted {len(new_vars)} variables into {env_file}")
    except Exception as e:
        warn(f"Failed to persist variables into {env_file}: {e}")


def resolve_dependencies(env_vars: Dict[str, str], current_dir: str, visited: Optional[Set[str]] = None) -> List[str]:
    """
    Resolve dependency chain from COMPINIT_DEPENDENCIES variable.
    Returns list of absolute dependency paths in start order (dependencies first).
    
    Args:
        env_vars: Environment variables containing COMPINIT_DEPENDENCIES
        current_dir: Current project directory (absolute path)
        visited: Set of visited directories for cycle detection
        
    Returns:
        List of absolute paths to start in order
        
    Raises:
        ValueError: If dependency cycle detected or invalid path
    """
    if visited is None:
        visited = set()
    
    current_abs = os.path.abspath(current_dir)
    if current_abs in visited:
        error(f"Dependency cycle detected: {current_abs} is already in the dependency chain")
    
    visited.add(current_abs)
    dependencies = []
    
    # Parse COMPINIT_DEPENDENCIES (comma or colon separated relative/absolute paths)
    deps_str = env_vars.get('COMPINIT_DEPENDENCIES', '').strip()
    if not deps_str:
        return [current_abs]  # No dependencies, just return self
    
    dep_paths = [d.strip() for d in deps_str.replace(':', ',').split(',') if d.strip()]
    
    for dep_path in dep_paths:
        # Convert relative paths to absolute (relative to current project)
        if not os.path.isabs(dep_path):
            dep_abs = os.path.abspath(os.path.join(current_dir, dep_path))
        else:
            dep_abs = os.path.abspath(dep_path)
        
        if not os.path.isdir(dep_abs):
            error(f"Dependency directory does not exist: {dep_abs}")
        
        # Check for .env.sample in dependency
        dep_sample = os.path.join(dep_abs, '.env.sample')
        if not os.path.isfile(dep_sample):
            warn(f"Dependency {dep_abs} has no .env.sample, skipping")
            continue
        
        # Recursively resolve dependencies of this dependency
        try:
            # Load dependency's env to check for its own dependencies
            dep_env_vars, _ = load_env_file(os.path.join(dep_abs, '.env.sample'))
            sub_deps = resolve_dependencies(dep_env_vars, dep_abs, visited.copy())
            dependencies.extend(sub_deps)
        except Exception as e:
            warn(f"Failed to resolve dependencies for {dep_abs}: {e}")
            dependencies.append(dep_abs)
    
    # Remove duplicates while preserving order
    seen = set()
    ordered_deps = []
    for dep in dependencies:
        if dep not in seen:
            seen.add(dep)
            ordered_deps.append(dep)
    
    # Add current directory last (after all dependencies)
    if current_abs not in seen:
        ordered_deps.append(current_abs)
    
    visited.remove(current_abs)
    return ordered_deps


def start_dependencies(dependency_paths: List[str], current_dir: str) -> None:
    """
    Start dependencies by recursively calling compose-init-up.py in each dependency directory.
    
    Args:
        dependency_paths: List of absolute paths to dependency directories
        current_dir: Current project directory (to skip when processing)
    """
    current_abs = os.path.abspath(current_dir)
    script_path = os.path.abspath(__file__)
    
    for dep_path in dependency_paths:
        if dep_path == current_abs:
            continue  # Skip self, will be started by main flow
        
        step(f"Starting dependency: {dep_path}")
        
        # Check if dependency is already running (basic heuristic)
        try:
            dep_env_file = os.path.join(dep_path, '.env')
            if os.path.isfile(dep_env_file):
                dep_env, _ = load_env_file(dep_env_file)
                # Try to detect if services are already running by checking common ports
                # This is a basic check - could be enhanced with actual service health checks
                info(f"Dependency {dep_path} has .env file, checking if already running...")
        except Exception:
            pass
        
        # Run compose-init-up.py in the dependency directory
        cmd = f"python3 {script_path} -d {dep_path} -y"
        try:
            info(f"Executing: {cmd}")
            result = subprocess.run(
                shlex.split(cmd),
                check=True,
                capture_output=True,
                text=True,
                timeout=300
            )
            info(f"Dependency {dep_path} started successfully")
            if result.stdout:
                info(f"Dependency output: {result.stdout.strip()}")
        except subprocess.CalledProcessError as e:
            error(f"Failed to start dependency {dep_path}: {e}\nStderr: {e.stderr}")
        except subprocess.TimeoutExpired:
            error(f"Timeout starting dependency {dep_path} (>5 minutes)")
        except Exception as e:
            error(f"Unexpected error starting dependency {dep_path}: {e}")



def generate_skeleton_toml(toml_out: str) -> None:
    """
    Dynamically generate a minimal `.env.toml` skeleton from CONFIG_VARIABLES.
    """
    # Determine a sensible default public FQDN by querying an external IP and
    # performing a reverse DNS lookup. This helps generate a more useful
    # skeleton for users who run the helper locally on a public host.
    def get_external_ip() -> str:
        # Allow overriding endpoints via environment variable
        urls = os.environ.get('COMPINIT_IP_DETECT_URLS')
        if urls:
            endpoints = [u.strip() for u in urls.split(',') if u.strip()]
        else:
            endpoints = DEFAULT_IP_DETECT_URLS

        for url in endpoints:
            try:
                with urllib.request.urlopen(url, timeout=5) as r:
                    ip = r.read().decode().strip()
                    # basic sanity check for IPv4/IPv6 or hostnames that may be returned
                    if ip:
                        return ip
            except Exception:
                continue
        return ''

    def reverse_dns(ip: str) -> str:
        try:
            name, _, _ = socket.gethostbyaddr(ip)
            return name.rstrip('.')
        except Exception:
            return ''

    def get_default_public_fqdn() -> str:
        # Prefer detected reverse DNS if available, otherwise fall back to
        # the configured CONFIG_VARIABLE default.
        ip = get_external_ip()
        if not ip:
            return next((v['default'] for v in CONFIG_VARIABLES if v['name'] == 'PUBLIC_FQDN'), 'example.local')
        rdns = reverse_dns(ip)
        if rdns:
            return rdns
        return ip

    detected_fqdn = get_default_public_fqdn()

    lines = [
        "# Project configuration in TOML format",
        "# This replaces .env.sample with better structure and metadata support",
        "",
        "[metadata]",
        f"project_name = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='LABEL_PROJECT_NAME'), 'my-project')}\"",
        f"env_tag = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='LABEL_ENV_TAG'), 'dev')}\"",
        f"label_prefix = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='LABEL_PREFIX'), 'example.com')}\"",
        "",
        "[control]",
    ]

    # Inject allowed-values metadata for control variables when available
    start_allowed = next((v.get('allowed_values') for v in CONFIG_VARIABLES if v['name']=='COMPINIT_COMPOSE_START_MODE'), None)
    if start_allowed:
        lines.append(f"# compose_start_mode allowed values: {' | '.join(start_allowed)}")
    else:
        lines.append("# compose_start_mode: how to behave when starting services that fail to start")

    lines.append(f"compose_start_mode = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='COMPINIT_COMPOSE_START_MODE'), 'abort-on-failure')}\"")

    reset_allowed = next((v.get('allowed_values') for v in CONFIG_VARIABLES if v['name']=='COMPINIT_RESET_BEFORE_START'), None)
    if reset_allowed:
        lines.append(f"# reset_before_start allowed values: {' | '.join(reset_allowed)}")
    else:
        lines.append("# reset_before_start: actions to perform before starting (comma-separated)")
        lines.append("#  options: none | containers | named-volumes | hostdirs | all")

    lines.extend([
        f"reset_before_start = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='COMPINIT_RESET_BEFORE_START'), 'none')}\"",
        f"image_check_enabled = {str(next((v['default'] for v in CONFIG_VARIABLES if v['name']=='COMPINIT_CHECK_IMAGE_ENABLED'), 'false')).lower()}",
        f"image_check_continue_on_error = {str(next((v['default'] for v in CONFIG_VARIABLES if v['name']=='COMPINIT_IMAGE_CHECK_CONTINUE_ON_ERROR'), '0'))}",
        "",
        "[infrastructure]",
        f"# Suggested default detected from your external IP (reverse DNS or IP): {detected_fqdn}",
        f"public_fqdn = \"{detected_fqdn}\"",
        f"public_tls_key_pem = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='PUBLIC_TLS_KEY_PEM'), '/etc/letsencrypt/live/$PUBLIC_FQDN/privkey.pem')}\"",
        f"public_tls_crt_pem = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='PUBLIC_TLS_CRT_PEM'), '/etc/letsencrypt/live/$PUBLIC_FQDN/fullchain.pem')}\"",
        "",
        "[health]",
        f"interval = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='HEALTHCHECK_INTERVAL'), '10s')}\"",
        f"timeout = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='HEALTHCHECK_TIMEOUT'), '5s')}\"",
        f"retries = {next((v['default'] for v in CONFIG_VARIABLES if v['name']=='HEALTHCHECK_RETRIES'), '3')}",
        f"start_period = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='HEALTHCHECK_START_PERIOD'), '30s')}\"",
        "",
        "[user]",
        f"uid = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='UID'), '$(id -u)')}\"",
        f"gid = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='GID'), '$(id -g)')}\"",
        "",
        "[dependencies]",
        "paths = []",
        "",
        "[hooks]",
        "pre_compose = []",
        "post_compose = []",
        "",
        "[variables]",
        "# Variables: type, default, description, allowed_values (if any)",
    ])

    # Emit detailed variable metadata entries for the TOML variables section
    for var in CONFIG_VARIABLES:
        name = var.get('name')
        vtype = var.get('type', 'string')
        default = var.get('default', '')
        desc = var.get('description', '')
        allowed = var.get('allowed_values')

        # Build a TOML inline table for metadata
        meta_parts = [f'type = "{vtype}"']
        if default is not None and default != '':
            # escape double quotes in default
            safe_def = str(default).replace('"', '\\"')
            meta_parts.append(f'default = "{safe_def}"')
        if desc:
            safe_desc = str(desc).replace('"', '\\"')
            meta_parts.append(f'description = "{safe_desc}"')
        if allowed:
            # format allowed values as TOML array of strings
            allowed_list = ', '.join([f'"{a}"' for a in allowed])
            meta_parts.append(f'allowed_values = [{allowed_list}]')

        meta_entry = f"{name} = {{{', '.join(meta_parts)}}}"
        lines.append(meta_entry)
    with open(toml_out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    info(f"Generated skeleton TOML configuration: {toml_out}")



def generate_skeleton_env(sample_out: str) -> None:
    """
    Dynamically generate a minimal `.env.sample` skeleton from CONFIG_VARIABLES.
    """
    # Try to detect a sensible public_fqdn as default similar to TOML skeleton
    def detect_public_fqdn_for_env() -> str:
        # Reuse the same multi-endpoint detection as the TOML generator
        urls = os.environ.get('COMPINIT_IP_DETECT_URLS')
        if urls:
            endpoints = [u.strip() for u in urls.split(',') if u.strip()]
        else:
            endpoints = DEFAULT_IP_DETECT_URLS

        for url in endpoints:
            try:
                with urllib.request.urlopen(url, timeout=5) as r:
                    ip = r.read().decode().strip()
                try:
                    name, _, _ = socket.gethostbyaddr(ip)
                    return name.rstrip('.')
                except Exception:
                    return ip
            except Exception:
                continue
        return next((v['default'] for v in CONFIG_VARIABLES if v['name'] == 'PUBLIC_FQDN'), 'example.local')

    detected_env_fqdn = detect_public_fqdn_for_env()
    lines = [
        "# Generated minimal .env.sample by compose-init-up.py",
        "# Edit and extend with your service-specific variables.",
        "",
        "# compose_start_mode: how to behave when starting services that fail to start", 
        "#   abort-on-failure (default) | continue-on-error",
        "# reset_before_start: actions before start: none | containers | named-volumes | hostdirs | all",
    ]

    for var in CONFIG_VARIABLES:
        if var.get("description"):
            lines.append(f"# {var['description']}")
        if var['name'] == 'PUBLIC_FQDN':
            lines.append(f"{var['name']}={detected_env_fqdn}")
        else:
            lines.append(f"{var['name']}={var['default']}")
    lines.append("")
    with open(sample_out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    info(f"Wrote skeleton .env.sample to {sample_out}")


def _load_toml_dict(path: str) -> dict:
    """Load TOML file into a dict. Uses tomllib (py3.11) or tomli fallback.

    Returns empty dict if file does not exist.
    """
    if not os.path.isfile(path):
        return {}
    try:
        import tomllib
    except Exception:
        try:
            import importlib
            tomllib = importlib.import_module('tomli')
        except Exception:
            warn("TOML parsing not available (tomllib/tomli). Cannot load: %s" % path)
            return {}
    try:
        with open(path, 'rb') as f:
            return tomllib.load(f)
    except Exception as e:
        warn(f"Failed to parse TOML file {path}: {e}")
        return {}


def _write_local_toml_variables(local_path: str, updates: Dict[str, str]) -> None:
    """Persist simple [variables] assignments into a per-project local TOML file.

    This file is intended to be git-ignored and only store non-sensitive
    overrides produced at runtime (hook outputs, local secrets). Only simple
    string values are supported here. Existing local file content will be
    merged (variables section updated); other sections are preserved if
    present.
    """
    # Load existing content if present
    data = _load_toml_dict(local_path)
    if not isinstance(data, dict):
        data = {}
    vars_section = data.get('variables', {}) or {}
    # Merge updates (overwriting existing keys)
    for k, v in updates.items():
        vars_section[k] = v
    data['variables'] = vars_section

    # Emit a minimal TOML file preserving top-level sections (simple serializer)
    try:
        with open(local_path, 'w', encoding='utf-8') as f:
            # Write metadata if present
            if 'metadata' in data and isinstance(data['metadata'], dict):
                f.write('[metadata]\n')
                for mk, mv in data['metadata'].items():
                    safe_mv = str(mv).replace('"', '\\"')
                    f.write(f'{mk} = "{safe_mv}"\n')
                f.write('\n')

            # Write variables section
            f.write('[variables]\n')
            for k, v in data['variables'].items():
                # Only simple string values supported here
                safe = str(v).replace('"', '\\"')
                f.write(f'{k} = "{safe}"\n')
            f.write('\n')
    except Exception as e:
        warn(f"Unable to persist local TOML overrides to {local_path}: {e}")

def _append_or_replace_section(toml_path: str, section: str, kv: Dict[str, str]) -> None:
    """Append or replace a simple top-level section with flat key/value pairs.
    Only supports string serialisation; creates file if absent."""
    try:
        content = ''
        if os.path.isfile(toml_path):
            with open(toml_path, 'r', encoding='utf-8') as f:
                content = f.read()
        lines = []
        in_target = False
        replaced = False
        if content:
            for line in content.splitlines():
                if line.strip().startswith(f'[{section}]'):
                    # skip old section
                    in_target = True
                    replaced = True
                    continue
                if in_target and line.startswith('['):
                    in_target = False
                if not in_target:
                    lines.append(line)
        if lines and lines[-1].strip() != '':
            lines.append('')
        lines.append(f'[{section}]')
        for k, v in kv.items():
            safe = str(v).replace('"', '\"')
            lines.append(f'{k} = "{safe}"')
        lines.append('')
        with open(toml_path, 'w', encoding='utf-8') as f:
            f.write('\n'.join([l for l in lines if l is not None]))
        debug(f"Updated section [{section}] in {toml_path} (replaced={replaced})")
    except Exception as e:
        warn(f"Failed to update section [{section}] in {toml_path}: {e}")

def _secret_hash(val: str) -> str:
    try:
        import hashlib
        return hashlib.sha256(val.encode()).hexdigest()[:16]
    except Exception:
        return 'hash_err'

def _purge_secret_stub(name: str) -> None:
    # Placeholder for Vault delete integration
    debug(f"Purging secret (stub): {name}")


def _merge_global_project_local_toml(global_path: str, project_path: str, local_path: str, merged_out: str) -> None:
    """Merge global -> project -> local TOML dicts and write a merged TOML file.

    The merged file is a simple serialization that covers the common sections
    we need: metadata, control, infrastructure, health, user, registry, variables, hooks, dependencies.
    This is used at runtime so we don't have to rewrite the original project file.
    """
    # Support multiple global TOML files discovered by walking up the tree when
    # a basename like 'compose.config.global.toml' is provided. Apply
    # furthest-away-first (i.e., topmost parent first) so nearer project-level
    # values override more distant repo/global defaults.
    g = {}
    if global_path:
        # If a simple basename is given, search upward from cwd for matches
        if os.path.basename(global_path) == global_path:
            # walk from cwd up to filesystem root
            collected = []
            cur = Path(os.getcwd()).resolve()
            for parent in [cur] + list(cur.parents):
                cand = os.path.join(str(parent), global_path)
                if os.path.isfile(cand):
                    collected.append(cand)
            # Apply furthest-away-first: reverse collected so root-most first
            for path in reversed(collected):
                try:
                    d = _load_toml_dict(path)
                    if isinstance(d, dict):
                        # overlay into g
                        for k, v in d.items():
                            if k not in g:
                                g[k] = {}
                            if isinstance(v, dict):
                                g[k].update(v)
                except Exception:
                    continue
        else:
            g = _load_toml_dict(global_path) if global_path else {}
    p = _load_toml_dict(project_path) if project_path else {}
    l = _load_toml_dict(local_path) if local_path else {}

    def merged_section(name: str):
        out = {}
        for src in (g.get(name, {}), p.get(name, {}), l.get(name, {})):
            if isinstance(src, dict):
                out.update(src)
        return out

    merged = {}
    # Include metadata (take project metadata primarily)
    merged['metadata'] = merged_section('metadata') or p.get('metadata', g.get('metadata', {}))
    # Sections to merge
    for sec in ('control', 'infrastructure', 'health', 'user', 'registry'):
        sec_val = merged_section(sec)
        if sec_val:
            merged[sec] = sec_val

    # Dependencies and hooks
    deps = []
    for src in (g.get('dependencies', {}), p.get('dependencies', {}), l.get('dependencies', {})):
        if isinstance(src, list):
            deps.extend(src)
        elif isinstance(src, dict) and 'paths' in src:
            deps.extend(src.get('paths', []))
    if deps:
        merged['dependencies'] = {'paths': deps}

    # Hooks
    hooks = {}
    for k in ('pre_compose', 'post_compose'):
        combined = []
        for src in (g.get('hooks', {}).get(k, []), p.get('hooks', {}).get(k, []), l.get('hooks', {}).get(k, [])):
            if isinstance(src, list):
                combined.extend(src)
            elif isinstance(src, str):
                combined.append(src)
        if combined:
            hooks[k] = combined
    if hooks:
        merged['hooks'] = hooks

    # Merge variables (global -> project -> local)
    vars_merged = {}
    for src in (g.get('variables', {}), p.get('variables', {}), l.get('variables', {})):
        if isinstance(src, dict):
            for k, v in src.items():
                vars_merged[k] = v
    if vars_merged:
        merged['variables'] = vars_merged

    # Emit merged TOML (minimal serializer)
    try:
        with open(merged_out, 'w', encoding='utf-8') as f:
            # Metadata
            if 'metadata' in merged and isinstance(merged['metadata'], dict):
                f.write('[metadata]\n')
                for mk, mv in merged['metadata'].items():
                    safe_mv = str(mv).replace('"', '\\"')
                    f.write(f'{mk} = "{safe_mv}"\n')
                f.write('\n')

            for sec in ('control', 'infrastructure', 'health', 'user', 'registry'):
                if sec in merged:
                    f.write(f'[{sec}]\n')
                    for k, v in merged[sec].items():
                        if isinstance(v, bool):
                            val = 'true' if v else 'false'
                            f.write(f'{k} = {val}\n')
                        else:
                            safe = str(v).replace('"', '\\"')
                            f.write(f'{k} = "{safe}"\n')
                    f.write('\n')

            if 'dependencies' in merged and isinstance(merged['dependencies'], dict):
                f.write('[dependencies]\n')
                paths = merged['dependencies'].get('paths', [])
                if isinstance(paths, list):
                    f.write('paths = [')
                    f.write(', '.join([f'"{p}"' for p in paths]))
                    f.write(']\n\n')

            if 'hooks' in merged and isinstance(merged['hooks'], dict):
                f.write('[hooks]\n')
                for k, arr in merged['hooks'].items():
                    if isinstance(arr, list):
                        f.write(f'{k} = [')
                        f.write(', '.join([f'"{x}"' for x in arr]))
                        f.write(']\n')
                f.write('\n')

            if 'variables' in merged and isinstance(merged['variables'], dict):
                f.write('[variables]\n')
                for k, v in merged['variables'].items():
                    if isinstance(v, dict) and 'value' in v:
                        safe = str(v['value']).replace('"', '\\"')
                        f.write(f'{k} = "{safe}"\n')
                    elif isinstance(v, str):
                        safe = v.replace('"', '\\"')
                        f.write(f'{k} = "{safe}"\n')
                    else:
                        # Fallback to string representation
                        safe = str(v).replace('"', '\\"')
                        f.write(f'{k} = "{safe}"\n')
                f.write('\n')
    except Exception as e:
        warn(f"Failed to write merged TOML to {merged_out}: {e}")


def migrate_env_sample_to_toml(sample_path: str, toml_out: str) -> None:
    """
    Migrate a legacy .env.sample (or .env) to a simple TOML configuration.

    The migration attempts to preserve variable names and values. It will
    heuristically map variable names to TOML variable metadata:
      - *_PASSWORD -> type=password
      - *_PASSWORD_DEFERED -> source=deferred
      - *_TOKEN_INTERNAL -> type=token, source=internal
      - *_TOKEN_EXTERNAL -> type=token, source=external
      - other -> type=string

    This produces a conservative TOML suitable as a starting point for
    manual editing.
    """
    if not os.path.isfile(sample_path):
        error(f"Cannot migrate: sample file not found: {sample_path}")

    env_vars, _ = load_env_file(sample_path)

    lines = [
        "# Migrated TOML configuration generated from legacy .env.sample",
        "# Review and adjust types/sources as needed",
        "",
        "[metadata]",
        f"project_name = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='LABEL_PROJECT_NAME'), 'my-project')}\"",
        f"env_tag = \"{next((v['default'] for v in CONFIG_VARIABLES if v['name']=='LABEL_ENV_TAG'), 'dev')}\"",
        "",
        "[variables]",
    ]

    def var_entry(k: str, v: str) -> str:
        # Decide type/source heuristics
        entry = None
        # Accept both historical misspelling 'DEFERED' and correct 'DEFERRED'
        if k.endswith('_PASSWORD_DEFERED') or k.endswith('_PASSWORD_DEFERRED'):
            entry = f'{k} = {{ type = "password", source = "deferred" }}'
        elif k.endswith('_PASSWORD'):
            entry = f'{k} = {{ type = "password", value = "{v}" }}'
        elif k.endswith('_TOKEN_INTERNAL'):
            entry = f'{k} = {{ type = "token", source = "internal", value = "{v}" }}'
        elif k.endswith('_TOKEN_EXTERNAL'):
            entry = f'{k} = {{ type = "token", source = "external", value = "{v}" }}'
        elif '_TOKEN_' in k or k.endswith('_TOKEN'):
            entry = f'{k} = {{ type = "token", value = "{v}" }}'
        else:
            # default to string
            # Escape double quotes
            safe = v.replace('"', '\\"') if isinstance(v, str) else str(v)
            entry = f'{k} = {{ type = "string", value = "{safe}" }}'
        return entry

    for k in sorted(env_vars.keys()):
        v = env_vars.get(k, '')
        lines.append(var_entry(k, v))

    with open(toml_out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')

    info(f"Migrated {sample_path} -> {toml_out}")


# Legacy mapping helper removed: scripts now require canonical variable names only.

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



def run_hooks(hook_type: str, env_vars: Dict[str, str], project_config: Optional[ProjectConfig] = None) -> Dict[str, str]:
    """Execute pre/post compose hooks and return environment variable changes.
    
    Args:
        hook_type: Either 'PRE_COMPOSE' or 'POST_COMPOSE'
        env_vars: Current environment variables
        
    Returns:
        Dict of environment variable changes from hooks
    """
    # Determine ordered hook list. Prefer project_config hooks when provided
    paths = []
    if project_config:
        hooks_list = project_config.pre_compose_hooks if hook_type == 'PRE_COMPOSE' else project_config.post_compose_hooks
        if hooks_list:
            for hc in hooks_list:
                try:
                    paths.append(hc.script)
                except Exception:
                    # Skip malformed HookConfig entries
                    continue

    # Fallback to environment variable listing if no project_config hooks provided
    if not paths:
        hook_var = f'COMPINIT_HOOK_{hook_type}'
        hook_paths = env_vars.get(hook_var, '').strip()
        if not hook_paths:
            return {}
        paths = [p.strip() for p in hook_paths.split(',') if p.strip()]

    # Normalized metadata map: name -> {'value':..., 'persist': 'auto'|'none'|'env'|'project', 'sensitive': bool, 'source_hook': str}
    meta_changes: Dict[str, Dict[str, Any]] = {}

    for hook_path in paths:
        if not os.path.isfile(hook_path):
            warn(f"Hook file not found: {hook_path}")
            continue

        try:
            info(f"Executing {hook_type.lower()} hook: {hook_path}")

            # Import hook module dynamically
            import importlib.util
            spec = importlib.util.spec_from_file_location("hook_module", hook_path)
            if not spec or not spec.loader:
                warn(f"Could not load hook module: {hook_path}")
                continue

            hook_module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(hook_module)

            # Require class-based hook with exact class name, e.g. PreComposeHook or PostComposeHook
            hook_class_name = f'{hook_type.title().replace("_", "")}Hook'
            if hasattr(hook_module, hook_class_name):
                hook_class = getattr(hook_module, hook_class_name)
                # Determine restricted environment to give to hook (only env_reads if declared)
                hook_env = dict(os.environ)
                matching = None
                if project_config:
                    for hc in (project_config.pre_compose_hooks if hook_type == 'PRE_COMPOSE' else project_config.post_compose_hooks):
                        try:
                            if os.path.abspath(hc.script) == os.path.abspath(hook_path) or os.path.basename(hc.script) == os.path.basename(hook_path):
                                matching = hc
                                break
                        except Exception:
                            continue
                    if matching and getattr(matching, 'env_reads', None):
                        hook_env = {k: os.environ.get(k, '') for k in matching.env_reads}

                # Instantiate hook. Try no-arg constructor first, then fallback to constructor accepting env
                try:
                    hook_instance = hook_class()
                except TypeError:
                    try:
                        hook_instance = hook_class(hook_env)
                    except Exception:
                        # last-resort, instantiate without args and hope for the best
                        hook_instance = hook_class()

                # Execute hook.run with the limited hook_env (if available)
                try:
                    hook_changes = hook_instance.run(hook_env) if hasattr(hook_instance, 'run') else {}
                except Exception as e:
                    warn(f"Hook {hook_path} raised an exception during run(): {e}")
                    hook_changes = {}

                if hook_changes:
                    # Normalize different return structures into meta_changes
                    # Supported return shapes:
                    # - dict of name -> value (legacy)
                    # - dict of name -> {value:, persist:, sensitive:}
                    # - list of dicts [{name:, value:, persist:, sensitive:}, ...]
                    try:
                        if isinstance(hook_changes, dict):
                                    for k, raw in hook_changes.items():
                                        if isinstance(raw, dict):
                                            val = raw.get('value')
                                            persist = raw.get('persist', 'auto')
                                            sensitive = bool(raw.get('sensitive', False))
                                        else:
                                            val = raw
                                            persist = 'auto'
                                            sensitive = False
                                        # If key already present from earlier hooks, later hooks override
                                        meta_changes[k] = {'value': val, 'persist': persist, 'sensitive': sensitive, 'source_hook': hook_path}
                        elif isinstance(hook_changes, list):
                            for item in hook_changes:
                                if not isinstance(item, dict):
                                    continue
                                name = item.get('name') or item.get('var') or item.get('key')
                                if not name:
                                    continue
                                val = item.get('value')
                                persist = item.get('persist', 'auto')
                                sensitive = bool(item.get('sensitive', False))
                                meta_changes[name] = {'value': val, 'persist': persist, 'sensitive': sensitive, 'source_hook': hook_path}
                        else:
                            warn(f"Hook {hook_path} returned unsupported type {type(hook_changes)}; expected dict or list")
                    except Exception as e:
                        warn(f"Failed to normalize hook result from {hook_path}: {e}")
                    info(f"Hook {hook_path} returned {len(hook_changes) if hasattr(hook_changes, '__len__') else '1'} changes (normalized to {len(meta_changes)} meta entries)")
            else:
                warn(f"Hook {hook_path} does not define required class {hook_class_name}; only class-based hooks are supported")

        except Exception as e:
            warn(f"Error executing hook {hook_path}: {e}")
            continue

    # Post-validate against declared HookConfig env_reads/env_writes/env_modifies/env_exports when available
    if project_config and meta_changes:
        hooks_list = project_config.pre_compose_hooks if hook_type == 'PRE_COMPOSE' else project_config.post_compose_hooks
        for hc in (hooks_list or []):
            try:
                hc_script_abs = os.path.abspath(hc.script)
            except Exception:
                hc_script_abs = hc.script
            for var_name, meta in list(meta_changes.items()):
                # Only validate entries that this hook produced
                try:
                    if not meta.get('source_hook'):
                        continue
                    if not (os.path.abspath(meta.get('source_hook')) == os.path.abspath(hc.script) or os.path.basename(meta.get('source_hook')) == os.path.basename(hc.script)):
                        continue
                except Exception:
                    continue
                # Allowed writes are env_writes, env_modifies, and env_exports
                allowed = set((getattr(hc, 'env_writes', []) or []) + (getattr(hc, 'env_modifies', []) or []) + (getattr(hc, 'env_exports', []) or []))
                if allowed and var_name not in allowed:
                    warn(f"Hook {hc.script} attempted to return variable '{var_name}' which is not declared in env_writes/env_modifies/env_exports ({', '.join(sorted(allowed))})")

    return meta_changes

def usage_notes() -> str:
    """
    Dynamically render usage notes and variable documentation from CONFIG_VARIABLES.
    """
    notes = [
        "Extended usage notes for compose-init-up.py\n",
        "- TOML-first: prefer a .env.toml configuration for new projects (recommended).",
        "- Legacy support is opt-in: pass --env-legacy to allow parsing legacy .env.sample/.env files. Without --env-legacy, legacy files will be refused and you will be offered a migration to TOML.",
        "- Hooks: only class-based Python hooks are supported. Define PreComposeHook and PostComposeHook classes with a run(env) method. Legacy stdout/main-based hooks are not supported.",
        "- Use COMPINIT_DEPENDENCIES to list dependency directories (comma-separated) that must be started first.",
        "- Use COMPINIT_IMAGE_CHECK_ENABLED to enable/disable image availability checks.",
        "- Use --init-skel-toml to generate a skeleton .env.sample.toml, --init-skel-env for legacy .env.sample.",
        "- COMPINIT_MYREGISTRY_URL can be set to a local registry mirror to speed pulls.",
        "- COMPINIT_ASSUME_YES=1 will run non-interactively and skip prompts (useful in CI).",
        "- COMPINIT_EXTERNAL_STRICT=1 will make missing EXTERNAL tokens a hard error in non-interactive mode.",
        "- COMPINIT_ENABLE_ENV_EXPANSION controls whether $VAR and $(cmd) expansions are applied at runtime; by default generated .env contains literal expanded values where appropriate.",
        "\n- New: prefer COMPINIT_STRICT_<NAME> variables for per-feature strict toggles (e.g. COMPINIT_STRICT_EXTERNAL, COMPINIT_STRICT_EXPANSION). Do NOT implement runtime fallbacks or compatibility shims that check for the legacy COMPINIT_<NAME>_STRICT variables. When changing strict-related behavior, perform a repository-wide refactor: update code, tests, documentation, and CI so only the canonical COMPINIT_STRICT_<NAME> names are used.",
        "\nDocker Hub rate-limiting and best practices:",
        "    See: https://docs.docker.com/docker-hub/usage/\n",
        "\nCanonical config variables:\n"
    ]
    for var in CONFIG_VARIABLES:
        notes.append(f"- {var['name']}: {var['description']} (default: {var['default']})")
    notes.append("\nKEEP IN SYNC: When changing the list above, also update the .env.sample and docs that mention COMPINIT_* variable names.")
    return '\n'.join(notes)


def check_myregistry(url: str, env: Dict[str, str]) -> Tuple[bool, str]:
    """
    Check if COMPINIT_MYREGISTRY_URL is reachable and optionally test credentials.
    Returns (ok, message). Verbose output helps debugging registry auth and reachability.
    """
    if not url:
        return False, 'No registry URL provided'

    try:
        info(f"Checking registry URL: {url}")

        # Build a test image reference that targets the registry host if possible.
        # If user provided a full registry URL like myregistry.local:5000, use that as host for a small image.
        # Otherwise fall back to a small public image to at least verify Docker can reach registries.
        user_host = url.strip().rstrip('/')
        test_image = os.environ.get('COMPINIT_MYREGISTRY_TEST_IMAGE', None)
        if test_image:
            target_image = test_image
        else:
            # Use an extremely small manifest target; prefer 'alpine:3.18' or busybox
            target_image = f"{user_host}/busybox:1" if ':' in user_host or '/' in user_host else 'busybox:1'

        info(f"Attempting docker manifest inspect for: {target_image}")

        # Support optional basic auth via COMPINIT_MYREGISTRY_USER / COMPINIT_MYREGISTRY_PASSWORD
        auth_user = os.environ.get('COMPINIT_MYREGISTRY_USER') or os.environ.get('COMPINIT_MYREGISTRY_USERNAME')
        auth_pw = os.environ.get('COMPINIT_MYREGISTRY_PASSWORD') or os.environ.get('COMPINIT_MYREGISTRY_TOKEN')

        # Build docker CLI command; avoid --insecure by default, allow operator to set DOCKER CLI configs.
        cmd = ["docker", "manifest", "inspect", target_image]

        # If auth is provided, try to login temporarily to enable authenticated inspect (best-effort).
        logged_in = False
        login_cmd = None
        if auth_user and auth_pw:
            try:
                info("Attempting docker login to provided registry for authenticated check (credentials from env)")
                # docker login requires host only; extract host portion
                registry_host = user_host
                login_cmd = ["docker", "login", registry_host, "-u", auth_user, "--password-stdin"]
                p = subprocess.run(login_cmd, input=auth_pw, text=True, capture_output=True, timeout=20)
                if p.returncode == 0:
                    logged_in = True
                    info("Docker login succeeded for registry host")
                else:
                    warn(f"Docker login returned non-zero: {p.stderr or p.stdout}")
            except Exception as e:
                warn(f"Docker login attempt failed: {e}")

        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
            out = (res.stdout or '').strip()
            err = (res.stderr or '').strip()
            if res.returncode == 0:
                return True, 'Registry and credentials appear to be working (manifest inspect OK)'
            else:
                # Detect Docker Hub rate-limit hints
                lowered = (err + out).lower()
                if 'toomanyrequests' in lowered or 'rate limit' in lowered:
                    return False, 'Manifest inspect failed: Docker Hub rate limit or too many requests. See https://docs.docker.com/docker-hub/download-rate-limit/'
                # Generic failure
                msg = err or out or f'exit code {res.returncode}'
                return False, f'Registry manifest inspect failed: {msg[:400]}'
        finally:
            # If we logged in for the check, attempt to logout to avoid leaving credentials in docker config
            if logged_in and login_cmd:
                try:
                    subprocess.run(["docker", "logout", user_host], capture_output=True, text=True, timeout=10)
                except Exception:
                    pass

    except subprocess.TimeoutExpired:
        return False, 'Timeout while checking registry URL'
    except Exception as e:
        return False, f'Error while checking registry URL: {e}'

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
                    if not v:
                        continue
                    if ('_HOSTDIR_' in k) or k.endswith('_HOSTDIR') or k.endswith('_HOSTDIRS') or ('HOSTDIR' in k):
                        try:
                            # Normalize path: expand env vars, user, and make absolute relative to current cwd
                            resolved = os.path.expanduser(os.path.expandvars(v))
                            if not os.path.isabs(resolved):
                                resolved = os.path.abspath(resolved)
                            if os.path.isdir(resolved):
                                info(f"Removing host data dir: {resolved}")
                                shutil.rmtree(resolved, ignore_errors=True)
                            else:
                                info(f"Host data dir not present (skipping): {resolved}")
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
        if var.startswith('COMPINIT_'):
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
    
    # Read control variable from environment (canonical name only)
    continue_on_error = os.environ.get('COMPINIT_IMAGE_CHECK_CONTINUE_ON_ERROR', '0') == '1'
    
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
                        warn(msg + " [continuing due to COMPINIT_IMAGE_CHECK_CONTINUE_ON_ERROR=1]")
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

def wait_for_services_health(compose_file: str, timeout: int = 300, interval: int = 5) -> bool:
    """
    Poll container health status until all are healthy or timeout.
    
    Args:
        compose_file: Path to docker-compose.yml
        timeout: Maximum seconds to wait
        interval: Seconds between checks
        
    Returns:
        True if all services became healthy, False otherwise
    """
    import time
    
    info(f"Waiting for services to become healthy (timeout: {timeout}s)...")
    start_time = time.time()
    
    while True:
        elapsed = time.time() - start_time
        if elapsed > timeout:
            warn(f"Timeout waiting for services to become healthy after {timeout}s")
            return False
        
        try:
            # Get container status as JSON
            result = subprocess.run(
                ['docker', 'compose', '-f', compose_file, 'ps', '--format', 'json'],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if result.returncode != 0:
                warn(f"Failed to query container status: {result.stderr}")
                time.sleep(interval)
                continue
            
            if not result.stdout.strip():
                warn("No containers found")
                time.sleep(interval)
                continue
            
            # Parse container statuses
            all_healthy = True
            any_unhealthy = False
            containers_info = []
            
            for line in result.stdout.strip().split('\n'):
                if not line.strip():
                    continue
                    
                try:
                    container = json.loads(line)
                    name = container.get('Service', 'unknown')
                    state = container.get('State', 'unknown')
                    health = container.get('Health', '')
                    
                    containers_info.append((name, state, health))
                    
                    # Check health status
                    if health:
                        if 'healthy' in health.lower():
                            continue  # This container is healthy
                        elif 'unhealthy' in health.lower():
                            warn(f"Container {name} is unhealthy")
                            any_unhealthy = True
                            all_healthy = False
                        elif 'starting' in health.lower():
                            all_healthy = False  # Still starting
                        else:
                            warn(f"Container {name} has unknown health status: {health}")
                            all_healthy = False
                    else:
                        # No health check defined - check if running
                        if state == 'running':
                            continue  # Treat as healthy
                        elif state == 'exited':
                            warn(f"Container {name} has exited")
                            any_unhealthy = True
                            all_healthy = False
                        else:
                            all_healthy = False  # Still starting or unknown
                            
                except json.JSONDecodeError:
                    warn(f"Failed to parse container status: {line[:100]}")
                    all_healthy = False
                    continue
            
            # Report status
            if all_healthy:
                info("All services are healthy!")
                for name, state, health in containers_info:
                    status = health if health else state
                    info(f"  ✓ {name}: {status}")
                return True
            
            if any_unhealthy:
                error_msg = "Some services are unhealthy:"
                for name, state, health in containers_info:
                    status = health if health else state
                    if 'unhealthy' in status.lower() or state == 'exited':
                        error_msg += f"\n  ✗ {name}: {status}"
                warn(error_msg)
                return False
            
            # Still waiting for services to start
            info(f"Waiting... ({int(elapsed)}s elapsed)")
            for name, state, health in containers_info:
                status = health if health else state
                info(f"  - {name}: {status}")
            
        except subprocess.TimeoutExpired:
            warn("Docker ps command timed out")
        except Exception as e:
            warn(f"Error checking container health: {e}")
        
        time.sleep(interval)

def start_compose(compose_file: str, mode: str, expanded_env: Dict[str, str], env_file: str) -> None:
    """
    Start Docker Compose services with the specified mode.
    
    Args:
        compose_file: Path to the docker-compose.yml file
        mode: Start mode - one of: detached, abort-on-failure, foreground
        expanded_env: Environment variables with expansions applied
        env_file: Path to the environment file for persistence
        
    Raises:
        SystemExit: If invalid mode specified or docker compose fails
        
    Modes:
        - detached: Start containers in background and return immediately
        - abort-on-failure: Start containers in background, wait for health, exit on success/failure
        - foreground: Start containers in foreground (blocks until Ctrl+C)
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
            run(f"docker compose -f {compose_file} up -d", env=expanded_env)
            
        elif normalized_mode == 'abort-on-failure':
            info("Starting containers in detached mode with health monitoring...")
            run(f"docker compose -f {compose_file} up -d", env=expanded_env)
            
            # Wait for services to become healthy
            success = wait_for_services_health(compose_file, timeout=300, interval=5)
            
            if success:
                info("All services started successfully and are healthy")
                # Post-compose hook execution is handled by main() after start_compose returns
                return
            else:
                error("Service startup failed - not all services became healthy")
                
        elif normalized_mode == 'foreground':
            info("Starting containers in foreground")
            run(f"docker compose -f {compose_file} up", env=expanded_env)
            
    except Exception as e:
        error(f"Failed to start Docker Compose services: {e}")

def main() -> None:
    """Greenfield TOML-only orchestration entrypoint.

    Updated lifecycle:
      1. Parse CLI args (supports --refresh-active, --dry-run, --print-context)
      2. Load active TOML or rebuild from sample + global overlays (on first run or refresh)
      3. Resolve secret directives (ASK_VAULT, GEN, GEN_EPHEMERAL, ASK_EXTERNAL, ASK_VAULT_ONCE, DERIVE) [PLACEHOLDER]
      4. Apply dependency graph from [project.dependencies] before current project [PLACEHOLDER]
      5. Inject [global.env] variables into runtime env context [PLACEHOLDER]
      6. Optional resets (containers|named-volumes|hostdirs|secrets)
      7. Render Jinja templates (compose + configs) [FUTURE INTEGRATION]
      8. Start docker compose unless --dry-run
      9. Execute pre/post hooks (class-based), persist metadata into active TOML only (no .env)

    Legacy .env* processing has been removed (greenfield). Any attempt to use
    --env-legacy or legacy skeleton generation aborts with an error.
    """
    import argparse
    # Ensure runtime dependencies are present (PyYAML etc.)
    import yaml
    
    # Parse command line arguments
    parser = argparse.ArgumentParser(
        description="Python replacement for 'docker compose up' or custom start scripts",
        epilog="""Short help: see --notes for extended usage and notes.""",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
        # The detailed usage/notes block is centralized in usage_notes() below.
        # TODO: KEEP THIS NOTEs BLOCK IN SYNC with any manual docs or README when
        # editing this file. Search for 'KEEP IN SYNC' markers before changing.
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
        help=f"Environment file name (default: {DEFAULT_ENV_ACTIVE_FILE})", 
        default=DEFAULT_ENV_ACTIVE_FILE,
        metavar='ENV_FILE'
    )
    parser.add_argument('--env-legacy', action='store_true', help='(Removed) Legacy .env mode is not supported')
    parser.add_argument('--notes', action='store_true', help='Print extended usage notes and exit')
    parser.add_argument('-y', '--yes', action='store_true', help='Assume yes / non-interactive: do not prompt after generating .env')
    parser.add_argument('--external-strict', action='store_true', help='Treat missing EXTERNAL tokens as fatal in non-interactive runs (equivalent to COMPINIT_STRICT_EXTERNAL=1)')
    parser.add_argument('--init-skel-toml', action='store_true', help='Generate a skeleton .env.sample.toml file and exit')
    # Removed legacy .env skeleton support (greenfield)
    parser.add_argument('--refresh-active', action='store_true', help='Rebuild compose.config.active.toml from sample + overlays (discarding existing active)')
    parser.add_argument('--dry-run', action='store_true', help='Resolve config & secrets, output redacted context, skip rendering & compose start')
    parser.add_argument('--print-context', action='store_true', help='Emit redacted merged context JSON then continue normal execution')
    parser.add_argument('--migrate-workspace-envs', action='store_true', help='Scan workspace directory and migrate any legacy .env.sample files to TOML (dry-run unless -y provided)')
    
    try:
        args = parser.parse_args()
    except SystemExit:
        # argparse already printed help/error message
        sys.exit(1)

    if getattr(args, 'notes', False):
        print(usage_notes())
        sys.exit(0)
    
    if getattr(args, 'init_skel_toml', False):
        generate_skeleton_toml(DEFAULT_TOML_SAMPLE_FILE)
        sys.exit(0)
    
    if getattr(args, 'env_legacy', False):
        error('Legacy .env mode is removed. Use TOML configuration only.')

    if getattr(args, 'migrate_workspace_envs', False):
        # Walk the working directory and find .env.sample files to migrate
        def _should_ignore_dir(d: str) -> bool:
            ignore = ('.git', '.venv', 'venv', 'node_modules', '__pycache__')
            return any(part in d for part in ignore)

        projects = []
        for root, dirs, files in os.walk(args.dir):
            # skip ignored dirs
            if _should_ignore_dir(root):
                continue
            if '.env.sample' in files or '.env' in files:
                projects.append(root)

        if not projects:
            info("No legacy env files found to migrate in workspace")
            sys.exit(0)

        info(f"Found {len(projects)} projects with legacy env files to migrate")
        for p in projects:
            sample = os.path.join(p, '.env.sample') if os.path.isfile(os.path.join(p, '.env.sample')) else os.path.join(p, '.env')
            out = os.path.join(p, DEFAULT_TOML_SAMPLE_FILE)
            info(f"Would migrate: {sample} -> {out}")
            if getattr(args, 'yes', False):
                try:
                    migrate_env_sample_to_toml(sample, out)
                    info(f"Migrated {sample} -> {out}")
                    try:
                        os.remove(sample)
                        info(f"Removed legacy sample: {sample}")
                    except Exception:
                        warn(f"Failed to remove legacy sample: {sample}")
                except Exception as e:
                    warn(f"Failed to migrate {sample}: {e}")
        if not getattr(args, 'yes', False):
            warn("Dry-run complete. Re-run with -y to perform migration and delete legacy files.")
        sys.exit(0)

    # Propagate CLI flag to environment variable so existing logic can use it
    if getattr(args, 'external_strict', False):
        os.environ['COMPINIT_STRICT_EXTERNAL'] = '1'

    # Global strict mode: when enabled, flip a small set of behaviors to stricter handling.
    # This keeps default behavior permissive for developers but enables stricter checks in CI/production.
    if os.environ.get('COMPINIT_STRICT_MODE', '').lower() in ('1', 'true', 'yes'):
        info("COMPINIT_STRICT_MODE enabled: enabling stricter checks for EXTERNAL tokens, certs, image/registry checks, and network timeouts")
        # Set canonical strict flags only (no legacy fallbacks)
        os.environ.setdefault('COMPINIT_STRICT_EXTERNAL', '1')
        os.environ.setdefault('COMPINIT_STRICT_CERTS', '1')
        # If a registry URL is provided, enable image checking and treat failures strictly.
        if os.environ.get('COMPINIT_MYREGISTRY_URL'):
            os.environ.setdefault('COMPINIT_CHECK_IMAGE_ENABLED', 'true')
            os.environ.setdefault('COMPINIT_STRICT_IMAGE', '1')
        # Treat network/registry timeouts as strict failures
        os.environ.setdefault('COMPINIT_STRICT_NETWORK', '1')
        # Expansion failures should be strict under strict mode
        os.environ.setdefault('COMPINIT_STRICT_EXPANSION', '1')
    
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
    
    # Define file paths - TOML-first policy
    toml_file = DEFAULT_TOML_ACTIVE_FILE
    sample_file = DEFAULT_TOML_SAMPLE_FILE
    env_file = None  # .env persistence disabled in greenfield mode
    compose_file = args.file
    
    # Determine configuration format
    use_toml = False
    config_file = None
    if os.path.isfile(toml_file) and not getattr(args, 'refresh_active', False):
        use_toml = True
        config_file = toml_file
        info(f"Using existing active TOML: {toml_file}")
    else:
        if not os.path.isfile(sample_file):
            error(f"Sample TOML '{sample_file}' not found; cannot initialize active configuration")
        info("(Re)generating active TOML from sample (plus overlays if present)")
        try:
            with open(sample_file, 'rb') as fin, open(toml_file, 'wb') as fout:
                fout.write(fin.read())
        except Exception as e:
            error(f"Failed to create active TOML from sample: {e}")
        use_toml = True
        config_file = toml_file
    
    # Validate required files exist
    if not os.path.isfile(compose_file):
        warn(f"Compose file '{compose_file}' not found (may be rendered later); continuing")
    
    # First run: generate .env from configuration file
    # If a global repo-level TOML exists, merge it with the project TOML and any local per-project overrides
    merged_toml_tmp = None
    merged_toml_tmp = None
    project_config_obj = None
    if use_toml:
        merged_toml_tmp = DEFAULT_TOML_ACTIVE_FILE + '.merged.tmp'
        _merge_global_project_local_toml(DEFAULT_GLOBAL_TOML_FILE, config_file, None, merged_toml_tmp)
        try:
            project_config_obj = parse_toml_config(merged_toml_tmp if os.path.isfile(merged_toml_tmp) else config_file)
        except Exception as e:
            warn(f"Failed to parse merged TOML for project metadata: {e}")


    # Generate runtime environment variables in-memory (TOML-first policy).
    env_vars: Dict[str, str] = {}
    if use_toml:
        cfg_path = merged_toml_tmp if merged_toml_tmp and os.path.isfile(merged_toml_tmp) else config_file
        try:
            config = parse_toml_config(cfg_path)
        except Exception as e:
            error(f"Failed to parse TOML configuration '{cfg_path}': {e}")

        # Validate configuration
        validation_errors = validate_config(config)
        if validation_errors:
            error(f"TOML configuration validation failed:\n  - " + "\n  - ".join(validation_errors))

        info(f"Parsed TOML configuration for project: {config.project_name}")

    # Legacy variable generation retained for now – will be superseded by directive resolver
        generated_values: Dict[str, str] = {}
        local_env = dict(os.environ)

        for name, var_config in config.variables.items():
            try:
                if var_config.source == "deferred":
                    generated_values[name] = ""
                    continue

                if var_config.type == "password" and not var_config.value:
                    info(f"Generating password for {name} (type={var_config.type}, length={var_config.length})")
                    generated_values[name] = gen_pw(var_config.length or 32, var_config.charset)
                elif var_config.type == "token" and not var_config.value:
                    if var_config.source == "external":
                        env_fallback = os.environ.get(name)
                        if env_fallback:
                            info(f"Using provided environment value for external token {name}")
                            generated_values[name] = env_fallback
                        else:
                            strict = strict_flag(os.environ, 'EXTERNAL')
                            if os.environ.get('COMPINIT_ASSUME_YES', '').lower() in ('1', 'true', 'yes') and strict:
                                error(f"External token {name} requires input and COMPINIT_STRICT_EXTERNAL=1 enforces strict behavior")
                            if os.environ.get('COMPINIT_ASSUME_YES', '').lower() in ('1', 'true', 'yes'):
                                warn(f"{name} is marked external but no value provided; continuing with empty value")
                                generated_values[name] = ''
                            else:
                                desc = var_config.description or f"External {var_config.type}"
                                warn(f"{name} ({desc}) requires a value. Please enter:")
                                try:
                                    generated_values[name] = input(f"{name}=").strip()
                                except (EOFError, KeyboardInterrupt):
                                    error(f"User input required for {name} but not provided")
                    elif var_config.source == "internal":
                        info(f"Generating internal token for {name} (length={var_config.length})")
                        generated_values[name] = gen_pw(var_config.length or 64, var_config.charset)
                    else:
                        generated_values[name] = var_config.value or ""
                elif var_config.value is not None:
                    try:
                        expanded = expand_vars(var_config.value, local_env)
                        generated_values[name] = expanded
                        local_env[name] = expanded
                    except Exception:
                        generated_values[name] = var_config.value
                        local_env[name] = var_config.value
                else:
                    generated_values[name] = ""
            except Exception as e:
                warn(f"Error generating value for variable {name}: {e}")

        # Convert config to env dict
        env_vars = config_to_env_dict(config, generated_values)
        # Load raw TOML to access sections not modeled in ProjectConfig yet (e.g. [global.env], [project.dependencies])
        raw_toml = _load_toml_dict(config_file)
        global_env_section = (
            raw_toml.get('global', {}).get('env', {})
            if isinstance(raw_toml.get('global'), dict) else {}
        )
        for gk, gv in global_env_section.items():
            # Do not override explicit service var definitions
            env_vars.setdefault(gk, str(gv))

        # Dependency resolution (simple required pass). Each key under [project.dependencies]
        # whose value is 'required' is treated as a relative directory path.
        proj_section = raw_toml.get('project', {}) if isinstance(raw_toml.get('project'), dict) else {}
        deps_section = raw_toml.get('project', {}).get('dependencies', {}) if isinstance(proj_section, dict) else {}
        if isinstance(deps_section, dict):
            for dep_name, dep_mode in deps_section.items():
                if str(dep_mode).lower() == 'required':
                    dep_path = os.path.normpath(os.path.join(os.getcwd(), '..', dep_name)) if not os.path.isdir(dep_name) else dep_name
                    if os.path.isdir(dep_path):
                        info(f"Starting required dependency project: {dep_name} -> {dep_path}")
                        try:
                            run(f"python3 {os.path.abspath(__file__)} -d {dep_path} --dry-run", check=True, suppress_output=True)
                            run(f"python3 {os.path.abspath(__file__)} -d {dep_path}", check=True)
                        except Exception as e:
                            error(f"Failed to start dependency {dep_name} at {dep_path}: {e}")
                    else:
                        warn(f"Declared dependency '{dep_name}' not found at path {dep_path}")
        # Secret directive resolution (greenfield placeholder with directive persistence)
        directive_prefixes = ("ASK_VAULT:", "GEN:", "GEN_EPHEMERAL", "ASK_EXTERNAL:", "ASK_VAULT_ONCE:", "DERIVE:")
        resolved_secrets: Dict[str, str] = {}           # plaintext resolved (runtime only)
        directive_map: Dict[str, str] = {}              # key -> directive token (persisted)
        secret_categories: Dict[str, str] = {}          # key -> category (managed, generated, once, external, ephemeral, derived)
        redacted = "***REDACTED***"

        def _record_directive(key: str, raw: str, category: str) -> None:
            directive_map[key] = raw
            secret_categories[key] = category

        for env_key, raw_val in list(env_vars.items()):
            if not isinstance(raw_val, str):
                continue
            token = raw_val.strip()
            if not (token.startswith(directive_prefixes) or token == "GEN_EPHEMERAL"):
                continue

            # Classification + simulated resolution
            if token.startswith("GEN:"):
                _record_directive(env_key, token, 'generated')
                resolved = gen_pw(32, 'ALNUM')
                resolved_secrets[env_key] = resolved
                env_vars[env_key] = resolved
            elif token == "GEN_EPHEMERAL":
                _record_directive(env_key, token, 'ephemeral')
                env_vars[env_key] = gen_pw(24, 'ALNUM')
            elif token.startswith("ASK_VAULT_ONCE:"):
                _record_directive(env_key, token, 'generated-once')
                # Placeholder: attempt vault read (simulate miss)
                resolved = gen_pw(40, 'ALNUM')
                resolved_secrets[env_key] = resolved
                env_vars[env_key] = resolved
            elif token.startswith("ASK_VAULT:"):
                _record_directive(env_key, token, 'managed')
                # Placeholder: treat as managed persistent secret – simulate value
                resolved = gen_pw(40, 'ALNUM')
                resolved_secrets[env_key] = resolved
                env_vars[env_key] = resolved
            elif token.startswith("ASK_EXTERNAL:"):
                _record_directive(env_key, token, 'external')
                ext_key = token.split(":",1)[1]
                env_vars[env_key] = os.environ.get(ext_key, '')
            elif token.startswith("DERIVE:"):
                _record_directive(env_key, token, 'derived')
                try:
                    _tag, algo, source = token.split(':',2)
                    src_val = env_vars.get(source)
                    if src_val:
                        import hashlib
                        h = hashlib.sha256(src_val.encode()).hexdigest() if algo.lower()=="sha256" else hashlib.md5(src_val.encode()).hexdigest()  # nosec - placeholder
                        env_vars[env_key] = h
                    else:
                        env_vars[env_key] = ''
                except Exception:
                    env_vars[env_key] = ''

        # If a secrets reset was requested include secrets token
        reset_spec = os.environ.get('COMPINIT_RESET_BEFORE_START', '')
        reset_tokens = [seg.strip().lower() for seg in reset_spec.split(',') if seg.strip()]
        secrets_reset = 'secrets' in reset_tokens
        strict_reset = strict_flag(os.environ, 'RESET')  # COMPINIT_STRICT_RESET

        if secrets_reset:
            info("Secrets reset requested: purging eligible Vault-backed secrets (simulated)")
            for key, category in list(secret_categories.items()):
                if category in ('generated', 'generated-once') or (strict_reset and category == 'managed'):
                    _purge_secret_stub(key)
                    # restore directive token (ensures regeneration on next run)
                    env_vars[key] = directive_map.get(key, env_vars[key])
            # signal to hooks
            os.environ['COMPINIT_SECRETS_PURGED'] = '1'

        # Persist directive metadata & secret hash state (never plaintext)
        if directive_map:
            state_hashes = {}
            for k, cat in secret_categories.items():
                if k in resolved_secrets:
                    try:
                        state_hashes[k] = _secret_hash(resolved_secrets[k])
                    except Exception:
                        continue
            try:
                _append_or_replace_section(config_file, 'secrets.directives', directive_map)
                if state_hashes:
                    _append_or_replace_section(config_file, 'secrets.state', state_hashes)
            except Exception as e:
                warn(f"Unable to persist secret directive metadata: {e}")

        # Redacted context for dry-run / print (plaintext never printed)
        redacted_context = {}
        for kk, vv in env_vars.items():
            if kk in resolved_secrets:
                redacted_context[kk] = redacted
            else:
                redacted_context[kk] = vv
        if getattr(args, 'print_context', False):
            try:
                import json
                print(json.dumps(redacted_context, indent=2, sort_keys=True))
            except Exception:
                warn("Failed to emit JSON context")

    else:
        error("TOML processing unexpectedly disabled; this state should be unreachable in greenfield mode")

    if getattr(args, 'dry_run', False):
        # Minimal redacted context print (placeholder)
        info("Dry run complete: secrets redacted. No compose start performed.")
        return

    # Optionally perform runtime expansion of $VAR and $(cmd) depending on setting
    expansion_enabled = os.environ.get('COMPINIT_ENABLE_ENV_EXPANSION', '').lower() in ('1', 'true', 'yes')
    if expansion_enabled:
        expanded_vars: Dict[str, str] = {}
        for key, value in env_vars.items():
            try:
                expanded_value = expand_vars(value, env_vars)
            except Exception as e:
                warn(f"Error expanding variable {key}: {e}")
                expanded_value = value
            expanded_vars[key] = expanded_value
            if expanded_value != value:
                info(f"Expanded {key} -> {expanded_value}")
        env_vars = expanded_vars
    else:
        info("Runtime expansion disabled: keeping values literal in memory")

    # Update current process environment so subsequent operations see the values
    os.environ.update(env_vars)

    # Process dependencies before starting this project
    dependencies_str = env_vars.get('COMPINIT_DEPENDENCIES', '').strip()
    if dependencies_str:
        step(f"Resolving dependencies: {dependencies_str}")
        try:
            dependency_paths = resolve_dependencies(env_vars, os.getcwd())
            info(f"Dependency resolution order: {' -> '.join([os.path.basename(p) for p in dependency_paths])}")
            start_dependencies(dependency_paths, os.getcwd())
        except Exception as e:
            error(f"Failed to process dependencies: {e}")
        
    # Perform any configured reset actions before creating volumes/directories
    reset_flags = env_vars.get('COMPINIT_RESET_BEFORE_START', 'none')
    if reset_state(env_vars, reset_flags, env_file):
        python = sys.executable
        os.execv(python, [python] + sys.argv)

    step("Creating required directories/volumes with permissions for containers")
    create_hostdirs_from_env(env_vars)
    step("Starting containers with Docker Compose")

    public_key = env_vars.get('PUBLIC_TLS_KEY_PEM')
    public_crt = env_vars.get('PUBLIC_TLS_CRT_PEM')
    certs_strict = strict_flag(os.environ, 'CERTS')
    if public_key and (not os.path.isfile(public_key) or not os.access(public_key, os.R_OK)):
        (error if certs_strict else warn)(f"PUBLIC TLS key file not readable: {public_key}")
    if public_crt and (not os.path.isfile(public_crt) or not os.access(public_crt, os.R_OK)):
        (error if certs_strict else warn)(f"PUBLIC TLS crt file not readable: {public_crt}")

    pre_meta = run_hooks('PRE_COMPOSE', env_vars, project_config=project_config_obj)
    if pre_meta:
        info(f"Applied {len(pre_meta)} meta changes from pre-compose hooks")
        # Apply values in-memory and process persistence per-variable
        to_env = {}
        project_updates = {}
        local_updates = {}
        env_updates = {}
        sensitive_report = []
        for name, md in pre_meta.items():
            val = md.get('value')
            persist = (md.get('persist') or 'auto').lower()
            sensitive = bool(md.get('sensitive', False))
            os.environ[name] = '' if val is None else str(val)
            env_vars[name] = '' if val is None else str(val)
            to_env[name] = env_vars[name]
            if persist == 'none':
                if sensitive:
                    sensitive_report.append(name)
                continue
            if persist == 'env':
                env_updates[name] = env_vars[name]
                continue
            if persist == 'local':
                local_updates[name] = env_vars[name]
                continue
            if persist == 'project':
                project_updates[name] = env_vars[name]
                continue
            if persist in ('auto', ''):
                if sensitive:
                    sensitive_report.append(name)
                else:
                    if os.path.isfile(config_file):
                        project_updates[name] = env_vars[name]
                    else:
                        local_updates[name] = env_vars[name]

        try:
            merged_project_updates = {}
            merged_project_updates.update(project_updates)
            merged_project_updates.update(local_updates)
            if sensitive_report:
                merged_project_updates.update({k: env_vars[k] for k in sensitive_report})
            if merged_project_updates:
                target_toml = config_file if os.path.isfile(config_file) else DEFAULT_TOML_ACTIVE_FILE
                _write_local_toml_variables(target_toml, merged_project_updates)
            if env_updates or to_env:
                info(f"Applied {len(env_updates) + len(to_env)} runtime-only hook variables in-memory (not persisted to disk)")
            if sensitive_report:
                info(f"Sensitive hook variables processed and persisted to active TOML: {', '.join(sensitive_report)}")
        except Exception as e:
            warn(f"Unable to persist pre-compose hook variables: {e}")
        compose_mode = env_vars.get('COMPINIT_COMPOSE_START_MODE', 'abort-on-failure')
        info(f"COMPINIT_COMPOSE_START_MODE set to: {compose_mode}")
        
        # Validate compose config and check env var usage
        config_yaml = check_compose_yaml(compose_file, env_vars, env_file)
        
        # Check image availability before attempting to start (toggleable)
        check_images_enabled = env_vars.get('COMPINIT_IMAGE_CHECK_ENABLED', 'false').lower() in ('1', 'true', 'yes')
        if not check_images_enabled:
            info("Image availability check is disabled (COMPINIT_IMAGE_CHECK_ENABLED=false). Skipping image checks.")
            images = []
        else:
            # Optionally verify COMPINIT_MYREGISTRY_URL reachability before checking images
            myreg = env_vars.get('COMPINIT_MYREGISTRY_URL')
            ok, msg = check_myregistry(myreg, env_vars)
            if not ok:
                warn(f"COMPINIT_MYREGISTRY_URL check failed: {msg}")
            else:
                info(f"COMPINIT_MYREGISTRY_URL check: {msg}")
            step(f"Checking image availability for all referenced images in {compose_file}...")
            images = get_images_from_compose(compose_file, env_vars)
            if images:
                info(f"Found {len(images)} images to check: {', '.join(images)}")
                available, missing = check_images_parallel(images)
                check_for_image_updates(images)
                if missing:
                    error(f"Some images are missing or inaccessible: {', '.join(missing)}\n"
                          f"Please ensure Docker is running and images are available.",
                          show_stacktrace=False)
                info(f"All {len(available)} required images are available")
            else:
                warn("No images found in docker-compose configuration")
        
    # Start Docker Compose services, passing runtime env_vars (in-memory)
    start_compose(compose_file, compose_mode, env_vars, env_file)

    # Run post-compose hooks (class-only) and persist returned vars
    post_meta = run_hooks('POST_COMPOSE', env_vars, project_config=project_config_obj)
    if post_meta:
        info(f"Applied {len(post_meta)} meta changes from post-compose hooks")
        # Apply same per-variable persistence model as pre-hooks
        to_env = {}
        project_updates = {}
        local_updates = {}
        env_updates = {}
        sensitive_report = []
        for name, md in post_meta.items():
            val = md.get('value')
            persist = (md.get('persist') or 'auto').lower()
            sensitive = bool(md.get('sensitive', False))
            os.environ[name] = '' if val is None else str(val)
            env_vars[name] = '' if val is None else str(val)
            to_env[name] = env_vars[name]
            if persist == 'none':
                if sensitive:
                    sensitive_report.append(name)
                continue
            if persist == 'env':
                env_updates[name] = env_vars[name]
                continue
            if persist == 'local':
                local_updates[name] = env_vars[name]
                continue
            if persist == 'project':
                project_updates[name] = env_vars[name]
                continue
            # auto
            if sensitive:
                sensitive_report.append(name)
            else:
                # New policy: always persist auto non-sensitive returns into project active TOML when project TOML exists
                if os.path.isfile(config_file):
                    project_updates[name] = env_vars[name]
                else:
                    local_updates[name] = env_vars[name]

        try:
            # Merge project/local updates and sensitive values and persist to active TOML
            merged_project_updates = {}
            merged_project_updates.update(project_updates)
            merged_project_updates.update(local_updates)
            if sensitive_report:
                merged_project_updates.update({k: env_vars[k] for k in sensitive_report})
            if merged_project_updates:
                target_toml = config_file if os.path.isfile(config_file) else DEFAULT_TOML_ACTIVE_FILE
                _write_local_toml_variables(target_toml, merged_project_updates)

            # Env-only updates remain in-memory and are not written to disk
            if env_updates or to_env:
                info(f"Applied {len(env_updates) + len(to_env)} runtime-only post-hook variables in-memory (not persisted to a .env file)")

            if sensitive_report:
                info(f"Sensitive hook variables processed and persisted to active TOML: {', '.join(sensitive_report)}")
        except Exception as e:
            warn(f"Unable to persist post-compose hook variables: {e}")

    info("Infrastructure initialization completed successfully!")
    return

if __name__ == "__main__":
    main()