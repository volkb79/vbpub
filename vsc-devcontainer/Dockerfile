# Devcontainer base image (pre-built)
# Supports multiple Debian + Python variants via build args.

ARG PYTHON_VERSION="3.13"
ARG DEBIAN_VERSION="bookworm"
ARG BASE_IMAGE="mcr.microsoft.com/devcontainers/python:1-${PYTHON_VERSION}-${DEBIAN_VERSION}"
ARG BACKPORTS_URI="http://debian.anexia.at/debian"

ARG AWSCLI_VERSION="latest"
ARG B2_VERSION="latest"
ARG BAT_VERSION="latest"
ARG CONSUL_VERSION="latest"
ARG FD_VERSION="latest"
ARG FZF_VERSION="latest"
ARG POSTGRESQL_CLIENT_VERSION="latest"
ARG REDIS_TOOLS_VERSION="latest"
ARG RIPGREP_VERSION="latest"
ARG SHELLCHECK_VERSION="latest"
ARG VAULT_VERSION="latest"
ARG YQ_VERSION="latest"
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-c"]

ARG PYTHON_VERSION
ARG DEBIAN_VERSION
ARG BACKPORTS_URI
ARG AWSCLI_VERSION
ARG B2_VERSION
ARG BAT_VERSION
ARG CONSUL_VERSION
ARG FD_VERSION
ARG FZF_VERSION
ARG POSTGRESQL_CLIENT_VERSION
ARG REDIS_TOOLS_VERSION
ARG RIPGREP_VERSION
ARG SHELLCHECK_VERSION
ARG VAULT_VERSION
ARG YQ_VERSION

ENV DEBIAN_FRONTEND=noninteractive

USER root

COPY apt/backports.sources.in /tmp/backports.sources.in
COPY apt/backports.pref.in /tmp/backports.pref.in

# Ensure vscode user exists (non-devcontainers bases)
RUN set -euo pipefail; \
    if ! id -u vscode >/dev/null 2>&1; then \
        if ! getent group vscode >/dev/null 2>&1; then \
            groupadd -g 1000 vscode; \
        fi; \
        useradd -m -s /bin/bash -u 1000 -g 1000 vscode; \
    fi

