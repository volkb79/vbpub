#!/usr/bin/env python3
"""
Pre-Compose Hook Test Script

This script demonstrates the pre-compose hook pattern:
- Receives environment variables from compose-init-up
- Performs setup tasks (e.g., GitHub runner registration, external secret fetch)
- Returns new environment variables to be persisted in .env

Use cases demonstrated:
1. Fetching ephemeral tokens from external services (GitHub PAT, API keys)
2. Generating dynamic configuration based on environment
3. Setting up prerequisites before containers start (runner registration)
4. Injecting secrets from external secret managers

Expected interface:
- Environment: All variables from .env are available as os.environ
- Return: dict of new variables via JSON to stdout
- Exit: 0 for success, non-zero for failure
"""

import os
import sys
import json
import secrets
import time
from datetime import datetime

def log(msg):
    """Log to stderr so stdout remains clean for JSON return"""
    print(f"[PRE-COMPOSE-HOOK] {msg}", file=sys.stderr)

def generate_runner_token():
    """
    Simulate GitHub runner registration token fetch.
    In real scenarios, this would call GitHub API to get a registration token.
    """
    log("Simulating GitHub runner token generation...")
    # In production: github.post('/repos/{owner}/{repo}/actions/runners/registration-token')
    return f"RUNNER_{secrets.token_hex(16).upper()}"

def fetch_webhook_secret():
    """
    Simulate fetching webhook secret from external vault/secret manager.
    In real scenarios, this would call AWS Secrets Manager, HashiCorp Vault, etc.
    """
    log("Simulating webhook secret fetch from vault...")
    # In production: vault_client.read('secret/data/webhooks')
    return f"whsec_{secrets.token_hex(24)}"

def generate_api_key():
    """
    Simulate generating an API key for external service integration.
    """
    log("Generating external API key...")
    return f"sk_test_{secrets.token_hex(20)}"

class PreComposeHook:
    """Pre-compose hook following compose-init-up interface"""
    
    def __init__(self, env: dict):
        self.env = env
    
    def run(self) -> dict:
        """Execute hook and return new environment variables"""
        log("Starting pre-compose hook execution")
        
        # Read relevant environment variables
        project_name = self.env.get('LABEL_PROJECT_NAME', 'unknown')
        env_tag = self.env.get('LABEL_ENV_TAG', 'unknown')
        public_fqdn = self.env.get('PUBLIC_FQDN', 'localhost')
        
        log(f"Project: {project_name}")
        log(f"Environment: {env_tag}")
        log(f"FQDN: {public_fqdn}")
        
        # Perform pre-compose setup tasks
        new_vars = {}
        
        # Task 1: Generate/fetch runner token
        try:
            runner_token = generate_runner_token()
            new_vars['PRECOMPOSE_RUNNER_TOKEN'] = runner_token
            log(f"Generated runner token: {runner_token[:20]}...")
        except Exception as e:
            log(f"ERROR: Failed to generate runner token: {e}")
        
        # Task 2: Fetch webhook secret from external vault
        try:
            webhook_secret = fetch_webhook_secret()
            new_vars['PRECOMPOSE_WEBHOOK_SECRET'] = webhook_secret
            log(f"Fetched webhook secret: {webhook_secret[:15]}...")
        except Exception as e:
            log(f"ERROR: Failed to fetch webhook secret: {e}")
        
        # Task 3: Generate external API key
        try:
            api_key = generate_api_key()
            new_vars['PRECOMPOSE_EXTERNAL_API_KEY'] = api_key
            log(f"Generated API key: {api_key[:15]}...")
        except Exception as e:
            log(f"ERROR: Failed to generate API key: {e}")
        
        # Task 4: Add timestamp for audit/debugging
        timestamp = datetime.utcnow().isoformat() + 'Z'
        new_vars['PRECOMPOSE_TIMESTAMP'] = timestamp
        log(f"Timestamp: {timestamp}")
        
        # Task 5: Conditional logic based on environment
        if env_tag == 'prod':
            log("Production environment detected - enabling strict mode")
            new_vars['STRICT_MODE_ENABLED'] = 'true'
        else:
            log("Non-production environment - enabling debug features")
            new_vars['DEBUG_FEATURES_ENABLED'] = 'true'
        
        # Task 6: Create prerequisite files or directories if needed
        try:
            config_dir = os.path.join(os.path.dirname(__file__), 'generated-config')
            os.makedirs(config_dir, exist_ok=True)
            config_file = os.path.join(config_dir, 'precompose-config.json')
            with open(config_file, 'w') as f:
                json.dump({
                    'project': project_name,
                    'environment': env_tag,
                    'generated_at': timestamp,
                    'fqdn': public_fqdn
                }, f, indent=2)
            log(f"Created configuration file: {config_file}")
            new_vars['PRECOMPOSE_CONFIG_FILE'] = config_file
        except Exception as e:
            log(f"WARNING: Failed to create config file: {e}")
        
        log(f"Returning {len(new_vars)} new variables to compose-init-up")
        log("Pre-compose hook completed successfully")
        return new_vars
