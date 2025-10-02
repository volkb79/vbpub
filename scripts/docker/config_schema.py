#!/usr/bin/env python3
"""
TOML Configuration Schema for compose-init-up.py

This module defines the schema and validation for .env.toml configuration files
that replace the old .env.sample format with better structure and metadata.
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Union, Any, Literal
import os
import re

# Type definitions
VariableType = Literal["string", "password", "token", "number", "boolean", "path"]
Charset = Literal["alnum", "hex", "alpha", "numeric"]
Source = Literal["internal", "external", "deferred", "env", "hook"]

@dataclass
class VariableConfig:
    """Configuration for a single environment variable."""
    value: Optional[str] = None
    type: VariableType = "string"
    charset: Charset = "alnum"
    length: Optional[int] = None
    source: Source = "internal"
    deferred: bool = False
    hook: Optional[str] = None
    required: bool = True
    description: Optional[str] = None
    validation_regex: Optional[str] = None
    
    def __post_init__(self):
        """Validate configuration after initialization."""
        if self.deferred and self.source != "deferred":
            self.source = "deferred"
        
        if self.hook and self.source not in ["hook", "deferred"]:
            self.source = "hook"
        
        # Set default lengths for password/token types
        if self.type in ["password", "token"] and self.length is None:
            self.length = 32 if self.type == "password" else 64


@dataclass
class HookConfig:
    """Configuration for pre/post compose hooks."""
    script: str
    description: Optional[str] = None
    env_exports: List[str] = field(default_factory=list)  # Variables this hook will set
    required: bool = True


@dataclass
class ProjectConfig:
    """Complete project configuration from .env.toml."""
    # Metadata
    project_name: str
    env_tag: str = "dev"
    label_prefix: Optional[str] = None
    
    # Variables
    variables: Dict[str, VariableConfig] = field(default_factory=dict)
    
    # Control flow
    compose_start_mode: str = "abort-on-failure"
    reset_before_start: str = "none"
    image_check_enabled: bool = False
    image_check_continue_on_error: bool = False
    
    # Infrastructure
    public_fqdn: Optional[str] = None
    public_tls_key_pem: Optional[str] = None
    public_tls_crt_pem: Optional[str] = None
    
    # Health monitoring
    healthcheck_interval: str = "10s"
    healthcheck_timeout: str = "5s"
    healthcheck_retries: int = 3
    healthcheck_start_period: str = "30s"
    
    # Hooks
    pre_compose_hooks: List[HookConfig] = field(default_factory=list)
    post_compose_hooks: List[HookConfig] = field(default_factory=list)
    
    # Dependencies
    dependencies: List[str] = field(default_factory=list)
    
    # Registry
    registry_url: Optional[str] = None
    
    # User/Group
    uid: Optional[str] = None
    gid: Optional[str] = None
    
    # Additional sections for extensibility
    custom_sections: Dict[str, Any] = field(default_factory=dict)


def parse_toml_config(toml_path: str) -> ProjectConfig:
    """
    Parse a .env.toml file and return a ProjectConfig object.
    
    Args:
        toml_path: Path to the .env.toml file
        
    Returns:
        ProjectConfig object with parsed configuration
        
    Raises:
        FileNotFoundError: If toml_path doesn't exist
        ValueError: If TOML is invalid or required fields are missing
    """
    try:
        import tomllib
    except ImportError:
        # Fallback for Python < 3.11
        try:
            import tomli as tomllib
        except ImportError:
            raise ImportError("TOML support requires Python 3.11+ or 'pip install tomli'")
    
    if not os.path.isfile(toml_path):
        raise FileNotFoundError(f"Configuration file not found: {toml_path}")
    
    with open(toml_path, 'rb') as f:
        data = tomllib.load(f)
    
    # Extract metadata (required)
    metadata = data.get('metadata', {})
    if 'project_name' not in metadata:
        raise ValueError("Missing required field: metadata.project_name")
    
    config = ProjectConfig(
        project_name=metadata['project_name'],
        env_tag=metadata.get('env_tag', 'dev'),
        label_prefix=metadata.get('label_prefix'),
    )
    
    # Parse control flow settings
    control = data.get('control', {})
    config.compose_start_mode = control.get('compose_start_mode', 'abort-on-failure')
    config.reset_before_start = control.get('reset_before_start', 'none')
    config.image_check_enabled = control.get('image_check_enabled', False)
    config.image_check_continue_on_error = control.get('image_check_continue_on_error', False)
    
    # Parse infrastructure settings
    infra = data.get('infrastructure', {})
    config.public_fqdn = infra.get('public_fqdn')
    config.public_tls_key_pem = infra.get('public_tls_key_pem')
    config.public_tls_crt_pem = infra.get('public_tls_crt_pem')
    
    # Parse health monitoring
    health = data.get('health', {})
    config.healthcheck_interval = health.get('interval', '10s')
    config.healthcheck_timeout = health.get('timeout', '5s')
    config.healthcheck_retries = health.get('retries', 3)
    config.healthcheck_start_period = health.get('start_period', '30s')
    
    # Parse variables
    variables = data.get('variables', {})
    for name, var_data in variables.items():
        if isinstance(var_data, str):
            # Simple string value
            config.variables[name] = VariableConfig(value=var_data)
        elif isinstance(var_data, dict):
            # Complex variable configuration
            config.variables[name] = VariableConfig(
                value=var_data.get('value'),
                type=var_data.get('type', 'string'),
                charset=var_data.get('charset', 'alnum'),
                length=var_data.get('length'),
                source=var_data.get('source', 'internal'),
                deferred=var_data.get('deferred', False),
                hook=var_data.get('hook'),
                required=var_data.get('required', True),
                description=var_data.get('description'),
                validation_regex=var_data.get('validation_regex')
            )
        else:
            raise ValueError(f"Invalid variable configuration for {name}: {var_data}")
    
    # Parse hooks
    hooks = data.get('hooks', {})
    
    # Pre-compose hooks
    pre_hooks = hooks.get('pre_compose', [])
    if isinstance(pre_hooks, str):
        pre_hooks = [pre_hooks]
    
    for hook_data in pre_hooks:
        if isinstance(hook_data, str):
            config.pre_compose_hooks.append(HookConfig(script=hook_data))
        elif isinstance(hook_data, dict):
            config.pre_compose_hooks.append(HookConfig(
                script=hook_data['script'],
                description=hook_data.get('description'),
                env_exports=hook_data.get('env_exports', []),
                required=hook_data.get('required', True)
            ))
    
    # Post-compose hooks
    post_hooks = hooks.get('post_compose', [])
    if isinstance(post_hooks, str):
        post_hooks = [post_hooks]
    
    for hook_data in post_hooks:
        if isinstance(hook_data, str):
            config.post_compose_hooks.append(HookConfig(script=hook_data))
        elif isinstance(hook_data, dict):
            config.post_compose_hooks.append(HookConfig(
                script=hook_data['script'],
                description=hook_data.get('description'),
                env_exports=hook_data.get('env_exports', []),
                required=hook_data.get('required', True)
            ))
    
    # Parse dependencies
    deps = data.get('dependencies', {})
    if isinstance(deps, list):
        config.dependencies = deps
    elif isinstance(deps, dict):
        config.dependencies = deps.get('paths', [])
    
    # Parse other settings
    config.registry_url = data.get('registry', {}).get('url')
    
    user_settings = data.get('user', {})
    config.uid = user_settings.get('uid', '$(id -u)')
    config.gid = user_settings.get('gid', '$(id -g)')
    
    # Store any custom sections for extensibility
    known_sections = {'metadata', 'control', 'infrastructure', 'health', 'variables', 'hooks', 'dependencies', 'registry', 'user'}
    for section, content in data.items():
        if section not in known_sections:
            config.custom_sections[section] = content
    
    return config


def config_to_env_dict(config: ProjectConfig, generated_values: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """
    Convert a ProjectConfig to a dictionary suitable for .env file generation.
    
    Args:
        config: ProjectConfig object
        generated_values: Dictionary of already generated values (passwords, tokens)
        
    Returns:
        Dictionary of environment variables
    """
    if generated_values is None:
        generated_values = {}
    
    env = {}
    
    # Control flow variables
    env['COMPINIT_COMPOSE_START_MODE'] = config.compose_start_mode
    env['COMPINIT_RESET_BEFORE_START'] = config.reset_before_start
    env['COMPINIT_CHECK_IMAGE_ENABLED'] = 'true' if config.image_check_enabled else 'false'
    env['COMPINIT_IMAGE_CHECK_CONTINUE_ON_ERROR'] = '1' if config.image_check_continue_on_error else '0'
    
    # Infrastructure
    env['LABEL_PROJECT_NAME'] = config.project_name
    env['LABEL_ENV_TAG'] = config.env_tag
    if config.label_prefix:
        env['LABEL_PREFIX'] = config.label_prefix
    if config.public_fqdn:
        env['PUBLIC_FQDN'] = config.public_fqdn
    if config.public_tls_key_pem:
        env['PUBLIC_TLS_KEY_PEM'] = config.public_tls_key_pem
    if config.public_tls_crt_pem:
        env['PUBLIC_TLS_CRT_PEM'] = config.public_tls_crt_pem
    
    # Health monitoring
    env['HEALTHCHECK_INTERVAL'] = config.healthcheck_interval
    env['HEALTHCHECK_TIMEOUT'] = config.healthcheck_timeout
    env['HEALTHCHECK_RETRIES'] = str(config.healthcheck_retries)
    env['HEALTHCHECK_START_PERIOD'] = config.healthcheck_start_period
    
    # Hooks (convert to comma-separated lists for backward compatibility)
    if config.pre_compose_hooks:
        env['COMPINIT_HOOK_PRE_COMPOSE'] = ','.join(h.script for h in config.pre_compose_hooks)
    if config.post_compose_hooks:
        env['COMPINIT_HOOK_POST_COMPOSE'] = ','.join(h.script for h in config.post_compose_hooks)
    
    # Dependencies
    if config.dependencies:
        env['COMPINIT_DEPENDENCIES'] = ','.join(config.dependencies)
    
    # Registry
    if config.registry_url:
        env['COMPINIT_MYREGISTRY_URL'] = config.registry_url
    
    # User/Group
    if config.uid:
        env['UID'] = config.uid
    if config.gid:
        env['GID'] = config.gid
    
    # Variables
    for name, var_config in config.variables.items():
        if name in generated_values:
            env[name] = generated_values[name]
        elif var_config.value is not None:
            env[name] = var_config.value
        elif var_config.source == "deferred":
            env[name] = ""  # Will be filled by hooks
        else:
            env[name] = ""  # Will be generated or prompted
    
    return env


def validate_config(config: ProjectConfig) -> List[str]:
    """
    Validate a ProjectConfig and return a list of validation errors.
    
    Args:
        config: ProjectConfig to validate
        
    Returns:
        List of validation error messages (empty if valid)
    """
    errors = []
    
    # Validate project name
    if not config.project_name:
        errors.append("project_name is required")
    elif not re.match(r'^[a-zA-Z0-9_-]+$', config.project_name):
        errors.append("project_name must contain only letters, numbers, underscore, and hyphen")
    
    # Validate variables
    for name, var_config in config.variables.items():
        if not re.match(r'^[A-Z][A-Z0-9_]*$', name):
            errors.append(f"Variable name '{name}' must be uppercase with underscores")
        
        if var_config.validation_regex:
            try:
                re.compile(var_config.validation_regex)
            except re.error as e:
                errors.append(f"Invalid regex for {name}: {e}")
        
        if var_config.type in ["password", "token"] and var_config.length and var_config.length < 8:
            errors.append(f"Password/token {name} length must be at least 8 characters")
    
    # Validate hook scripts exist
    for hook in config.pre_compose_hooks + config.post_compose_hooks:
        if not hook.script.endswith('.py'):
            errors.append(f"Hook script must be a Python file: {hook.script}")
    
    # Validate dependencies
    for dep in config.dependencies:
        if not dep.strip():
            errors.append("Empty dependency path not allowed")
    
    return errors