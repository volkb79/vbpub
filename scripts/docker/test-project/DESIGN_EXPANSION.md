# Expansion Semantics & EXTERNAL token strictness

This document summarizes how `compose-init-up.py` handles command substitution,
environment variable expansion, and EXTERNAL token handling.

1. Generation-time expansion

- By default `compose-init-up.py` expands command substitutions `$(...)` and
  environment variables in both `$VAR` and `${VAR}` form when generating the
  live `.env` file. This ensures values like `UID=$(id -u)` become literal
  numeric values in the generated file.
- The helper exposes `COMPINIT_ENABLE_ENV_EXPANSION` to control runtime expansion
  behavior for consumers. Test projects typically expect generation-time
  expansion so tests can assert UID/GID and derived paths.

2. EXTERNAL tokens and strict mode

- External tokens are variables ending in `_TOKEN_EXTERNAL` or descriptor
  variants with `_EXTERNAL` suffix. These represent secrets that should be
  supplied by an operator or secret store.
- Default behavior in automated/non-interactive runs (`COMPINIT_ASSUME_YES=1`):
  - If a value for an EXTERNAL token is supplied as an environment variable
    to the process, it will be used.
  - If no value is provided and `COMPINIT_EXTERNAL_STRICT` is not set, the
    - If no value is provided and `COMPINIT_STRICT_EXTERNAL` is not set, the
      helper will warn and continue with an empty value (CI-friendly).
    - If `COMPINIT_STRICT_EXTERNAL=1` and running non-interactively, the
      helper will fail with an error to enforce strict secret provisioning.

3. Hooks and persistence

- Pre- and post-compose Python hooks can return variables (a dict). These are
  now persisted into the generated `.env` file so subsequent steps and tests
  can read them.

Use this doc as the canonical reference for authors of `.env.sample` files and
for CI authors configuring `compose-init-up.py`.
