#!/usr/bin/env python3
"""
Migration script to convert .env.sample files to .env.toml format

This script helps transition from the old .env.sample format with encoded
metadata in variable names to the new structured TOML format.
"""


import os
import sys
import re
from typing import Dict, List, Tuple, Optional
from pathlib import Path

# Try to import canonical file names from compose-init-up.py using importlib
DEFAULT_ENV_SAMPLE_FILE = ".env.sample"
DEFAULT_TOML_ACTIVE_FILE = ".env.toml"
compose_init_path = Path(__file__).parent / "compose-init-up.py"
if compose_init_path.exists():
    import importlib.util
    spec = importlib.util.spec_from_file_location("compose_init", str(compose_init_path))
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
        DEFAULT_ENV_SAMPLE_FILE = getattr(mod, "DEFAULT_ENV_SAMPLE_FILE", DEFAULT_ENV_SAMPLE_FILE)
        DEFAULT_TOML_ACTIVE_FILE = getattr(mod, "DEFAULT_TOML_ACTIVE_FILE", DEFAULT_TOML_ACTIVE_FILE)
    except Exception:
        pass

def parse_legacy_env_sample(sample_path: str) -> Tuple[Dict[str, Dict], List[str], List[str]]:
    """
    Parse a legacy .env.sample file and extract variables with metadata.
    
    Returns:
        Tuple of (variables_dict, comments, control_vars)
    """
    variables = {}
    comments = []
    control_vars = []
    
    with open(sample_path, 'r', encoding='utf-8') as f:
        for line_num, line in enumerate(f, 1):
            orig = line.rstrip('\n')
            
            # Collect comments
            if orig.strip().startswith('#'):
                comments.append(orig.strip())
                continue
            
            if not orig.strip() or '=' not in orig:
                continue
            
            key, val = orig.split('=', 1)
            key = key.strip()
            val = val.strip()
            
            # Remove quotes
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            elif val.startswith("'") and val.endswith("'"):
                val = val[1:-1]
            
            # Detect variable type and metadata from naming convention
            var_info = analyze_variable_name(key, val)
            variables[key] = var_info
            
            # Track control variables separately
            if key.startswith('COMPINIT_') or key.startswith('LABEL_') or key.startswith('PUBLIC_') or key.startswith('HEALTHCHECK_'):
                control_vars.append(key)    
    return variables, comments, control_vars


def analyze_variable_name(name: str, value: str) -> Dict:
    """
    Analyze a variable name and value to extract type and metadata.
    
    This handles the legacy naming conventions like:
    - VAR_PASSWORD -> password type
    - VAR_TOKEN_ALNUM64 -> token with alnum charset, 64 length
    - VAR_TOKEN_HEX32_INTERNAL -> internal token, hex, 32 length
    - VAR_PASSWORD_DEFERED -> deferred password
    """
    info = {
        'value': value,
        'type': 'string',
        'source': 'internal',
        'deferred': False,
        'length': None,
        'charset': 'alnum',
        'description': None
    }
    
    # Check for password variables
    if '_PASSWORD' in name:
        info['type'] = 'password'
        info['length'] = 32  # Default password length
        
        # Check for deferred
        if name.endswith('_DEFERED') or '_PASSWORD_DEFERED' in name:
            info['deferred'] = True
            info['source'] = 'deferred'
        
        # Extract charset and length from descriptors
        # Pattern: NAME_PASSWORD_ALNUM32 or NAME_PASSWORD_HEX64
        desc_match = re.search(r'_PASSWORD_(ALNUM|HEX)(\d+)', name)
        if desc_match:
            info['charset'] = desc_match.group(1).lower()
            info['length'] = int(desc_match.group(2))
    
    # Check for token variables
    elif '_TOKEN' in name:
        info['type'] = 'token'
        info['length'] = 64  # Default token length
        
        # Check source type
        if name.endswith('_INTERNAL') or '_TOKEN_INTERNAL' in name:
            info['source'] = 'internal'
        elif name.endswith('_EXTERNAL') or '_TOKEN_EXTERNAL' in name:
            info['source'] = 'external'
        elif name.endswith('_DEFERED') or '_TOKEN_DEFERED' in name:
            info['deferred'] = True
            info['source'] = 'deferred'
        
        # Extract charset and length from descriptors
        # Pattern: NAME_TOKEN_ALNUM64_INTERNAL or NAME_TOKEN_HEX32
        desc_match = re.search(r'_TOKEN_(ALNUM|HEX)(\d+)', name)
        if desc_match:
            info['charset'] = desc_match.group(1).lower()
            info['length'] = int(desc_match.group(2))
    
    # Detect other types
    elif name.endswith('_PORT') or 'PORT' in name:
        info['type'] = 'number'
    elif name.endswith('_ENABLE') or name.startswith('ENABLE_') or value.lower() in ['true', 'false']:
        info['type'] = 'boolean'
    elif name.endswith('_PATH') or name.endswith('_DIR') or 'HOSTDIR' in name:
        info['type'] = 'path'
    
    # Generate description based on variable name
    if not info['description']:
        # Convert SOME_VAR_NAME to "Some var name"
        desc_parts = name.lower().split('_')
        info['description'] = ' '.join(desc_parts).title()
    
    return info