# Core system packages
RUN set -euo pipefail; \
    if [ "${DEBIAN_VERSION}" = "trixie" ]; then \
        NETCAT_PKG="netcat-openbsd"; \
    else \
        NETCAT_PKG="netcat-traditional"; \
    fi; \
    BACKPORTS_SUITE="${DEBIAN_VERSION}-backports"; \
    sed -e "s|@URI@|${BACKPORTS_URI}|g" -e "s|@SUITE@|${BACKPORTS_SUITE}|g" /tmp/backports.sources.in > "/etc/apt/sources.list.d/${BACKPORTS_SUITE}.sources"; \
    sed -e "s|@SUITE@|${BACKPORTS_SUITE}|g" /tmp/backports.pref.in > /etc/apt/preferences.d/backports; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash-completion \
        ca-certificates \
        curl \
        dnsutils \
        fuse3 \
        git \
        gnupg \
        gzip \
        htop \
        httpie \
        iputils-ping \
        jq \
        less \
        lsb-release \
        man-db \
        mc \
        "${NETCAT_PKG}" \
        python3-venv \
        sqlite3 \
        sshfs \
        tar \
        tree \
        unzip \
        vim \
        wget \
        xz-utils \
    ; \
    echo "user_allow_other" >> /etc/fuse.conf; \
    rm -rf /var/lib/apt/lists/*

# Modern tools installation
RUN set -euo pipefail; \
    get_latest_release() { \
        local repo="$1"; \
        curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
            | jq -r '.tag_name // empty' \
            | sed 's/^v//' \
            | tr -d '\r\n'; \
    }; \
    resolve_version() { \
        local requested="$1"; \
        local repo="$2"; \
        if [ -n "${requested}" ] && [ "${requested}" != "latest" ]; then \
            echo "${requested}"; \
        else \
            get_latest_release "${repo}"; \
        fi; \
    }; \
    B2_VER="$(resolve_version "${B2_VERSION}" "Backblaze/B2_Command_Line_Tool")"; \
    BAT_VER="$(resolve_version "${BAT_VERSION}" "sharkdp/bat")"; \
    FD_VER="$(resolve_version "${FD_VERSION}" "sharkdp/fd")"; \
    RIPGREP_VER="$(resolve_version "${RIPGREP_VERSION}" "BurntSushi/ripgrep")"; \
    SHELLCHECK_VER="$(resolve_version "${SHELLCHECK_VERSION}" "koalaman/shellcheck")"; \
    FZF_VER="$(resolve_version "${FZF_VERSION}" "junegunn/fzf")"; \
    YQ_VER="$(resolve_version "${YQ_VERSION}" "mikefarah/yq")"; \
    CONSUL_VER="$(resolve_version "${CONSUL_VERSION}" "hashicorp/consul")"; \
    VAULT_VER="$(resolve_version "${VAULT_VERSION}" "hashicorp/vault")"; \
    echo "B2_VER=${B2_VER}" > /tmp/tool-versions.env; \
    echo "BAT_VER=${BAT_VER}" >> /tmp/tool-versions.env; \
    echo "FD_VER=${FD_VER}" >> /tmp/tool-versions.env; \
    echo "RIPGREP_VER=${RIPGREP_VER}" >> /tmp/tool-versions.env; \
    echo "SHELLCHECK_VER=${SHELLCHECK_VER}" >> /tmp/tool-versions.env; \
    echo "FZF_VER=${FZF_VER}" >> /tmp/tool-versions.env; \
    echo "YQ_VER=${YQ_VER}" >> /tmp/tool-versions.env; \
    echo "CONSUL_VER=${CONSUL_VER}" >> /tmp/tool-versions.env; \
    echo "VAULT_VER=${VAULT_VER}" >> /tmp/tool-versions.env

RUN set -euo pipefail; \
    . /tmp/tool-versions.env; \
    curl -fsSL "https://github.com/Backblaze/B2_Command_Line_Tool/releases/download/v${B2_VER}/b2-linux" -o /tmp/b2-linux; \
    curl -fsSL "https://github.com/Backblaze/B2_Command_Line_Tool/releases/download/v${B2_VER}/b2-linux_hashes.txt" -o /tmp/b2-linux_hashes.txt; \
    EXPECTED_SHA256=$(grep "^sha256" /tmp/b2-linux_hashes.txt | awk '{print $2}'); \
    echo "${EXPECTED_SHA256}  /tmp/b2-linux" | sha256sum -c -; \
    install -m 755 /tmp/b2-linux /usr/local/bin/b2; \
    rm -f /tmp/b2-linux /tmp/b2-linux_hashes.txt

RUN set -euo pipefail; \
    . /tmp/tool-versions.env; \
    curl -fsSL "https://github.com/sharkdp/bat/releases/download/v${BAT_VER}/bat_${BAT_VER}_amd64.deb" -o /tmp/bat.deb; \
    curl -fsSL "https://github.com/sharkdp/fd/releases/download/v${FD_VER}/fd_${FD_VER}_amd64.deb" -o /tmp/fd.deb; \
    curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VER}/ripgrep_${RIPGREP_VER}-1_amd64.deb" -o /tmp/ripgrep.deb; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/bat.deb /tmp/fd.deb /tmp/ripgrep.deb; \
    rm -f /tmp/bat.deb /tmp/fd.deb /tmp/ripgrep.deb; \
    rm -rf /var/lib/apt/lists/*

RUN set -euo pipefail; \
    . /tmp/tool-versions.env; \
    curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VER}/shellcheck-v${SHELLCHECK_VER}.linux.x86_64.tar.xz" -o /tmp/shellcheck.tar.xz; \
    tar -xf /tmp/shellcheck.tar.xz -C /tmp; \
    install -m 755 "/tmp/shellcheck-v${SHELLCHECK_VER}/shellcheck" /usr/local/bin/shellcheck; \
    rm -rf /tmp/shellcheck.tar.xz "/tmp/shellcheck-v${SHELLCHECK_VER}"

RUN set -euo pipefail; \
    . /tmp/tool-versions.env; \
    curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VER}/fzf-${FZF_VER}-linux_amd64.tar.gz" -o /tmp/fzf.tar.gz; \
    tar -xzf /tmp/fzf.tar.gz -C /tmp; \
    install -m 755 /tmp/fzf /usr/local/bin/fzf; \
    rm -rf /tmp/fzf.tar.gz /tmp/fzf

RUN set -euo pipefail; \
    . /tmp/tool-versions.env; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VER}/yq_linux_amd64" -o /usr/local/bin/yq; \
    chmod 755 /usr/local/bin/yq

RUN set -euo pipefail; \
    . /tmp/tool-versions.env; \
    curl -fsSL "https://releases.hashicorp.com/consul/${CONSUL_VER}/consul_${CONSUL_VER}_SHA256SUMS" -o /tmp/consul_SHA256SUMS; \
    curl -fsSL "https://releases.hashicorp.com/consul/${CONSUL_VER}/consul_${CONSUL_VER}_linux_amd64.zip" -o "/tmp/consul_${CONSUL_VER}_linux_amd64.zip"; \
    cd /tmp && grep "consul_${CONSUL_VER}_linux_amd64.zip" consul_SHA256SUMS | sha256sum -c -; \
    unzip "/tmp/consul_${CONSUL_VER}_linux_amd64.zip" -d /usr/local/bin; \
    chmod 755 /usr/local/bin/consul; \
    rm -f "/tmp/consul_${CONSUL_VER}_linux_amd64.zip" /tmp/consul_SHA256SUMS

RUN set -euo pipefail; \
    . /tmp/tool-versions.env; \
    curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VER}/vault_${VAULT_VER}_SHA256SUMS" -o /tmp/vault_SHA256SUMS; \
    curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VER}/vault_${VAULT_VER}_linux_amd64.zip" -o "/tmp/vault_${VAULT_VER}_linux_amd64.zip"; \
    cd /tmp && grep "vault_${VAULT_VER}_linux_amd64.zip" vault_SHA256SUMS | sha256sum -c -; \
    unzip -q -o "/tmp/vault_${VAULT_VER}_linux_amd64.zip" -d /tmp/vault-extract; \
    install -m 755 /tmp/vault-extract/vault /usr/local/bin/vault; \
    rm -rf "/tmp/vault_${VAULT_VER}_linux_amd64.zip" /tmp/vault-extract /tmp/vault_SHA256SUMS /tmp/tool-versions.env

# AWS CLI v2 (latest) - no checksum file available
RUN set -euo pipefail; \
    if [ "${AWSCLI_VERSION}" = "latest" ]; then \
        AWSCLI_ZIP_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"; \
    else \
        AWSCLI_ZIP_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip"; \
    fi; \
    curl -fsSL "${AWSCLI_ZIP_URL}" -o /tmp/awscliv2.zip; \
    unzip -q /tmp/awscliv2.zip -d /tmp/awscli; \
    /tmp/awscli/aws/install -i /usr/local/aws -b /usr/local/bin; \
    rm -rf /tmp/awscliv2.zip /tmp/awscli

# Latest PostgreSQL and Redis clients (override versions via build args)
RUN set -euo pipefail; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list; \
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /etc/apt/keyrings/redis-archive-keyring.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list; \
    apt-get update; \
    if [ -n "${POSTGRESQL_CLIENT_VERSION}" ] && [ "${POSTGRESQL_CLIENT_VERSION}" != "latest" ]; then \
        apt-get install -y --no-install-recommends "postgresql-client-${POSTGRESQL_CLIENT_VERSION}"; \
    else \
        apt-get install -y --no-install-recommends postgresql-client; \
    fi; \
    if [ -n "${REDIS_TOOLS_VERSION}" ] && [ "${REDIS_TOOLS_VERSION}" != "latest" ]; then \
        apt-get install -y --no-install-recommends "redis-tools=${REDIS_TOOLS_VERSION}"; \
    else \
        apt-get install -y --no-install-recommends redis-tools; \
    fi; \
    rm -rf /var/lib/apt/lists/*

USER vscode
RUN set -euo pipefail; \
    python3 -m venv /home/vscode/.venv; \
    /home/vscode/.venv/bin/python -m pip install --upgrade pip setuptools wheel --disable-pip-version-check --quiet; \
    /home/vscode/.venv/bin/python -m pip install --disable-pip-version-check --quiet \
        boto3 \
        PyYAML \
        aiohttp \
        asyncpg \
        black \
        click \
        coverage \
        hvac \
        ipython \
        isort \
        jinja2 \
        mypy \
        pydantic \
        pydantic-settings \
        pytest \
        pytest-asyncio \
        pytest-cov \
        redis \
        requests \
        rich \
        structlog \
        tomli_w

ENV VIRTUAL_ENV="/home/vscode/.venv"
ENV PATH="/home/vscode/.venv/bin:${PATH}"

USER root

# Manifest of included tool versions
RUN set -euo pipefail; \
    manifest="/home/vscode/devcontainer-manifest.txt"; \
    if [ "${DEBIAN_VERSION}" = "trixie" ]; then \
        NETCAT_PKG="netcat-openbsd"; \
    else \
        NETCAT_PKG="netcat-traditional"; \
    fi; \
    { \
        echo "image.debian=${DEBIAN_VERSION}"; \
        echo "image.python=$(python3 --version 2>&1)"; \
        echo "tool.b2=$(b2 --version 2>&1 | head -1)"; \
        echo "tool.bat=$(bat --version 2>&1 | head -1)"; \
        echo "tool.fd=$(fd --version 2>&1 | head -1)"; \
        echo "tool.ripgrep=$(rg --version 2>&1 | head -1)"; \
        echo "tool.shellcheck=$(shellcheck --version 2>&1 | head -1)"; \
        echo "tool.fzf=$(fzf --version 2>&1)"; \
        echo "tool.yq=$(yq --version 2>&1)"; \
        echo "tool.consul=$(consul version 2>&1 | head -1)"; \
        echo "tool.vault=$(vault version 2>&1 | head -1)"; \
        echo "tool.psql=$(psql --version 2>&1)"; \
        echo "tool.redis_cli=$(redis-cli --version 2>&1)"; \
        echo "tool.aws=$(aws --version 2>&1)"; \
        echo "pip.packages:"; \
        /home/vscode/.venv/bin/pip list --format=freeze; \
        echo "dpkg.versions:"; \
        dpkg-query -W -f='${Package}=${Version}\n' \
            bash-completion ca-certificates curl dnsutils fuse3 git gnupg gzip htop httpie iputils-ping jq less lsb-release man-db mc \
            "${NETCAT_PKG}" python3-venv sqlite3 sshfs tar tree unzip vim wget xz-utils \
                postgresql-client redis-tools; \
            } > "${manifest}"; \
            chown vscode:vscode "${manifest}"
