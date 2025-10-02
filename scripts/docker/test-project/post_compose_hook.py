#!/usr/bin/env python3
"""
Post-Compose Hook Test Script

This script demonstrates the post-compose hook pattern:
- Containers are running and healthy
- Extract data from running containers (e.g., Portus admin credentials, service IDs)
- Generate additional secrets or tokens
- Return new environment variables to be persisted in .env

Use cases demonstrated:
1. Extracting admin credentials from container logs (Portus scenario)
2. Getting container IDs, IP addresses, or service discovery info
3. Querying container APIs to get tokens (robot accounts, service tokens)
4. Validating service readiness and extracting version information
5. Creating database users and returning their credentials

Expected interface:
- Environment: All variables from .env are available as os.environ
- Docker: Can execute docker commands to inspect/interact with containers
- Return: dict of new variables via JSON to stdout
- Exit: 0 for success, non-zero for failure
"""

import os
import sys
import json
import subprocess
import secrets
import time
from datetime import datetime

def log(msg):
    """Log to stderr so stdout remains clean for JSON return"""
    print(f"[POST-COMPOSE-HOOK] {msg}", file=sys.stderr)

def run_docker_command(cmd):
    """Execute a docker command and return output"""
    log(f"Executing: {' '.join(cmd)}")
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        log(f"Docker command failed: {e.stderr}")
        raise
    except subprocess.TimeoutExpired:
        log("Docker command timed out")
        raise

def extract_portus_admin_credentials():
    """
    Simulate extracting Portus admin credentials from container logs.
    In real scenario, would parse container logs for initial admin password.
    """
    log("Simulating Portus admin credential extraction...")
    
    # In production, would do something like:
    # logs = run_docker_command(['docker', 'compose', 'logs', 'portus'])
    # Parse logs for: "Admin user created with password: XXXXX"
    
    # For testing, generate simulated credentials
    admin_user = "portus_admin"
    admin_token = f"portus_{secrets.token_hex(32)}"
    
    log(f"Extracted admin user: {admin_user}")
    log(f"Extracted admin token: {admin_token[:20]}...")
    
    return admin_user, admin_token

def get_container_info():
    """Get information about running containers"""
    log("Querying container information...")
    
    try:
        # Get project name from environment
        project_name = os.environ.get('LABEL_PROJECT_NAME', 'test-project')
        
        # List containers for this project
        output = run_docker_command([
            'docker', 'compose', 'ps', '--format', 'json'
        ])
        
        if output:
            log(f"Found running containers")
            # Parse JSON output (each line is a container)
            containers = []
            for line in output.split('\n'):
                if line.strip():
                    containers.append(json.loads(line))
            
            log(f"Container count: {len(containers)}")
            return containers
        else:
            log("No containers found")
            return []
    except Exception as e:
        log(f"Failed to get container info: {e}")
        return []

def query_database_version():
    """
    Simulate querying database version from running container.
    In production, would exec into db container and query version.
    """
    log("Simulating database version query...")
    
    # In production:
    # version = run_docker_command([
    #     'docker', 'compose', 'exec', '-T', 'db',
    #     'psql', '-U', 'postgres', '-t', '-c', 'SELECT version();'
    # ])
    
    # For testing, return simulated version
    version = "PostgreSQL 15.3 (Debian 15.3-1.pgdg120+1)"
    log(f"Database version: {version}")
    return version

def create_robot_account():
    """
    Simulate creating a robot/service account in a running service (e.g., Portus).
    In production, would call container API to create account and get token.
    """
    log("Simulating robot account creation...")
    
    # In production, would call Portus API:
    # POST /api/v1/robot_accounts
    # Get back: {"id": 123, "name": "robot_ci", "token": "..."}
    
    robot_name = "robot_ci_cd"
    robot_token = f"robot_{secrets.token_hex(28)}"
    
    log(f"Created robot account: {robot_name}")
    log(f"Robot token: {robot_token[:20]}...")
    
    return robot_name, robot_token