def generate_toml_config(variables: Dict[str, Dict], comments: List[str], control_vars: List[str], 
                        project_name: str = None) -> str:
    """
    Generate TOML configuration from parsed variables.
    """
    if not project_name:
        # Try to extract from LABEL_PROJECT_NAME or directory name
        project_name = variables.get('LABEL_PROJECT_NAME', {}).get('value') or os.path.basename(os.getcwd())
    
    # Extract control and infrastructure variables
    env_tag = variables.get('LABEL_ENV_TAG', {}).get('value', 'dev')
    label_prefix = variables.get('LABEL_PREFIX', {}).get('value', '')
    
    toml_content = f'''# Migrated from .env.sample to TOML format
# Generated by env-sample-to-toml migration script

[metadata]
project_name = "{project_name}"
env_tag = "{env_tag}"
'''
    
    if label_prefix:
        toml_content += f'label_prefix = "{label_prefix}"\n'
    
    # Control section
    toml_content += '''
[control]
'''
    control_mappings = {
        'COMPINIT_COMPOSE_START_MODE': 'compose_start_mode',
        'COMPINIT_RESET_BEFORE_START': 'reset_before_start',
        'COMPINIT_CHECK_IMAGE_ENABLED': 'image_check_enabled',
        'COMPINIT_IMAGE_CHECK_CONTINUE_ON_ERROR': 'image_check_continue_on_error',
    }
    
    for old_name, new_name in control_mappings.items():
        if old_name in variables:
            val = variables[old_name]['value']
            if new_name.endswith('_enabled') and val.lower() in ['true', 'false']:
                toml_content += f'{new_name} = {val.lower()}\n'
            elif new_name.endswith('_on_error') and val.isdigit():
                toml_content += f'{new_name} = {str(val == "1").lower()}\n'
            else:
                toml_content += f'{new_name} = "{val}"\n'
    
    # Infrastructure section
    toml_content += '''
[infrastructure]
'''
    infra_mappings = {
        'PUBLIC_FQDN': 'public_fqdn',
        'PUBLIC_TLS_KEY_PEM': 'public_tls_key_pem', 
        'PUBLIC_TLS_CRT_PEM': 'public_tls_crt_pem',
    }
    
    for old_name, new_name in infra_mappings.items():
        if old_name in variables:
            val = variables[old_name]['value']
            toml_content += f'{new_name} = "{val}"\n'
    
    # Health monitoring
    toml_content += '''
[health]
'''
    health_mappings = {
        'HEALTHCHECK_INTERVAL': 'interval',
        'HEALTHCHECK_TIMEOUT': 'timeout',
        'HEALTHCHECK_RETRIES': 'retries',
        'HEALTHCHECK_START_PERIOD': 'start_period',
    }
    
    for old_name, new_name in health_mappings.items():
        if old_name in variables:
            val = variables[old_name]['value']
            if new_name == 'retries':
                toml_content += f'{new_name} = {val}\n'
            else:
                toml_content += f'{new_name} = "{val}"\n'
    
    # User section
    toml_content += '''
[user]
'''
    if 'UID' in variables:
        toml_content += f'uid = "{variables["UID"]["value"]}"\n'
    if 'GID' in variables:
        toml_content += f'gid = "{variables["GID"]["value"]}"\n'
    
    # Dependencies and hooks
    deps = variables.get('COMPINIT_DEPENDENCIES', {}).get('value', '')
    pre_hooks = variables.get('COMPINIT_PRECOMPOSEHOOK', {}).get('value') or variables.get('COMPINIT_HOOK_PRE_COMPOSE', {}).get('value', '')
    post_hooks = variables.get('COMPINIT_POSTCOMPOSEHOOK', {}).get('value') or variables.get('COMPINIT_HOOK_POST_COMPOSE', {}).get('value', '')
    
    if deps or pre_hooks or post_hooks:
        if deps:
            dep_list = [f'"{d.strip()}"' for d in deps.replace(':', ',').split(',') if d.strip()]
            toml_content += f'''
[dependencies]
paths = [{', '.join(dep_list)}]
'''
        
        if pre_hooks or post_hooks:
            toml_content += '''
[hooks]
'''
            if pre_hooks:
                hook_list = [f'"{h.strip()}"' for h in pre_hooks.split(',') if h.strip()]
                toml_content += f'pre_compose = [{", ".join(hook_list)}]\n'
            if post_hooks:
                hook_list = [f'"{h.strip()}"' for h in post_hooks.split(',') if h.strip()]
                toml_content += f'post_compose = [{", ".join(hook_list)}]\n'
    
    # Variables section
    toml_content += '''
[variables]
'''
    
    # Skip control variables we already handled
    skip_vars = set(control_vars + ['UID', 'GID'])
    
    for name, info in variables.items():
        if name in skip_vars:
            continue
        
        # Simple string values
        if info['type'] == 'string' and info['source'] == 'internal' and not info['deferred']:
            # Check if value needs quoting
            val = info['value']
            if ' ' in val or '"' in val or "'" in val:
                escaped = val.replace('"', '\\\\"')
                toml_content += f'{name} = "{escaped}"\n'
            else:
                toml_content += f'{name} = "{val}"\n'
        else:
            # Complex variable with metadata
            attrs = []
            
            if info['type'] != 'string':
                attrs.append(f'type = "{info["type"]}"')
            
            if info['value']:
                val = info['value']
                if '"' in val:
                    val = val.replace('"', '\\\\"')
                attrs.append(f'value = "{val}"')
            
            if info['length'] and info['type'] in ['password', 'token']:
                attrs.append(f'length = {info["length"]}')
            
            if info['charset'] != 'alnum':
                attrs.append(f'charset = "{info["charset"]}"')
            
            if info['source'] != 'internal':
                attrs.append(f'source = "{info["source"]}"')
            
            if info['deferred']:
                attrs.append('deferred = true')
            
            if info['description']:
                attrs.append(f'description = "{info["description"]}"')
            
            if attrs:
                attrs_str = ', '.join(attrs)
                toml_content += f'{name} = {{{attrs_str}}}\n'
            else:
                toml_content += f'{name} = "{info["value"]}"\n'
    
    return toml_content


