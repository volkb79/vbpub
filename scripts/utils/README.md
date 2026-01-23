### Utility Tools (`utils/`)

#### `utils/jwt-decode` - JWT Token Analyzer
**Purpose:** Decodes and analyzes JSON Web Tokens for GitHub Apps.

```bash
# Decode JWT with validation
utils/jwt-decode --validate --verbose "eyJhbGciOiJSUzI1NiIs..."

# Extract only payload in JSON format
echo "JWT_TOKEN" | utils/jwt-decode --payload-only --quiet

# Table format with signature info
utils/jwt-decode --format table --signature-info "JWT_TOKEN"
```

**Key Features:**
- ✅ Complete JWT structure analysis
- ✅ Timestamp validation and human-readable dates
- ✅ Multiple output formats (JSON, YAML, table)
- ✅ GitHub App claim validation
- ✅ Base64url decoding with error handling
- ✅ Signature metadata analysis

**Validation Checks:**
- JWT structure (3 parts: header.payload.signature)
- Algorithm validation (RS256 required for GitHub Apps)
- Required claims presence (iss, iat, exp)
- Timestamp validation (not expired, reasonable lifetime)

#### `utils/subtree-checkout` - Repository Subtree Tool
**Purpose:** Efficiently checkout specific subdirectories from GitHub repositories.

```bash
# Interactive subtree selection
utils/subtree-checkout volkb79/DST-DNS

# Direct subtree download
utils/subtree-checkout volkb79/DST-DNS projects/controller --output /tmp/controller

# Use sparse checkout for large repositories
utils/subtree-checkout --method sparse-checkout volkb79/DST-DNS projects/controller
```

**Key Features:**
- ✅ Two checkout methods: download (API) and sparse-checkout (Git)
- ✅ Interactive subtree browser with search
- ✅ Support for private repositories (PAT authentication)
- ✅ Recursive directory scanning and listing
- ✅ Progress tracking and verbose logging
- ✅ Overwrite protection with confirmation

**Checkout Methods:**
- `download`: Fast API-based download (no Git history)
- `sparse-checkout`: Git-based with history preservation
