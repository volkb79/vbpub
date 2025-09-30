# Bash Pitfalls Guide

A comprehensive guide to common bash scripting pitfalls and their solutions, with real-world examples from production scripts.

## Table of Contents

1. [Arithmetic Expressions with `set -e`](#arithmetic-expressions-with-set--e)
2. [Array Handling Pitfalls](#array-handling-pitfalls)
3. [Quoting and Word Splitting](#quoting-and-word-splitting)
4. [Exit Code Handling](#exit-code-handling)
5. [Pipeline Error Handling](#pipeline-error-handling)
6. [Variable Expansion Traps](#variable-expansion-traps)
7. [File Test Pitfalls](#file-test-pitfalls)
8. [JSON Parsing with jq](#json-parsing-with-jq)
9. [Best Practices Summary](#best-practices-summary)

---

## Arithmetic Expressions with `set -e`

### The Problem

When using `set -e` (exit on error), certain arithmetic expressions can unexpectedly cause script termination.

### Real-World Example

```bash
#!/bin/bash
set -euo pipefail

success_count=0
failure_count=0

# ❌ WRONG: This will exit the script when success_count=0
if some_operation; then
    ((success_count++))  # Returns 0 (false) when success_count was 0
    echo "Success!"
else
    ((failure_count++))
    echo "Failed!"
fi
```

### Why This Happens

- `((success_count++))` is a post-increment operation
- It returns the **old value** of the variable
- When `success_count=0`, `((success_count++))` returns `0` (falsy)
- With `set -e`, any falsy return value (non-zero exit code) terminates the script

### The Solution

```bash
#!/bin/bash
set -euo pipefail

success_count=0
failure_count=0

# ✅ CORRECT: Use assignment-style arithmetic
if some_operation; then
    success_count=$((success_count + 1))  # Always returns the new value
    echo "Success!"
else
    failure_count=$((failure_count + 1))
    echo "Failed!"
fi

# Alternative solutions:
((success_count++)) || true  # Ignore the return value
: $((success_count++))       # Use : (no-op) to consume the return value
```

### Other Arithmetic Pitfalls

```bash
# ❌ These can also cause issues with set -e:
((count--))         # Returns old value (problematic when count=0)
((result = 5 - 5))  # Returns 0 when result is 0
((flag = 0))        # Returns 0 (false)

# ✅ Safe alternatives:
count=$((count - 1))
result=$((5 - 5)) 
flag=0
```

---

## Array Handling Pitfalls

### Empty Array Expansion

```bash
#!/bin/bash
set -euo pipefail

# ❌ WRONG: Fails with "unbound variable" if array is empty
repos=()
for repo in "${repos[@]}"; do  # Error when repos is empty
    echo "$repo"
done

# ✅ CORRECT: Handle empty arrays safely
repos=()
for repo in "${repos[@]+"${repos[@]}"}"; do  # No error when empty
    echo "$repo"
done

# Or simply:
if [[ ${#repos[@]} -gt 0 ]]; then
    for repo in "${repos[@]}"; do
        echo "$repo"
    done
fi
```

### Array Assignment in Functions

```bash
# ❌ WRONG: Array assignment can fail silently
function get_repos() {
    local repos=()
    repos+=("repo1")
    repos+=("repo2")
    echo "${repos[@]}"  # This concatenates elements with spaces
}

# ✅ CORRECT: Use printf or return codes
function get_repos() {
    local repos=("repo1" "repo2")
    printf '%s\n' "${repos[@]}"
}

# Usage:
readarray -t my_repos < <(get_repos)
```

---

## Quoting and Word Splitting

### Variable Expansion

```bash
#!/bin/bash

filename="my file.txt"
directory="/path/with spaces"

# ❌ WRONG: Subject to word splitting
ls $filename                    # Becomes: ls my file.txt (two arguments)
cd $directory                   # Fails on spaces
rm $filename                    # Could remove wrong files

# ✅ CORRECT: Always quote variable expansions
ls "$filename"                  # Single argument: "my file.txt"
cd "$directory"                 # Handles spaces correctly
rm "$filename"                  # Safe removal

# Exception: When you intentionally want word splitting
options="-l -a -h"
ls $options /path               # Expands to: ls -l -a -h /path
```

### Command Substitution

```bash
# ❌ WRONG: Loses formatting and fails on spaces
files=$(ls)
for file in $files; do          # Word splitting breaks filenames with spaces
    echo "$file"
done

# ✅ CORRECT: Preserve structure
while IFS= read -r file; do
    echo "$file"
done < <(ls)

# Or use arrays:
readarray -t files < <(ls)
for file in "${files[@]}"; do
    echo "$file"
done
```

---

## Exit Code Handling

### Testing Command Success

```bash
# ❌ WRONG: Assumes commands always succeed
result=$(curl -s "https://api.github.com/user")
user=$(echo "$result" | jq -r '.login')

# ✅ CORRECT: Check exit codes explicitly
if result=$(curl -s "https://api.github.com/user"); then
    if user=$(echo "$result" | jq -r '.login'); then
        echo "User: $user"
    else
        echo "Failed to parse JSON"
        exit 1
    fi
else
    echo "Failed to fetch user data"
    exit 1
fi
```

### Pipeline Exit Codes

```bash
set -euo pipefail

# ❌ WRONG: Only checks last command in pipeline
curl -s "https://api.github.com/invalid" | jq -r '.login'  # jq might succeed even if curl fails

# ✅ CORRECT: pipefail ensures any pipeline failure is caught
# The set -o pipefail above makes this safe

# For more control:
if ! result=$(curl -s "https://api.github.com/user"); then
    echo "Curl failed"
    exit 1
fi

if ! user=$(echo "$result" | jq -r '.login'); then
    echo "jq failed"
    exit 1
fi
```

---

## Pipeline Error Handling

### The `pipefail` Option

```bash
#!/bin/bash
set -euo pipefail

# Without pipefail, this would succeed even if curl fails:
# curl fails → jq receives empty input → pipeline "succeeds" with exit code 0

# ❌ WRONG (without pipefail):
set -eu  # Missing pipefail
curl -s "https://invalid-url" | jq -r '.data'  # Fails silently

# ✅ CORRECT:
set -euo pipefail
curl -s "https://api.github.com/user" | jq -r '.login'  # Fails fast if curl fails
```

### Complex Pipeline Debugging

```bash
# When debugging complex pipelines, check each step:
set -euo pipefail

# ❌ Hard to debug:
result=$(curl -s "$url" | jq -r '.data[]' | grep "active" | head -n1)

# ✅ Easier to debug:
temp_file=$(mktemp)
trap 'rm -f "$temp_file"' EXIT

if ! curl -s "$url" > "$temp_file"; then
    echo "Curl failed for: $url"
    exit 1
fi

if ! jq -r '.data[]' "$temp_file" | grep "active" | head -n1; then
    echo "Processing failed"
    cat "$temp_file"  # Show what we actually got
    exit 1
fi
```

---

## Variable Expansion Traps

### Unset Variables

```bash
#!/bin/bash
set -euo pipefail

# ❌ WRONG: Fails if OPTIONAL_VAR is not set
echo "Value: $OPTIONAL_VAR"

# ✅ CORRECT: Handle unset variables
echo "Value: ${OPTIONAL_VAR:-default_value}"
echo "Value: ${OPTIONAL_VAR:+set_value}"
echo "Value: ${OPTIONAL_VAR?error_message}"

# For environment variables:
API_KEY="${API_KEY:?API_KEY environment variable is required}"
```

### Path Handling

```bash
# ❌ WRONG: Vulnerable to path traversal
user_input="../../../etc/passwd"
cat "$user_input"

# ✅ CORRECT: Validate and sanitize paths
user_input="../../../etc/passwd"
# Remove leading paths and ensure it's in allowed directory
safe_path=$(basename "$user_input")
full_path="/allowed/directory/$safe_path"

if [[ "$full_path" == "/allowed/directory/"* ]] && [[ -f "$full_path" ]]; then
    cat "$full_path"
else
    echo "Invalid or unsafe path"
    exit 1
fi
```

---

## File Test Pitfalls

### Testing File Existence

```bash
filename="my file.txt"

# ❌ WRONG: Word splitting breaks the test
if [[ -f $filename ]]; then     # Without quotes, fails on spaces
    echo "File exists"
fi

# ✅ CORRECT: Always quote in tests
if [[ -f "$filename" ]]; then
    echo "File exists"
fi

# ❌ WRONG: Using single brackets with unquoted variables
if [ -f $filename ]; then       # Very dangerous with spaces or special chars
    echo "File exists"
fi

# ✅ CORRECT: Use double brackets or quote everything
if [ -f "$filename" ]; then     # Safe with quotes
    echo "File exists"
fi
```

### Directory Creation

```bash
directory="/path/with spaces"

# ❌ WRONG: Creates multiple directories due to word splitting
mkdir -p $directory

# ✅ CORRECT: Quote the path
mkdir -p "$directory"

# Better: Check if creation was successful
if ! mkdir -p "$directory"; then
    echo "Failed to create directory: $directory"
    exit 1
fi
```

---

## JSON Parsing with jq

### Handling Missing Fields

```bash
json_response='{"user": {"name": "John"}}'

# ❌ WRONG: Fails if field doesn't exist
email=$(echo "$json_response" | jq -r '.user.email')  # Returns "null" as string

# ✅ CORRECT: Handle missing fields explicitly
email=$(echo "$json_response" | jq -r '.user.email // empty')
if [[ -n "$email" ]]; then
    echo "Email: $email"
else
    echo "No email found"
fi

# Or provide defaults:
email=$(echo "$json_response" | jq -r '.user.email // "no-email@example.com"')
```

### Array Processing

```bash
json_array='{"repos": [{"name": "repo1"}, {"name": "repo2"}]}'

# ❌ WRONG: Doesn't handle empty arrays or missing fields
names=$(echo "$json_array" | jq -r '.repos[].name')

# ✅ CORRECT: Safe array processing
if names=$(echo "$json_array" | jq -r '.repos[]?.name // empty' 2>/dev/null); then
    if [[ -n "$names" ]]; then
        while IFS= read -r name; do
            echo "Repo: $name"
        done <<< "$names"
    else
        echo "No repositories found"
    fi
else
    echo "Failed to parse JSON or no repos field"
fi
```

---

## Best Practices Summary

### Essential Script Header

```bash
#!/bin/bash
# Always use these flags for robust scripts:
set -euo pipefail

# -e: Exit immediately if a command exits with a non-zero status
# -u: Treat unset variables as an error and exit immediately
# -o pipefail: The return value of a pipeline is the status of the last 
#              command to exit with a non-zero status, or zero if no 
#              command exited with a non-zero status
```

### Safe Arithmetic

```bash
# ✅ Use these patterns:
counter=$((counter + 1))        # Always returns new value
result=$((a + b))               # Safe for any values
flag=1                          # Direct assignment

# ❌ Avoid these with set -e:
((counter++))                   # Can return 0 (false)
((result = a - b))              # Returns 0 when result is 0
```

### Safe Variable Handling

```bash
# ✅ Always quote variables:
echo "$variable"
rm "$filename"
cd "$directory"

# ✅ Handle unset variables:
value="${VAR:-default}"
required="${REQUIRED_VAR:?Missing required variable}"

# ✅ Use arrays properly:
array=("item1" "item2" "item3")
for item in "${array[@]}"; do
    echo "$item"
done
```

### Safe External Commands

```bash
# ✅ Check command existence:
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not installed"
    exit 1
fi

# ✅ Capture and check exit codes:
if result=$(curl -s "$url" 2>&1); then
    echo "Success: $result"
else
    echo "Curl failed: $result"
    exit 1
fi
```

### Error Context and Cleanup

```bash
# ✅ Provide context in error messages:
if ! mkdir -p "$directory"; then
    echo "Error: Failed to create directory '$directory'" >&2
    echo "Check permissions and disk space" >&2
    exit 1
fi

# ✅ Use trap for cleanup:
temp_file=$(mktemp)
trap 'rm -f "$temp_file"' EXIT

# ✅ Use trap for error context:
trap 'echo "Error on line $LINENO: $BASH_COMMAND" >&2' ERR
```

---

## Debugging Tips

### Enable Debug Mode

```bash
# Add to script for debugging:
set -x                          # Print commands before executing
set -v                          # Print shell input lines as they are read

# Or run with:
bash -x your_script.sh
```

### Check Your Script

```bash
# Use shellcheck for static analysis:
shellcheck your_script.sh

# Common shellcheck warnings to fix:
# SC2086: Double quote to prevent globbing and word splitting
# SC2068: Double quote array expansions to avoid re-splitting elements
# SC2046: Quote this to prevent word splitting
```

### Test Edge Cases

```bash
# Test your script with:
# - Empty arrays
# - Variables with spaces
# - Missing files/directories
# - Network failures (mock with false commands)
# - Invalid JSON responses
# - Unset environment variables
```

---

## Conclusion

The most common bash pitfalls stem from:

1. **Incorrect assumptions about command success**
2. **Improper variable quoting and expansion**
3. **Misunderstanding arithmetic expression return values**
4. **Not handling edge cases (empty arrays, missing files, etc.)**

By following the patterns in this guide and using `set -euo pipefail`, you can write more robust bash scripts that fail fast and provide clear error messages.

Remember: **Always quote your variables, check your exit codes, and test edge cases!**