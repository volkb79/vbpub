// Defaults are defined here so builds work without any environment.
// .env or shell variables can override these at build time.
variable "REGISTRY" {
  default = "ghcr.io"
}

// Override with NAMESPACE in your environment (.env or shell).
variable "NAMESPACE" {
  default = "your-org"
}

// Override with IMAGE_NAME in your environment (.env or shell).
variable "IMAGE_NAME" {
  default = "vsc-devcontainer"
}

// Used in tags; build script sets BUILD_DATE if not provided.
variable "BUILD_DATE" {
  default = "19700101"
}

function "tag" {
  params = [debian, python]
  result = "${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}:${debian}-py${python}-${BUILD_DATE}"
}

target "base" {
  context = "."
  dockerfile = "Dockerfile"
}

target "bookworm-py311" {
  inherits = ["base"]
  args = {
    BASE_IMAGE = "mcr.microsoft.com/devcontainers/python:1-3.11-bookworm"
    PYTHON_VERSION = "3.11"
    DEBIAN_VERSION = "bookworm"
  }
  tags = [tag("bookworm", "3.11")]
}

target "bookworm-py313" {
  inherits = ["base"]
  args = {
    BASE_IMAGE = "mcr.microsoft.com/devcontainers/python:1-3.13-bookworm"
    PYTHON_VERSION = "3.13"
    DEBIAN_VERSION = "bookworm"
  }
  tags = [tag("bookworm", "3.13")]
}

target "trixie-py311" {
  inherits = ["base"]
  args = {
    BASE_IMAGE = "python:3.11-trixie"
    PYTHON_VERSION = "3.11"
    DEBIAN_VERSION = "trixie"
  }
  tags = [tag("trixie", "3.11")]
}

target "trixie-py313" {
  inherits = ["base"]
  args = {
    BASE_IMAGE = "python:3.13-trixie"
    PYTHON_VERSION = "3.13"
    DEBIAN_VERSION = "trixie"
  }
  tags = [tag("trixie", "3.13")]
}

group "all" {
  targets = [
    "bookworm-py311",
    "bookworm-py313",
    "trixie-py311",
    "trixie-py313"
  ]
}