def verify_service_health():
    """
    Verify all services are healthy and ready.
    """
    log("Verifying service health...")
    
    try:
        # Check health status of all services
        output = run_docker_command([
            'docker', 'compose', 'ps', '--format', 'json'
        ])
        
        if not output:
            log("No services found")
            return False
        
        all_healthy = True
        for line in output.split('\n'):
            if line.strip():
                container = json.loads(line)
                status = container.get('Health', 'unknown')
                name = container.get('Service', 'unknown')
                
                if status and 'healthy' in status.lower():
                    log(f"✓ {name}: healthy")
                elif status == 'unknown':
                    # No health check defined, check if running
                    state = container.get('State', 'unknown')
                    if state == 'running':
                        log(f"✓ {name}: running (no healthcheck)")
                    else:
                        log(f"✗ {name}: {state}")
                        all_healthy = False
                else:
                    log(f"✗ {name}: {status}")
                    all_healthy = False
        
        return all_healthy
    except Exception as e:
        log(f"Health check failed: {e}")
        return False

class PostComposeHook:
    """Post-compose hook following compose-init-up interface"""
    
    def __init__(self, env: dict):
        self.env = env
    
    def run(self) -> dict:
        """Execute hook and return new environment variables"""
        log("Starting post-compose hook execution")
        
        # Read relevant environment variables
        project_name = self.env.get('LABEL_PROJECT_NAME', 'unknown')
        env_tag = self.env.get('LABEL_ENV_TAG', 'unknown')
        
        log(f"Project: {project_name}")
        log(f"Environment: {env_tag}")
        
        # Wait a moment for containers to fully initialize
        log("Waiting for containers to stabilize...")
        time.sleep(2)
        
        # Collect new variables from post-compose tasks
        new_vars = {}
        
        # Task 1: Extract Portus admin credentials
        try:
            admin_user, admin_token = extract_portus_admin_credentials()
            new_vars['POSTCOMPOSE_ADMIN_USERNAME'] = admin_user
            new_vars['POSTCOMPOSE_ADMIN_TOKEN'] = admin_token
        except Exception as e:
            log(f"WARNING: Failed to extract admin credentials: {e}")
        
        # Task 2: Get container information
        try:
            containers = get_container_info()
            if containers:
                first_container = containers[0]
                container_id = first_container.get('ID', 'unknown')
                new_vars['POSTCOMPOSE_FIRST_CONTAINER_ID'] = container_id
                log(f"First container ID: {container_id}")
        except Exception as e:
            log(f"WARNING: Failed to get container info: {e}")
        
        # Task 3: Query database version
        try:
            db_version = query_database_version()
            new_vars['POSTCOMPOSE_DATABASE_VERSION'] = db_version
        except Exception as e:
            log(f"WARNING: Failed to query database version: {e}")
        
        # Task 4: Create robot/service account
        try:
            robot_name, robot_token = create_robot_account()
            new_vars['POSTCOMPOSE_ROBOT_NAME'] = robot_name
            new_vars['POSTCOMPOSE_ROBOT_TOKEN'] = robot_token
        except Exception as e:
            log(f"WARNING: Failed to create robot account: {e}")
        
        # Task 5: Verify service health
        try:
            all_healthy = verify_service_health()
            new_vars['POSTCOMPOSE_SERVICE_READY'] = 'true' if all_healthy else 'false'
            log(f"All services healthy: {all_healthy}")
        except Exception as e:
            log(f"WARNING: Health check failed: {e}")
            new_vars['POSTCOMPOSE_SERVICE_READY'] = 'unknown'
        
        # Task 6: Add completion timestamp
        timestamp = datetime.utcnow().isoformat() + 'Z'
        new_vars['POSTCOMPOSE_COMPLETED_AT'] = timestamp
        log(f"Completion timestamp: {timestamp}")
        
        # Task 7: Deferred secrets
        try:
            if not self.env.get('PORTUS_ADMIN_PASSWORD'):
                log("Generating deferred PORTUS_ADMIN_PASSWORD...")
                portus_password = secrets.token_urlsafe(32)
                new_vars['PORTUS_ADMIN_PASSWORD'] = portus_password
                log("Generated PORTUS_ADMIN_PASSWORD")
            
            if not self.env.get('ROBOT_TOKEN_INTERNAL'):
                log("Generating deferred ROBOT_TOKEN_INTERNAL...")
                robot_token_internal = secrets.token_hex(24)
                new_vars['ROBOT_TOKEN_INTERNAL'] = robot_token_internal
                log("Generated ROBOT_TOKEN_INTERNAL")
        except Exception as e:
            log(f"WARNING: Failed to generate deferred secrets: {e}")
        
        log(f"Returning {len(new_vars)} new variables to compose-init-up")
        log("Post-compose hook completed successfully")
        return new_vars
