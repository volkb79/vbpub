# compose-init-up Test Project

This is a comprehensive test suite for `compose-init-up.py` that validates all features and edge cases.

## Test Coverage

### 1. Password Generation (`_PASSWORD`)
- ✅ Simple empty password auto-generation
- ✅ Preserving existing password values
- ✅ Deferred password generation (`_PASSWORD_DEFERED`)
- ✅ Descriptor-based passwords:
  - `_PASSWORD_ALNUM{LENGTH}` (alphanumeric)
  - `_PASSWORD_HEX{LENGTH}` (hexadecimal)
  - With `_DEFERED` suffix

### 2. Token Generation (`_TOKEN_*`)
- ✅ `_TOKEN_INTERNAL`: Auto-generate and persist locally
- ✅ `_TOKEN_EXTERNAL`: Prompt for user input (or read from env)
- ✅ `_TOKEN_DEFERED`: Generated later by post-compose hook
- ✅ Descriptor-based tokens:
  - `_TOKEN_ALNUM{LENGTH}_INTERNAL`
  - `_TOKEN_HEX{LENGTH}_INTERNAL`
  - `_TOKEN_ALNUM{LENGTH}_EXTERNAL`
  - `_TOKEN_HEX{LENGTH}_EXTERNAL`
  - `_TOKEN_ALNUM{LENGTH}_DEFERED`
  - `_TOKEN_HEX{LENGTH}_DEFERED`

### 3. Command Substitution and Variable Expansion
- ✅ `$(command)` expansion (e.g., `UID=$(id -u)`)
- ✅ `${VAR}` variable references
- ✅ Nested variable expansion
- ✅ Command substitution in paths

### 4. Pre-Compose Hook
- ✅ Hook execution before compose starts
- ✅ Receiving environment variables
- ✅ Returning new variables via JSON
- ✅ Variables persisted to `.env`
- ✅ File/config generation by hook
- ✅ Use cases:
  - GitHub runner token generation
  - External secret fetching (vault/secret manager)
  - Dynamic API key generation
  - Timestamp and audit trails

### 5. Post-Compose Hook
- ✅ Hook execution after containers are running
- ✅ Docker command execution to inspect containers
- ✅ Extracting data from running services
- ✅ Returning new variables via JSON
- ✅ Variables persisted to `.env`
- ✅ Use cases:
  - Portus admin credential extraction
  - Container ID/IP address discovery
  - Database version queries
  - Robot account creation
  - Service health verification
  - Deferred secret generation

### 6. Directory Management
- ✅ `*_HOSTDIR_*` variable pattern detection
- ✅ Automatic creation of `vol-*` directories
- ✅ Reset behavior (`COMPINIT_RESET_BEFORE_START=hostdirs`)

### 7. Compose Modes
- ✅ `abort-on-failure`: Start detached, poll health, exit on success/fail
- ✅ Non-blocking operation (no manual Ctrl+C needed)
- ✅ Health check monitoring and reporting

### 8. Error Handling
- ✅ Missing `.env.sample` detection
- ✅ Missing TLS certificate handling
- ✅ Invalid compose file validation
- ✅ Hook execution failures
- ✅ Graceful error messages

### 9. Idempotency
- ✅ No regeneration of existing passwords/tokens
- ✅ Preserved values remain unchanged
- ✅ Safe to run multiple times

### 10. Edge Cases
- ✅ Very short descriptors (e.g., `_ALNUM8`)
- ✅ Very long descriptors (e.g., `_HEX128`)
- ✅ Minimum length (e.g., `_ALNUM1`)
- ✅ Empty values with whitespace
- ✅ Inline comments
- ✅ Special characters in values
- ✅ URL-like values
- ✅ JSON-like values
- ✅ Values with equals signs

## Files

- **`.env.sample`**: Comprehensive environment template with all test cases
- **`docker-compose.yml`**: Minimal compose file with fast startup and health checks
- **`pre_compose_hook.py`**: Pre-compose hook demonstrating variable injection
- **`post_compose_hook.py`**: Post-compose hook demonstrating data extraction
- **`run_tests.py`**: Automated test runner that validates all features
- **`README.md`**: This file

## Running Tests

### Quick Test Run
```bash
cd /home/vb/repos/vbpub/scripts/docker/test-project
./run_tests.py
```

### Manual Test Run
```bash
cd /home/vb/repos/vbpub/scripts/docker/test-project

# Clean start
rm -f .env
rm -rf vol-* generated-config

# Run compose-init-up
../compose-init-up.py

# Inspect generated .env
cat .env

# Check generated directories
ls -la vol-*

# Check hook output
cat generated-config/precompose-config.json
```

