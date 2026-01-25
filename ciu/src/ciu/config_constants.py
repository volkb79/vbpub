#!/usr/bin/env python3
"""
Configuration filename constants for DST-DNS project.

CRITICAL: This is the SINGLE SOURCE OF TRUTH for all config filenames.
All scripts MUST import from this file instead of using hardcoded strings.

Naming Convention (Greenfield Standard):
- *.defaults.toml.j2 = Template defaults (committed)
- *.toml.j2 = Template overrides (gitignored)
- *.toml = Rendered runtime config (gitignored)
"""

# ============================================================================
# TOML Configuration Filenames (CANONICAL - DO NOT HARDCODE)
# ============================================================================

# Global configuration (repository root)
GLOBAL_CONFIG_DEFAULTS = 'ciu-global.defaults.toml.j2'
GLOBAL_CONFIG_OVERRIDES = 'ciu-global.toml.j2'
GLOBAL_CONFIG_RENDERED = 'ciu-global.toml'

# Stack configuration (per-service directory: applications/*, infra/*, infra-global/*, tools/*)
STACK_CONFIG_DEFAULTS = 'ciu.defaults.toml.j2'
STACK_CONFIG_OVERRIDES = 'ciu.toml.j2'
STACK_CONFIG_RENDERED = 'ciu.toml'

# Service configuration (Python apps using config_loader)
SERVICE_CONFIG_DEFAULTS = 'service.defaults.toml'
SERVICE_CONFIG_ACTIVE = 'service.active.toml'

# Standalone variants (for special deployments like registry-lightweight)
STACK_CONFIG_STANDALONE = 'ciu.standalone.toml'

# Docker Compose generated files
DOCKER_COMPOSE_TEMPLATE = 'docker-compose.yml.j2'
DOCKER_COMPOSE_OUTPUT = 'docker-compose.yml'

# ============================================================================
# Configuration Search Patterns (for glob/find operations)
# ============================================================================

# Find all stack configs
STACK_SEARCH_PATTERNS = [
    f'applications/*/{STACK_CONFIG_DEFAULTS}',
    f'infra/*/{STACK_CONFIG_DEFAULTS}',
    f'infra-global/*/{STACK_CONFIG_DEFAULTS}',
    f'tools/*/{STACK_CONFIG_DEFAULTS}',
]

# Find all service configs
SERVICE_SEARCH_PATTERNS = [
    f'applications/*/src/*/{SERVICE_CONFIG_DEFAULTS}',
    f'**/{SERVICE_CONFIG_DEFAULTS}',
]

# ============================================================================
# Helper Functions
# ============================================================================


def get_rendered_config_name(defaults_name: str) -> str:
    """
    Get the corresponding rendered filename for a defaults template.

    Args:
        defaults_name: The .defaults.toml.j2 filename

    Returns:
        The corresponding .toml filename

    Examples:
        >>> get_rendered_config_name('ciu.defaults.toml.j2')
        'ciu.toml'
        >>> get_rendered_config_name('ciu-global.defaults.toml.j2')
        'ciu-global.toml'
    """
    return defaults_name.replace('.defaults.toml.j2', '.toml')


def get_defaults_template_name(rendered_name: str) -> str:
    """
    Get the corresponding defaults template filename for a rendered TOML.

    Args:
        rendered_name: The rendered .toml filename

    Returns:
        The corresponding .defaults.toml.j2 filename

    Examples:
        >>> get_defaults_template_name('ciu.toml')
        'ciu.defaults.toml.j2'
        >>> get_defaults_template_name('ciu-global.toml')
        'ciu-global.defaults.toml.j2'
    """
    return rendered_name.replace('.toml', '.defaults.toml.j2')


def is_config_file(filename: str) -> bool:
    """
    Check if a filename is a recognized configuration file.
    
    Args:
        filename: The filename to check
        
    Returns:
        True if the filename matches a known config pattern
    """
    config_files = {
        GLOBAL_CONFIG_DEFAULTS,
        GLOBAL_CONFIG_OVERRIDES,
        GLOBAL_CONFIG_RENDERED,
        STACK_CONFIG_DEFAULTS,
        STACK_CONFIG_OVERRIDES,
        STACK_CONFIG_RENDERED,
        SERVICE_CONFIG_DEFAULTS,
        SERVICE_CONFIG_ACTIVE,
        STACK_CONFIG_STANDALONE,
    }
    return filename in config_files


if __name__ == '__main__':
    # Self-test
    print("=== Config Constants ===")
    print(f"Global defaults: {GLOBAL_CONFIG_DEFAULTS}")
    print(f"Global overrides: {GLOBAL_CONFIG_OVERRIDES}")
    print(f"Global rendered: {GLOBAL_CONFIG_RENDERED}")
    print(f"Stack defaults:  {STACK_CONFIG_DEFAULTS}")
    print(f"Stack overrides: {STACK_CONFIG_OVERRIDES}")
    print(f"Stack rendered:  {STACK_CONFIG_RENDERED}")
    print(f"Service defaults: {SERVICE_CONFIG_DEFAULTS}")
    print(f"Service active:   {SERVICE_CONFIG_ACTIVE}")
    print()
    print("=== Helper Tests ===")
    print(f"get_rendered_config_name('{STACK_CONFIG_DEFAULTS}') = {get_rendered_config_name(STACK_CONFIG_DEFAULTS)}")
    print(f"get_defaults_template_name('{STACK_CONFIG_RENDERED}') = {get_defaults_template_name(STACK_CONFIG_RENDERED)}")
    print(f"is_config_file('{GLOBAL_CONFIG_DEFAULTS}') = {is_config_file(GLOBAL_CONFIG_DEFAULTS)}")
    print(f"is_config_file('random.toml') = {is_config_file('random.toml')}")