def migrate_env_sample_to_toml(sample_path: str, toml_path: str = None, project_name: str = None) -> None:
    """
    Migrate a .env.sample file to .env.toml format.
    """
    if not os.path.isfile(sample_path):
        print(f"Error: {sample_path} not found")
        sys.exit(1)
    
    if toml_path is None:
        toml_path = sample_path.replace('.env.sample', '.env.toml')
    
    print(f"Migrating {sample_path} -> {toml_path}")
    
    # Parse legacy file
    variables, comments, control_vars = parse_legacy_env_sample(sample_path)
    
    print(f"Found {len(variables)} variables, {len(comments)} comments")
    
    # Generate TOML
    toml_content = generate_toml_config(variables, comments, control_vars, project_name)
    
    # Write TOML file
    with open(toml_path, 'w', encoding='utf-8') as f:
        f.write(toml_content)
    
    print(f"Migration complete: {toml_path}")
    print("\\nNext steps:")
    print(f"1. Review and edit {toml_path}")
    print("2. Test with: python3 compose-init-up.py")
    print(f"3. Remove {sample_path} when satisfied")


def main():
    """Main migration script."""
    import argparse
    
    parser = argparse.ArgumentParser(description="Migrate .env.sample to .env.toml format")
    parser.add_argument('sample_file', nargs='?', default=DEFAULT_ENV_SAMPLE_FILE, help='Input .env.sample file')
    parser.add_argument('-o', '--output', help='Output .env.toml file')
    parser.add_argument('-p', '--project-name', help='Project name override')

    args = parser.parse_args()

    output_file = args.output if args.output else DEFAULT_TOML_ACTIVE_FILE
    migrate_env_sample_to_toml(args.sample_file, output_file, args.project_name)


if __name__ == '__main__':
    main()