### Test Specific Scenarios

#### Test Password/Token Generation
```bash
rm -f .env
../compose-init-up.py
grep "PASSWORD\|TOKEN" .env | head -20
```

#### Test Command Substitution
```bash
rm -f .env
../compose-init-up.py
grep "UID\|GID\|CURRENT_DATE" .env
```

#### Test Hooks
```bash
rm -f .env
../compose-init-up.py
grep "PRECOMPOSE\|POSTCOMPOSE" .env
ls generated-config/
```

#### Test Idempotency
```bash
# First run
../compose-init-up.py > /tmp/run1.log 2>&1

# Save generated passwords
grep "PASSWORD" .env > /tmp/passwords1.txt

# Second run
../compose-init-up.py > /tmp/run2.log 2>&1

# Compare
grep "PASSWORD" .env > /tmp/passwords2.txt
diff /tmp/passwords1.txt /tmp/passwords2.txt
# Should show no differences
```

#### Test Reset Behavior
```bash
# Generate .env and volumes
../compose-init-up.py

# Check volumes exist
ls -d vol-*

# Reset volumes
COMPINIT_RESET_BEFORE_START=hostdirs ../compose-init-up.py

# Volumes should be recreated empty
ls -la vol-*
```

## Expected Behavior

### First Run
1. Script reads `.env.sample`
2. Generates passwords for empty `_PASSWORD` variables
3. Generates tokens for empty `_TOKEN_INTERNAL` variables
4. Expands command substitutions (UID, GID, dates)
5. Expands variable references
6. Executes `pre_compose_hook.py`
7. Adds pre-compose variables to `.env`
8. Creates `vol-*` directories
9. Validates `docker-compose.yml`
10. Starts containers in detached mode
11. Polls container health
12. Executes `post_compose_hook.py` when containers are healthy
13. Adds post-compose variables to `.env`
14. Exits successfully

### Second Run
1. Script loads existing `.env`
2. Skips regeneration of existing secrets
3. Re-executes hooks (may generate new values)
4. Updates any new variables
5. Validates and starts containers
6. Exits successfully

## Debugging

### Enable Verbose Output
Check `compose-init-up.py` output for detailed logging:
```bash
../compose-init-up.py 2>&1 | tee compose-init.log
```

### Check Hook Execution
Hook scripts log to stderr, so you'll see their output during execution:
```
[PRE-COMPOSE-HOOK] Starting pre-compose hook execution
[PRE-COMPOSE-HOOK] Project: compose-init-test
...
```

### Inspect Generated Values
```bash
# Show all generated passwords
grep "_PASSWORD" .env

# Show all generated tokens
grep "_TOKEN" .env

# Show hook-injected variables
grep "PRECOMPOSE\|POSTCOMPOSE" .env

# Show expanded commands
grep "UID\|GID\|DATE" .env
```

### Validate Descriptor Lengths
```bash
# Check ALNUM32 is 32 chars
value=$(grep "API_SECRET_PASSWORD_ALNUM32=" .env | cut -d'=' -f2)
echo "Length: ${#value} (expected: 32)"

# Check HEX64 is 64 chars and hex
value=$(grep "ENCRYPTION_KEY_PASSWORD_HEX64=" .env | cut -d'=' -f2)
echo "Length: ${#value} (expected: 64)"
echo "Hex check: $(echo $value | grep -qE '^[0-9a-f]+$' && echo 'valid' || echo 'invalid')"
```

## Cleanup

```bash
# Remove generated files and directories
cd /home/vb/repos/vbpub/scripts/docker/test-project
rm -f .env
rm -rf vol-* generated-config

# Remove containers and networks
docker compose down -v
```

## Integration with CI/CD

This test suite can be integrated into CI pipelines:

```yaml
# Example GitHub Actions workflow
- name: Test compose-init-up
  run: |
    cd scripts/docker/test-project
    python3 run_tests.py
```

## Known Limitations

1. **Docker Hub Rate Limits**: Tests use `busybox:1.36` which is small, but may still hit rate limits on unauthenticated pulls. Consider using a local registry or authenticated pulls.

2. **TLS Files**: Tests use dummy files in `/tmp`. Real projects need actual TLS certificates.

3. **External Dependencies**: Post-compose hook tests assume Docker is available and can execute `docker compose` commands.

4. **Timing Sensitivity**: Health checks and startup times may vary. Adjust `HEALTHCHECK_*` variables if needed.

## Contributing

When adding new features to `compose-init-up.py`:

1. Add test cases to `.env.sample`
2. Update `run_tests.py` with validation tests
3. Document new behavior in this README
4. Run full test suite to ensure no regressions
