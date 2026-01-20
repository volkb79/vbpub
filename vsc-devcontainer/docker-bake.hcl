// Defaults are defined here so builds work without any environment.
// .env or shell variables can override these at build time.
variable "REGISTRY" {
  default = "ghcr.io"
}

// Set NAMESPACE to your GHCR org/user (e.g., volkb79-2) so pushes land at ghcr.io/<namespace>/vsc-devcontainer:<variant>. 
variable "NAMESPACE" {
  default = "volkb79-2"
}

// Override with IMAGE_NAME in your environment (.env or shell).
variable "IMAGE_NAME" {
  default = "vsc-devcontainer"
}

// Used in tags; build script sets BUILD_DATE if not provided.
variable "BUILD_DATE" {
  default = "19700101"
}

variable "BACKPORTS_URI" {
  default = "http://debian.anexia.at/debian"
}

variable "OCI_TITLE" {
  default = "vsc-devcontainer"
}

variable "OCI_DESCRIPTION" {
  default = "Pre-built VS Code devcontainer base image with modern CLI tools, Python venv, and service clients."
}

variable "OCI_SOURCE" {
  default = "https://github.com/volkb79-2/vbpub"
}

variable "OCI_DOCUMENTATION" {
  default = "https://github.com/volkb79-2/vbpub/tree/main/vsc-devcontainer"
}

variable "OCI_URL" {
  default = "https://github.com/volkb79-2/vbpub/tree/main/vsc-devcontainer"
}

variable "OCI_LICENSES" {
  default = "MIT"
}

variable "OCI_VENDOR" {
  default = "volkb79-2"
}

variable "OCI_VERSION" {
  default = "${BUILD_DATE}"
}

variable "OCI_REVISION" {
  default = "unknown"
}

variable "OCI_CREATED" {
  default = "unknown"
}

variable "DELTA_VERSION" {
  default = "latest"
}

variable "GH_VERSION" {
  default = "latest"
}

variable "RGA_VERSION" {
  default = "latest"
}

variable "AWSCLI_VERSION" {
  default = "latest"
}

variable "B2_VERSION" {
  default = "latest"
}

variable "BAT_VERSION" {
  default = "latest"
}

variable "CONSUL_VERSION" {
  default = "latest"
}

variable "FD_VERSION" {
  default = "latest"
}

variable "FZF_VERSION" {
  default = "latest"
}

variable "POSTGRESQL_CLIENT_VERSION" {
  default = "latest"
}

variable "REDIS_TOOLS_VERSION" {
  default = "latest"
}

variable "RIPGREP_VERSION" {
  default = "latest"
}

variable "SHELLCHECK_VERSION" {
  default = "latest"
}

variable "VAULT_VERSION" {
  default = "latest"
}

variable "YQ_VERSION" {
  default = "latest"
}

function "tag" {
  params = [debian, python]
  result = "${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}:${debian}-py${python}-${BUILD_DATE}"
}

function "latest_tag" {
  params = [debian, python]
  result = "${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}:${debian}-py${python}-latest"
}

target "base" {
  context = "."
  dockerfile = "Dockerfile"
  args = {
    BACKPORTS_URI = "${BACKPORTS_URI}"
    AWSCLI_VERSION = "${AWSCLI_VERSION}"
    B2_VERSION = "${B2_VERSION}"
    BAT_VERSION = "${BAT_VERSION}"
    CONSUL_VERSION = "${CONSUL_VERSION}"
    DELTA_VERSION = "${DELTA_VERSION}"
    FD_VERSION = "${FD_VERSION}"
    FZF_VERSION = "${FZF_VERSION}"
    GH_VERSION = "${GH_VERSION}"
    OCI_TITLE = "${OCI_TITLE}"
    OCI_DESCRIPTION = "${OCI_DESCRIPTION}"
    OCI_SOURCE = "${OCI_SOURCE}"
    OCI_DOCUMENTATION = "${OCI_DOCUMENTATION}"
    OCI_URL = "${OCI_URL}"
    OCI_LICENSES = "${OCI_LICENSES}"
    OCI_VENDOR = "${OCI_VENDOR}"
    OCI_VERSION = "${OCI_VERSION}"
    OCI_REVISION = "${OCI_REVISION}"
    OCI_CREATED = "${OCI_CREATED}"
    POSTGRESQL_CLIENT_VERSION = "${POSTGRESQL_CLIENT_VERSION}"
    REDIS_TOOLS_VERSION = "${REDIS_TOOLS_VERSION}"
    RIPGREP_VERSION = "${RIPGREP_VERSION}"
    RGA_VERSION = "${RGA_VERSION}"
    SHELLCHECK_VERSION = "${SHELLCHECK_VERSION}"
    VAULT_VERSION = "${VAULT_VERSION}"
    YQ_VERSION = "${YQ_VERSION}"
  }
}

target "bookworm-py311" {
  inherits = ["base"]
  args = {
    BASE_IMAGE = "mcr.microsoft.com/devcontainers/python:1-3.11-bookworm"
    PYTHON_VERSION = "3.11"
    DEBIAN_VERSION = "bookworm"
  }
  tags = [tag("bookworm", "3.11"), latest_tag("bookworm", "3.11")]
}

target "bookworm-py313" {
  inherits = ["base"]
  args = {
    BASE_IMAGE = "mcr.microsoft.com/devcontainers/python:1-3.13-bookworm"
    PYTHON_VERSION = "3.13"
    DEBIAN_VERSION = "bookworm"
  }
  tags = [tag("bookworm", "3.13"), latest_tag("bookworm", "3.13")]
}

target "trixie-py311" {
  inherits = ["base"]
  args = {
    BASE_IMAGE = "python:3.11-trixie"
    PYTHON_VERSION = "3.11"
    DEBIAN_VERSION = "trixie"
  }
  tags = [tag("trixie", "3.11"), latest_tag("trixie", "3.11")]
}

target "trixie-py313" {
  inherits = ["base"]
  args = {
    BASE_IMAGE = "python:3.13-trixie"
    PYTHON_VERSION = "3.13"
    DEBIAN_VERSION = "trixie"
  }
  tags = [tag("trixie", "3.13"), latest_tag("trixie", "3.13"), "${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}:latest"]
}

group "all" {
  targets = [
    "bookworm-py311",
    "bookworm-py313",
    "trixie-py311",
    "trixie-py313"
  ]
}
