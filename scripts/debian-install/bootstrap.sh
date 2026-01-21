#!/bin/bash
# System Setup Bootstrap for Debian
# Full system initialization including swap, user config, benchmarking
# Note: netcup init-script payloads can be size-limited (~10KB). If you need that,
# use a tiny shim that curls this full bootstrap script.
# Usage: curl -fsSL URL | bash
# Or: curl -fsSL URL | SWAP_ARCH=3 RUN_GEEKBENCH=yes bash

set -euo pipefail

# Debug mode
DEBUG_MODE="${DEBUG_MODE:-no}"
if [ "$DEBUG_MODE" = "yes" ]; then
    set -x
fi
# Force Python unbuffered output for benchmark
export PYTHONUNBUFFERED=1

# Configuration
REPO_URL="${REPO_URL:-https://github.com/volkb79/vbpub.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
CLONE_DIR="${CLONE_DIR:-/opt/vbpub}"
SCRIPT_DIR="${CLONE_DIR}/scripts/debian-install"
LOG_DIR="${LOG_DIR:-/var/log/debian-install}"
RUN_TS="${RUN_TS:-$(date +%Y%m%d-%H%M%S)}"
# If LOG_FILE is pre-set by the caller, honor it. Otherwise we will select a
# stage-specific log file in main() once BOOTSTRAP_STAGE is resolved.
LOG_FILE="${LOG_FILE:-}"
CALLER_LOG_FILE="${LOG_FILE}"

# Stage control
# - stage1: minimal setup + schedule stage2, then reboot
# - stage2: heavy tasks (benchmarks/swap/geekbench/etc) and resume-safe
# - full: legacy one-shot behavior (runs everything now)
BOOTSTRAP_STAGE="${BOOTSTRAP_STAGE:-auto}"  # auto, stage1, stage2, full
AUTO_REBOOT_AFTER_STAGE1="${AUTO_REBOOT_AFTER_STAGE1:-auto}"  # auto, yes, no
NEVER_REBOOT="${NEVER_REBOOT:-no}"  # yes/no (force: never reboot automatically)

STATE_DIR="${STATE_DIR:-/var/lib/vbpub/bootstrap}"
ENV_FILE="${ENV_FILE:-/etc/vbpub/bootstrap.env}"

# Swap configuration (NEW NAMING CONVENTION)
# RAM-based swap
SWAP_RAM_SOLUTION="${SWAP_RAM_SOLUTION:-auto}"  # zram, zswap, none (auto-detected if not set)
SWAP_RAM_TOTAL_GB="${SWAP_RAM_TOTAL_GB:-auto}"  # RAM dedicated to compression (auto = calculated)
ZRAM_COMPRESSOR="${ZRAM_COMPRESSOR:-zstd}"  # lz4, zstd, lzo-rle
ZRAM_ALLOCATOR="${ZRAM_ALLOCATOR:-zsmalloc}"  # zsmalloc, z3fold, zbud
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"  # Priority for ZRAM (higher = preferred)
ZSWAP_COMPRESSOR="${ZSWAP_COMPRESSOR:-zstd}"  # lz4, zstd, lzo-rle
ZSWAP_ZPOOL="${ZSWAP_ZPOOL:-zbud}"  # zbud (most reliable), z3fold, zsmalloc

# Disk-based swap
SWAP_BACKING_TYPE="${SWAP_BACKING_TYPE:-auto}"  # files_in_root, partitions_swap, partitions_zvol, files_in_partitions, none (auto-detected if not set)
SWAP_DISK_TOTAL_GB="${SWAP_DISK_TOTAL_GB:-auto}"  # Total disk-based swap (auto = calculated)
SWAP_STRIPE_WIDTH="${SWAP_STRIPE_WIDTH:-auto}"  # Number of parallel swap devices (for I/O striping)
SWAP_PARTITION_COUNT="${SWAP_PARTITION_COUNT:-16}"  # Pre-create this many swap partitions (benchmark chooses how many to activate)
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"  # Priority for disk swap (lower than RAM)
EXTEND_ROOT="${EXTEND_ROOT:-yes}"

# ZFS-specific
ZFS_POOL="${ZFS_POOL:-tank}"

# Bootstrap options
RUN_USER_CONFIG="${RUN_USER_CONFIG:-yes}"
RUN_APT_CONFIG="${RUN_APT_CONFIG:-yes}"
RUN_JOURNALD_CONFIG="${RUN_JOURNALD_CONFIG:-yes}"
RUN_DOCKER_INSTALL="${RUN_DOCKER_INSTALL:-yes}"
RUN_SSH_SETUP="${RUN_SSH_SETUP:-yes}"  # Generate SSH key for root and send via Telegram
RUN_GEEKBENCH="${RUN_GEEKBENCH:-yes}"
RUN_BENCHMARKS="${RUN_BENCHMARKS:-yes}"
BENCHMARK_DURATION="${BENCHMARK_DURATION:-5}"  # Duration in seconds for each benchmark test
SEND_SYSINFO="${SEND_SYSINFO:-yes}"

# Advanced benchmark options (Phase 2-4) - NOW ENABLED BY DEFAULT
CREATE_SWAP_PARTITIONS="${CREATE_SWAP_PARTITIONS:-yes}"  # Create optimized partitions from matrix test
TEST_ZSWAP_LATENCY="${TEST_ZSWAP_LATENCY:-yes}"  # Run ZSWAP latency tests with real partitions
PRESERVE_ROOT_SIZE_GB="${PRESERVE_ROOT_SIZE_GB:-10}"  # Minimum root partition size (for shrink scenario)

# Stage1 pre-shrink (offline ext*) before stage2 benchmarks/partitioning
PRE_SHRINK_ONLY="${PRE_SHRINK_ONLY:-auto}"  # auto/yes/no
PRE_SHRINK_ROOT_EXTRA_GB="${PRE_SHRINK_ROOT_EXTRA_GB:-10}"

# Telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_THREAD_ID="${TELEGRAM_THREAD_ID:-}"
# If TELEGRAM_CHAT_ID points to a forum-enabled supergroup, we can create a topic
# at install start and send all messages into that topic thread.
# Values: auto|yes|no
TELEGRAM_USE_FORUM_TOPIC="${TELEGRAM_USE_FORUM_TOPIC:-auto}"
TELEGRAM_TOPIC_PREFIX="${TELEGRAM_TOPIC_PREFIX:-vbpub install}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_debug() { 
    if [ "$DEBUG_MODE" = "yes" ]; then
        echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
    fi
}

# Temporarily disable bash xtrace to avoid leaking secrets (tokens, IDs) into logs.
# Use like:
#   local had_xtrace; had_xtrace=$(xtrace_pause)
#   ... sensitive checks ...
#   xtrace_resume "$had_xtrace"
xtrace_pause() {
    if [[ $- == *x* ]]; then
        set +x
        echo 1
    else
        echo 0
    fi
}

xtrace_resume() {
    local had_xtrace="${1:-0}"
    if [ "$had_xtrace" = "1" ]; then
        set -x
    fi
}

select_log_file_for_stage() {
    # Only keep LOG_FILE fixed if the caller explicitly provided it.
    if [ -n "${CALLER_LOG_FILE:-}" ]; then
        return 0
    fi

    local stage="$1"
    case "$stage" in
        stage1) LOG_FILE="${LOG_DIR}/stage1-${RUN_TS}.log" ;;
        stage2) LOG_FILE="${LOG_DIR}/stage2-${RUN_TS}.log" ;;
        full)   LOG_FILE="${LOG_DIR}/full-${RUN_TS}.log" ;;
        *)      LOG_FILE="${LOG_DIR}/bootstrap-${RUN_TS}.log" ;;
    esac
}

is_cloud_init_context() {
    # Best-effort detection. Netcup "customScript" is not always cloud-init, but on NoCloud it is.
    [ -d /run/cloud-init ] || [ -f /var/lib/cloud/instance/boot-finished ]
}

state_has() { [ -f "${STATE_DIR}/$1" ]; }
state_set() {
    mkdir -p "$STATE_DIR"
    : > "${STATE_DIR}/$1"
}

should_reboot_after_stage1() {
    if [ "$NEVER_REBOOT" = "yes" ]; then
        return 1
    fi
    case "$AUTO_REBOOT_AFTER_STAGE1" in
        yes) return 0 ;;
        no) return 1 ;;
        auto)
            if is_cloud_init_context; then
                return 0
            fi
            return 1
            ;;
        *)
            log_warn "Unknown AUTO_REBOOT_AFTER_STAGE1=$AUTO_REBOOT_AFTER_STAGE1 (treating as auto)"
            if is_cloud_init_context; then
                return 0
            fi
            return 1
            ;;
    esac
}

stage1_reboot() {
    sync || true

    if [ "$NEVER_REBOOT" = "yes" ]; then
        log_warn "NEVER_REBOOT=yes; refusing to reboot automatically"
        return 0
    fi

    # IMPORTANT: When running under cloud-init/customScript, rebooting inline can
    # strand the provider task (e.g. Netcup CloudinitWait). Instead, schedule a
    # delayed reboot so this script can exit cleanly and cloud-init can report
    # completion.
    if is_cloud_init_context; then
        local delay_seconds="${STAGE1_REBOOT_DELAY_SECONDS:-60}"
        log_warn "Cloud-init context detected; scheduling reboot in ${delay_seconds}s (to allow cloud-init to finish)"
        ( sleep "$delay_seconds"; systemctl reboot || reboot ) >/dev/null 2>&1 &
        return 0
    fi

    log_warn "Rebooting now"
    systemctl reboot || reboot
}

stage2_reboot() {
    sync || true

    if [ "$NEVER_REBOOT" = "yes" ]; then
        log_warn "NEVER_REBOOT=yes; refusing to reboot automatically"
        return 0
    fi

    # Stage2 can also be invoked in cloud-init-ish contexts (e.g. provider tasks).
    # Use the same delayed reboot pattern for safety.
    if is_cloud_init_context; then
        local delay_seconds="${STAGE2_REBOOT_DELAY_SECONDS:-60}"
        log_warn "Cloud-init context detected; scheduling reboot in ${delay_seconds}s"
        ( sleep "$delay_seconds"; systemctl reboot || reboot ) >/dev/null 2>&1 &
        return 0
    fi

    log_warn "Rebooting now (stage2)"
    systemctl reboot || reboot
}

log_root_layout() {
    local root_part
    root_part=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
    if [ -z "$root_part" ]; then
        log_warn "Could not determine root partition"
        return 0
    fi

    log_info "Root mount source: $root_part"
    df -h / 2>/dev/null | tee -a "$LOG_FILE" || true

    local root_disk
    root_disk=$(lsblk -no PKNAME "$root_part" 2>/dev/null | head -1 || true)
    if [ -n "$root_disk" ] && [ -b "/dev/$root_disk" ]; then
        log_info "Root disk layout: /dev/$root_disk"
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "/dev/$root_disk" 2>/dev/null | tee -a "$LOG_FILE" || true
    else
        log_warn "Could not determine root disk for $root_part"
    fi
}

# Helper function to run commands with comprehensive logging
run_logged() {
    local cmd="$1"
    local description="${2:-Running command}"
    
    log_debug "==> $description"
    log_debug "Command: $cmd"
    
    local output
    local exit_code
    
    if output=$($cmd 2>&1); then
        exit_code=$?
    else
        exit_code=$?
    fi
    
    if [ "$DEBUG_MODE" = "yes" ]; then
        echo "$output" | tee -a "$LOG_FILE"
    else
        echo "$output" >> "$LOG_FILE"
    fi
    
    log_debug "Exit code: $exit_code"
    
    return $exit_code
}

# Test Telegram connectivity
test_telegram() {
    log_info "Testing Telegram connectivity..."

    local had_xtrace
    had_xtrace=$(xtrace_pause)
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        xtrace_resume "$had_xtrace"
        log_warn "Telegram not configured (TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set)"
        return 1
    fi
    xtrace_resume "$had_xtrace"
    
    if [ ! -f "${SCRIPT_DIR}/telegram_client.py" ]; then
        log_error "telegram_client.py not found at ${SCRIPT_DIR}/telegram_client.py"
        return 1
    fi
    
    log_info "Testing bot connection..."
    if python3 "${SCRIPT_DIR}/telegram_client.py" --test 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ Telegram test successful!"
        return 0
    else
        log_error "✗ Telegram test failed"
        return 1
    fi
}

# Helper function to send telegram messages using telegram_client.py
tg_send() {
    local msg="$1"

    local had_xtrace
    had_xtrace=$(xtrace_pause)
    [ -z "$TELEGRAM_BOT_TOKEN" ] && { xtrace_resume "$had_xtrace"; return 0; }
    [ -z "$TELEGRAM_CHAT_ID" ] && { xtrace_resume "$had_xtrace"; return 0; }
    # Only try to send if the script exists (repo must be cloned first)
    [ ! -f "${SCRIPT_DIR}/telegram_client.py" ] && { xtrace_resume "$had_xtrace"; return 0; }
    xtrace_resume "$had_xtrace"
    python3 "${SCRIPT_DIR}/telegram_client.py" --send "$msg" 2>/dev/null || true
}

tg_send_system_summary_once() {
    # Send the initial system summary into the install thread (if enabled)
    # and only once per install run (persisted across stage1->stage2).
    if state_has system_summary_sent; then
        return 0
    fi
    if [ -z "${SYSTEM_SUMMARY:-}" ]; then
        return 0
    fi
    tg_send "$SYSTEM_SUMMARY"
    state_set system_summary_sent
}

tg_init_thread() {
    local had_xtrace
    had_xtrace=$(xtrace_pause)

    case "${TELEGRAM_USE_FORUM_TOPIC}" in
        no) xtrace_resume "$had_xtrace"; return 0 ;;
        yes|auto) : ;;
        *) xtrace_resume "$had_xtrace"; return 0 ;;
    esac

    # Only initialize once.
    if [ -n "${TELEGRAM_THREAD_ID:-}" ]; then
        export TELEGRAM_THREAD_ID
        xtrace_resume "$had_xtrace"
        return 0
    fi

    # Only try if telegram is configured and telegram_client exists.
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        xtrace_resume "$had_xtrace"
        return 0
    fi
    if [ ! -f "${SCRIPT_DIR}/telegram_client.py" ]; then
        xtrace_resume "$had_xtrace"
        return 0
    fi

    # Ensure dependencies are present (telegram_client.py needs requests).
    if ! python3 -c 'import requests' >/dev/null 2>&1; then
        xtrace_resume "$had_xtrace"
        return 0
    fi
    xtrace_resume "$had_xtrace"

    local fqdn ip date_str prefix title
    fqdn="$(hostname -f 2>/dev/null || hostname)"
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [ -z "${ip:-}" ] && ip="unknown"
    date_str="$(date +%Y-%m-%d)"
    prefix="${TELEGRAM_TOPIC_PREFIX:-Install}"
    title="${prefix} ${fqdn} (${ip}) ${date_str}"

    # createForumTopic works only on forum-enabled supergroups. If it fails and
    # we're in 'auto' mode, we just fall back to non-threaded messaging.
    local thread_id
    thread_id=$(python3 "${SCRIPT_DIR}/telegram_client.py" --create-topic "$title" 2>>"$LOG_FILE" || true)
    if [[ "${thread_id:-}" =~ ^[0-9]+$ ]]; then
        TELEGRAM_THREAD_ID="$thread_id"
        export TELEGRAM_THREAD_ID
        mkdir -p "$STATE_DIR" || true
        printf '%s\n' "$TELEGRAM_THREAD_ID" >"$STATE_DIR/telegram_thread_id" 2>/dev/null || true
        log_info "Telegram forum topic initialized (message_thread_id=$TELEGRAM_THREAD_ID)"
    else
        if [ "${TELEGRAM_USE_FORUM_TOPIC}" = "yes" ]; then
            log_warn "TELEGRAM_USE_FORUM_TOPIC=yes but forum topic creation failed (chat may not be a forum-enabled supergroup)."
        fi
    fi
}

# Helper function to send files via telegram
tg_send_file() {
    local file="$1"
    local caption="${2:-}"

    local had_xtrace
    had_xtrace=$(xtrace_pause)
    [ -z "$TELEGRAM_BOT_TOKEN" ] && { xtrace_resume "$had_xtrace"; return 0; }
    [ -z "$TELEGRAM_CHAT_ID" ] && { xtrace_resume "$had_xtrace"; return 0; }
    # Only try to send if the script exists (repo must be cloned first)
    [ ! -f "${SCRIPT_DIR}/telegram_client.py" ] && { xtrace_resume "$had_xtrace"; return 0; }
    xtrace_resume "$had_xtrace"
    if [ -n "$caption" ]; then
        python3 "${SCRIPT_DIR}/telegram_client.py" --file "$file" --caption "$caption" 2>/dev/null || true
    else
        python3 "${SCRIPT_DIR}/telegram_client.py" --file "$file" 2>/dev/null || true
    fi
}

# Collect system summary using unified system_info.py module
get_system_summary() {
    # Use system_info.py for consistent system information collection
    # This replaces the old bash implementation and uses the same module as sysinfo-notify.py
    if [ -f "${SCRIPT_DIR}/system_info.py" ]; then
        echo ""
        python3 "${SCRIPT_DIR}/system_info.py" --format text 2>> "$LOG_FILE" || {
            # Fallback to basic info if system_info.py fails
            echo "System: $(hostname -f 2>/dev/null || hostname) ($(hostname -I 2>/dev/null | awk '{print $1}'))"
            echo "RAM: $(free -h | awk '/^Mem:/{print $2}'), Cores: $(nproc)"
            echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
        }
    else
        # Minimal fallback if system_info.py doesn't exist yet
        echo "System: $(hostname) - $(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
}

# Install essential packages early
apt_install_packages() {
    local description="$1"; shift
    local packages="$*"

    export DEBIAN_FRONTEND=noninteractive
    log_info "$description"
    apt-get update -qq
    # shellcheck disable=SC2086
    apt-get install -y -qq $packages || log_warn "Package install had issues (continuing)"
}

install_stage1_packages() {
    log_info "==> Installing stage1 packages (minimal)"
    local base_packages="ca-certificates gnupg lsb-release curl wget git jq bash-completion python3 python3-requests"
    local network_packages="iproute2 iputils-ping dnsutils"
    apt_install_packages "Installing base packages..." "$base_packages $network_packages"
    log_info "✓ Stage1 packages installed"
}

install_stage2_packages() {
    log_info "==> Installing stage2 packages (tools + benchmarks)"

    local core_packages="vim less man-db python3-pip"
    local additional_packages="ripgrep fd-find tree fzf httpie netcat-traditional"
    local system_packages="fio sysstat python3-matplotlib python3-pil"

    apt_install_packages "Installing core + benchmark packages..." "$core_packages $system_packages"
    apt_install_packages "Installing additional tools..." "$additional_packages"

    # Install yq (go-based, not the old Python version)
    if ! command -v yq >/dev/null 2>&1; then
        log_info "Installing yq (go-based) from GitHub..."
        if wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
            log_info "✓ yq installed"
        else
            log_warn "Failed to install yq"
        fi
    fi

    # Install tldr with proper setup (optional)
    if ! command -v tldr >/dev/null 2>&1; then
        log_info "Installing tldr (Python-based) system-wide..."
        if pip3 install --system tldr 2>/dev/null || pip3 install tldr; then
            log_info "Updating tldr cache..."
            tldr --update 2>/dev/null || log_warn "tldr installed but cache update failed"
        else
            log_warn "Failed to install tldr"
        fi
    else
        log_info "Updating tldr cache..."
        tldr --update 2>/dev/null || log_warn "Failed to update tldr cache"
    fi

    log_info "✓ Stage2 packages installed"
}

install_stage2_systemd_unit() {
    log_info "==> Installing stage2 systemd unit"

    mkdir -p /etc/vbpub
    mkdir -p /usr/local/sbin

    # Persist key variables for stage2. Keep it shell-safe and minimal.
    cat > "$ENV_FILE" <<EOF
REPO_URL="${REPO_URL}"
REPO_BRANCH="${REPO_BRANCH}"
CLONE_DIR="${CLONE_DIR}"
LOG_DIR="${LOG_DIR}"
DEBUG_MODE="${DEBUG_MODE}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
TELEGRAM_THREAD_ID="${TELEGRAM_THREAD_ID}"
TELEGRAM_USE_FORUM_TOPIC="${TELEGRAM_USE_FORUM_TOPIC}"
TELEGRAM_TOPIC_PREFIX="${TELEGRAM_TOPIC_PREFIX}"

# Stage control
AUTO_REBOOT_AFTER_STAGE1="${AUTO_REBOOT_AFTER_STAGE1}"
NEVER_REBOOT="${NEVER_REBOOT}"

# Preserve bootstrap choices
RUN_USER_CONFIG="${RUN_USER_CONFIG}"
RUN_APT_CONFIG="${RUN_APT_CONFIG}"
RUN_JOURNALD_CONFIG="${RUN_JOURNALD_CONFIG}"
RUN_DOCKER_INSTALL="${RUN_DOCKER_INSTALL}"
RUN_SSH_SETUP="${RUN_SSH_SETUP}"
RUN_GEEKBENCH="${RUN_GEEKBENCH}"
RUN_BENCHMARKS="${RUN_BENCHMARKS}"
BENCHMARK_DURATION="${BENCHMARK_DURATION}"

# Optional validation (default enabled; runs after Geekbench in stage2)
RUN_ZSWAP_VALIDATION="${RUN_ZSWAP_VALIDATION:-yes}"
ZSWAP_VALIDATE_HOLD_SECONDS="${ZSWAP_VALIDATE_HOLD_SECONDS:-90}"
ZSWAP_VALIDATE_PRESSURE_MB="${ZSWAP_VALIDATE_PRESSURE_MB:-auto}"

CREATE_SWAP_PARTITIONS="${CREATE_SWAP_PARTITIONS}"
TEST_ZSWAP_LATENCY="${TEST_ZSWAP_LATENCY}"
PRESERVE_ROOT_SIZE_GB="${PRESERVE_ROOT_SIZE_GB}"

# Swap parameters
SWAP_RAM_SOLUTION="${SWAP_RAM_SOLUTION}"
SWAP_RAM_TOTAL_GB="${SWAP_RAM_TOTAL_GB}"
ZRAM_COMPRESSOR="${ZRAM_COMPRESSOR}"
ZRAM_ALLOCATOR="${ZRAM_ALLOCATOR}"
ZRAM_PRIORITY="${ZRAM_PRIORITY}"
ZSWAP_COMPRESSOR="${ZSWAP_COMPRESSOR}"
ZSWAP_ZPOOL="${ZSWAP_ZPOOL}"
SWAP_BACKING_TYPE="${SWAP_BACKING_TYPE}"
SWAP_DISK_TOTAL_GB="${SWAP_DISK_TOTAL_GB}"
SWAP_STRIPE_WIDTH="${SWAP_STRIPE_WIDTH}"
SWAP_PARTITION_COUNT="${SWAP_PARTITION_COUNT}"
SWAP_PRIORITY="${SWAP_PRIORITY}"
EXTEND_ROOT="${EXTEND_ROOT}"
ZFS_POOL="${ZFS_POOL}"
EOF

    cat > /usr/local/sbin/vbpub-bootstrap-stage2 <<'EOF'
#!/bin/bash
set -euo pipefail

ENV_FILE=/etc/vbpub/bootstrap.env
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

REPO_URL="${REPO_URL:-https://github.com/volkb79/vbpub.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
CLONE_DIR="${CLONE_DIR:-/opt/vbpub}"

export REPO_URL REPO_BRANCH CLONE_DIR

if ! command -v git >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq git ca-certificates curl
fi

if [ -d "$CLONE_DIR/.git" ]; then
  cd "$CLONE_DIR" && git fetch origin && git reset --hard "origin/$REPO_BRANCH"
else
  rm -rf "$CLONE_DIR" && git clone -b "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR"
fi

exec "$CLONE_DIR/scripts/debian-install/bootstrap.sh" --stage=stage2
EOF

    chmod +x /usr/local/sbin/vbpub-bootstrap-stage2

    cat > /etc/systemd/system/vbpub-bootstrap-stage2.service <<EOF
[Unit]
Description=vbpub bootstrap (stage2)
After=network-online.target
Wants=network-online.target
ConditionPathExists=${STATE_DIR}/stage1_done
ConditionPathExists=!${STATE_DIR}/stage2_done

[Service]
Type=oneshot
EnvironmentFile=-${ENV_FILE}
ExecStart=/usr/local/sbin/vbpub-bootstrap-stage2
TimeoutStartSec=infinity
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable vbpub-bootstrap-stage2.service 2>/dev/null || true
    log_info "✓ Stage2 service installed and enabled"
}

parse_stage_from_args() {
    local stage_arg=""
    for arg in "$@"; do
        case "$arg" in
            --stage=*) stage_arg="${arg#--stage=}" ;;
        esac
    done

    if [ -n "$stage_arg" ]; then
        BOOTSTRAP_STAGE="$stage_arg"
    fi

    case "$BOOTSTRAP_STAGE" in
        auto)
            # In cloud-init contexts, default to a fast stage1 + reboot.
            if is_cloud_init_context; then
                BOOTSTRAP_STAGE="stage1"
            else
                BOOTSTRAP_STAGE="full"
            fi
            ;;
        1|stage1) BOOTSTRAP_STAGE="stage1" ;;
        2|stage2) BOOTSTRAP_STAGE="stage2" ;;
        full|stage1|stage2) : ;;
        *)
            log_warn "Unknown BOOTSTRAP_STAGE=$BOOTSTRAP_STAGE; using full"
            BOOTSTRAP_STAGE="full"
            ;;
    esac
}

run_stage1() {
    if state_has stage1_done; then
        log_info "Stage1 already done; skipping"
        return 0
    fi

    log_info "==> Running stage1 (minimal cloud-init friendly)"

    # Configure APT repositories BEFORE installing packages
    if [ "$RUN_APT_CONFIG" = "yes" ]; then
        log_info "==> Configuring APT repositories (before package installation)"
        if ./configure-apt.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ APT configured"
        else
            log_warn "APT config had issues (non-critical, continuing)"
        fi
    else
        log_info "==> APT configuration skipped (RUN_APT_CONFIG=$RUN_APT_CONFIG)"
    fi

    install_stage1_packages

    # Optional: Create a forum topic for this install run so all notifications are grouped.
    tg_init_thread

    # Now that the thread exists (and requests is installed), send the initial summary into it.
    tg_send_system_summary_once

    # User configuration (aliases etc)
    if [ "$RUN_USER_CONFIG" = "yes" ]; then
        log_info "==> Configuring users (stage1)"
        ./configure-users.sh 2>&1 | tee -a "$LOG_FILE" || log_warn "User config had issues"
    fi

    # Journald config
    if [ "$RUN_JOURNALD_CONFIG" = "yes" ]; then
        log_info "==> Configuring journald (stage1)"
        ./configure-journald.sh 2>&1 | tee -a "$LOG_FILE" || log_warn "Journald config had issues"
    fi

    # Docker in stage1 (allowed; keeps base system ready ASAP)
    if [ "$RUN_DOCKER_INSTALL" = "yes" ]; then
        log_info "==> Installing Docker (stage1)"
        ./install-docker.sh 2>&1 | tee -a "$LOG_FILE" || log_warn "Docker installation had issues"
    fi

    # Schedule offline pre-shrink so the stage1->stage2 reboot can apply it.
    local do_presh
    do_presh="$PRE_SHRINK_ONLY"
    if [ "$do_presh" = "auto" ]; then
        do_presh=yes
    fi
    if [ "$do_presh" = "yes" ]; then
        log_info "==> Scheduling offline pre-shrink (stage1)"
        export PRESERVE_ROOT_SIZE_GB PRE_SHRINK_ROOT_EXTRA_GB
        set +e
        ./create-swap-partitions.sh --pre-shrink-only 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -eq 42 ]; then
            log_warn "Offline pre-shrink scheduled via initramfs for next reboot"
            tg_send "🪚 Stage1: offline pre-shrink scheduled (filesystem resize will run early at next boot before stage2)."
        elif [ "$rc" -eq 0 ]; then
            log_info "No pre-shrink needed"
            tg_send "✅ Stage1: no offline pre-shrink needed."
        else
            log_warn "Pre-shrink scheduling failed (rc=$rc); continuing without it"
            tg_send "⚠️ Stage1 warning: pre-shrink scheduling failed (rc=$rc). Stage2 may still run, but partition creation could require a later reboot."
        fi
    else
        log_info "==> Pre-shrink skipped (PRE_SHRINK_ONLY=$PRE_SHRINK_ONLY)"
    fi

    install_stage2_systemd_unit
    state_set stage1_done

    tg_send "✅ vbpub stage1 complete on $(hostname -f 2>/dev/null || hostname). Stage2 will run automatically after reboot via systemd."

    if should_reboot_after_stage1; then
        log_warn "Reboot required to start stage2..."
        stage1_reboot
    else
        log_info "Stage1 complete. Reboot is required for stage2 (AUTO_REBOOT_AFTER_STAGE1=$AUTO_REBOOT_AFTER_STAGE1)."
    fi
}

run_stage2() {
    if state_has stage2_done; then
        log_info "Stage2 already done; skipping"
        return 0
    fi

    log_info "==> Running stage2 (long-running / resume-safe)"
    tg_init_thread
    tg_send_system_summary_once
    tg_send "▶️ vbpub stage2 started on $(hostname -f 2>/dev/null || hostname). Running: packages → swap partition prep → benchmarks → final swap setup (then optional docker/ssh/geekbench)."

    install_stage2_packages

    # Export all config (new naming convention)
    export SWAP_RAM_SOLUTION SWAP_RAM_TOTAL_GB
    export ZRAM_COMPRESSOR ZRAM_ALLOCATOR ZRAM_PRIORITY
    export ZSWAP_COMPRESSOR ZSWAP_ZPOOL
    export SWAP_DISK_TOTAL_GB SWAP_BACKING_TYPE SWAP_STRIPE_WIDTH
    export SWAP_PARTITION_COUNT
    export SWAP_PRIORITY EXTEND_ROOT
    export ZFS_POOL
    export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_THREAD_ID LOG_FILE
    export DEBUG_MODE
    export PRESERVE_ROOT_SIZE_GB

    # Partition creation (may schedule offline resize + require reboot)
    # New flow: pre-create a fixed set of swap partitions first, then benchmark those partitions.
    if [ "$CREATE_SWAP_PARTITIONS" = "yes" ] && ! state_has partitions_done && ! state_has partitions_failed; then
        log_info "==> Creating swap partitions (stage2; no-activate; count=${SWAP_PARTITION_COUNT})"
        tg_send "🧩 Stage2: creating ${SWAP_PARTITION_COUNT} GPT swap partitions (no activate yet) so benchmarks can test real devices."
        log_root_layout

        set +e
        ./create-swap-partitions.sh --no-activate --swap-partition-count="$SWAP_PARTITION_COUNT" 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
        set -e

        if [ "$rc" -eq 0 ]; then
            log_info "✓ Swap partitions created successfully"
            state_set partitions_done
            log_root_layout
        elif [ "$rc" -eq 42 ]; then
            log_warn "Offline ext* resize required; reboot is required to continue stage2"
            state_set partitions_reboot_scheduled
            # NEVER_REBOOT is primarily for stage1/cloud-init safety. Stage2 may reboot when needed
            # unless explicitly disabled via NEVER_REBOOT_STAGE2=yes.
            if [ "${NEVER_REBOOT_STAGE2:-no}" = "yes" ]; then
                tg_send "⚠️ Stage2 paused: an offline filesystem resize was scheduled (pre-shrink/repartition). Reboot is required to continue, but NEVER_REBOOT_STAGE2=yes so reboot is NOT automatic."
                log_warn "NEVER_REBOOT_STAGE2=yes; not rebooting automatically. Reboot manually when ready."
            else
                tg_send "🔁 Stage2 paused: an offline filesystem resize was scheduled (pre-shrink/repartition). Rebooting to continue stage2 automatically."
                stage2_reboot
            fi
            return 0
        else
            log_error "✗ Swap partition creation failed (rc=$rc)"
            state_set partitions_failed
            tg_send "❌ Stage2 warning: swap partition creation failed (rc=$rc). Continuing without pre-created partitions; benchmarks may fall back to auto settings."
        fi
    fi

    # Benchmarks
    if [ "$RUN_BENCHMARKS" = "yes" ] && ! state_has benchmarks_done; then
        log_info "==> Running system benchmarks (stage2)"
        tg_send "🧪 Stage2: running swap/IO benchmarks (fio + memory tests). This will choose swap settings based on measured results."
        BENCHMARK_OUTPUT="/tmp/benchmark-results-$(date +%Y%m%d-%H%M%S).json"
        BENCHMARK_CONFIG="/tmp/benchmark-optimal-config.sh"

        # If swap partitions exist, let benchmark.py use them to recommend SWAP_STRIPE_WIDTH.
        local swap_parts_arg=""
        if [[ "${SWAP_PARTITION_COUNT:-}" =~ ^[0-9]+$ ]] && [ "${SWAP_PARTITION_COUNT:-0}" -gt 0 ]; then
            swap_parts_arg="--swap-partitions-max ${SWAP_PARTITION_COUNT}"
        fi

        if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            BENCHMARK_ARGS="--test-all --duration $BENCHMARK_DURATION $swap_parts_arg --output $BENCHMARK_OUTPUT --shell-config $BENCHMARK_CONFIG --telegram"
        else
            BENCHMARK_ARGS="--test-all --duration $BENCHMARK_DURATION $swap_parts_arg --output $BENCHMARK_OUTPUT --shell-config $BENCHMARK_CONFIG"
        fi

        if ./benchmark.py $BENCHMARK_ARGS 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Benchmarks complete"
            export SWAP_BENCHMARK_CONFIG="$BENCHMARK_CONFIG"
            state_set benchmarks_done
            tg_send "✅ Stage2: benchmarks complete. Applying recommended swap configuration now."

            # Source the exported config so stage2 can act on decisions immediately.
            # shellcheck disable=SC1090
            if [ -f "$BENCHMARK_CONFIG" ]; then
                . "$BENCHMARK_CONFIG" || true
            fi
        else
            log_warn "Benchmarks had issues (non-critical, continuing)"
            state_set benchmarks_failed
            tg_send "⚠️ Stage2 warning: benchmarks had issues. Continuing with swap setup using defaults/auto where needed."
        fi
    else
        log_info "==> Benchmarks skipped (RUN_BENCHMARKS=$RUN_BENCHMARKS or already done)"
    fi

    # Repartition swap space to the benchmark-chosen stripe width.
    # Goal: end state has exactly N swap partitions (not N-of-M enabled).
    if state_has benchmarks_done && state_has partitions_done && ! state_has partitions_final_done && ! state_has partitions_final_failed; then
        if [[ "${SWAP_STRIPE_WIDTH:-}" =~ ^[0-9]+$ ]] && [ "${SWAP_STRIPE_WIDTH:-0}" -gt 0 ]; then
            if [ "${SWAP_STRIPE_WIDTH}" -ne "${SWAP_PARTITION_COUNT}" ]; then
                log_info "==> Repartitioning swap space to optimal stripe width (N=${SWAP_STRIPE_WIDTH})"
                tg_send "🧩 Stage2: repartitioning swap space to ${SWAP_STRIPE_WIDTH} swap partitions (benchmark-chosen stripe width)."

                set +e
                ./create-swap-partitions.sh --no-activate --swap-partition-count="$SWAP_STRIPE_WIDTH" 2>&1 | tee -a "$LOG_FILE"
                rc=${PIPESTATUS[0]}
                set -e

                if [ "$rc" -eq 0 ]; then
                    log_info "✓ Swap partitions repartitioned to ${SWAP_STRIPE_WIDTH}"
                    state_set partitions_final_done
                elif [ "$rc" -eq 42 ]; then
                    log_warn "Offline ext* resize required after repartition; reboot is required to continue stage2"
                    state_set partitions_final_reboot_scheduled
                    if [ "${NEVER_REBOOT_STAGE2:-no}" = "yes" ]; then
                        tg_send "⚠️ Stage2 paused: offline filesystem resize scheduled while finalizing swap partitions. Reboot is required to continue, but NEVER_REBOOT_STAGE2=yes so reboot is NOT automatic."
                        log_warn "NEVER_REBOOT_STAGE2=yes; not rebooting automatically. Reboot manually when ready."
                    else
                        tg_send "🔁 Stage2 paused: offline filesystem resize scheduled while finalizing swap partitions. Rebooting to continue stage2 automatically."
                        stage2_reboot
                    fi
                    return 0
                else
                    log_error "✗ Final swap repartition failed (rc=$rc)"
                    state_set partitions_final_failed
                    tg_send "❌ Stage2 warning: failed to finalize swap partitions to ${SWAP_STRIPE_WIDTH} (rc=$rc). Continuing with existing partitions."
                fi
            else
                state_set partitions_final_done
            fi
        else
            log_info "==> SWAP_STRIPE_WIDTH not measured; skipping swap repartition finalization"
            state_set partitions_final_done
        fi
    fi

    # Swap setup
    if ! state_has swap_done; then
        log_info "==> Configuring swap (stage2)"
        if ./setup-swap.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Swap configured"
            state_set swap_done
            if command -v swapon >/dev/null 2>&1; then
                local swap_state
                swap_state=$(swapon --show=NAME,TYPE,SIZE,USED,PRIO --noheadings 2>/dev/null | head -50 || true)
                if [ -n "$swap_state" ]; then
                    tg_send "Stage2: swap active (name type size used prio):\n${swap_state}"
                else
                    tg_send "Stage2: swap configured and active."
                fi
            else
                tg_send "Stage2: swap configured."
            fi
        else
            log_error "✗ Swap config failed"
            exit 1
        fi
    fi

    # Docker installation
    if [ "$RUN_DOCKER_INSTALL" = "yes" ] && ! state_has docker_done; then
        log_info "==> Installing Docker (stage2)"
        ./install-docker.sh 2>&1 | tee -a "$LOG_FILE" || log_warn "Docker installation had issues"
        state_set docker_done
    fi

    # SSH key generation and setup
    if [ "$RUN_SSH_SETUP" = "yes" ] && ! state_has ssh_done; then
        log_info "==> Generating SSH key for root user (stage2)"
        export HOME="/root"
        export NONINTERACTIVE="yes"

        if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            python3 ../ssh-keygen-deploy.py --user root --send-private --non-interactive 2>&1 | tee -a "$LOG_FILE" || log_warn "SSH key generation had issues"
        else
            python3 ../ssh-keygen-deploy.py --user root --non-interactive 2>&1 | tee -a "$LOG_FILE" || log_warn "SSH key generation had issues"
        fi
        state_set ssh_done
    fi

    # Geekbench
    if [ "$RUN_GEEKBENCH" = "yes" ] && ! state_has geekbench_done; then
        log_info "==> Running Geekbench (stage2)"
        set +e
        if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            ./sysinfo-notify.py --geekbench --notify 2>&1 | tee -a "$LOG_FILE"
        else
            ./sysinfo-notify.py --geekbench-only 2>&1 | tee -a "$LOG_FILE"
        fi
        set -e
        state_set geekbench_done
    fi

    # Optional: ZSWAP validation (best-effort)
    if [ "${RUN_ZSWAP_VALIDATION:-no}" = "yes" ] && ! state_has zswap_validation_done; then
        if [ -r /sys/module/zswap/parameters/enabled ] && grep -Eq '^(Y|1)$' /sys/module/zswap/parameters/enabled 2>/dev/null; then
            log_info "==> Validating ZSWAP behavior (stage2)"
            tg_send "Stage2: running ZSWAP validation (memory pressure + zswap stats)."

            chmod +x ./zswap-validate.sh 2>/dev/null || true
            report_file="${LOG_DIR}/zswap-validation-${RUN_TS}.txt"
            set +e
            zswap_report=$(./zswap-validate.sh 2>&1 | tee -a "$LOG_FILE" | tee "$report_file")
            rc=${PIPESTATUS[0]}
            set -e

            if [ "$rc" -eq 0 ]; then
                tg_send "Stage2: ZSWAP validation complete. Summary:\n$(printf '%s' "$zswap_report" | head -c 3000)"
                if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -f "$report_file" ]; then
                    tg_send_file "$report_file" "ZSWAP validation report"
                fi
                state_set zswap_validation_done
            else
                tg_send "⚠️ Stage2: ZSWAP validation encountered issues (rc=$rc). See log for details."
                if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -f "$report_file" ]; then
                    tg_send_file "$report_file" "ZSWAP validation report (failed)"
                fi
                state_set zswap_validation_done
            fi
        else
            log_info "==> ZSWAP validation skipped (zswap not enabled)"
            state_set zswap_validation_done
        fi
    fi

    # Summary + completion messages
    print_bootstrap_summary
    state_set stage2_done

    tg_send "🎉 vbpub stage2 complete on $(hostname -f 2>/dev/null || hostname)."
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -f "$LOG_FILE" ]; then
        tg_send_file "$LOG_FILE" "📋 Stage2 Complete - Full Log"
    fi
}

print_bootstrap_summary() {
    log_info ""
    log_info "=========================================="
    log_info "  BOOTSTRAP COMPLETE - SUMMARY"
    log_info "=========================================="
    log_info ""
    
    # System info
    local hostname=$(hostname)
    local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    log_info "✓ System configured: ${hostname} (${ip})"
    log_info "✓ RAM: ${ram_gb}GB"
    
    # Swap configuration
    if [ -n "${SWAP_RAM_SOLUTION:-}" ]; then
        log_info "✓ Swap: ${SWAP_RAM_SOLUTION}"
    fi
    
    # Docker version
    if command -v docker >/dev/null 2>&1; then
        local docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
        log_info "✓ Docker: ${docker_version}"
    fi
    
    log_info ""
    log_info "Key Reports:"
    
    # Find most recent reports
    local benchmark_summary=$(ls -t /var/log/debian-install/benchmark-summary-*.txt 2>/dev/null | head -1)
    local swap_config=$(ls -t /var/log/debian-install/swap-config-decisions-*.txt 2>/dev/null | head -1)
    
    if [ -n "$benchmark_summary" ] && [ -f "$benchmark_summary" ]; then
        log_info "  • Benchmark: $benchmark_summary"
    fi
    
    if [ -n "$swap_config" ] && [ -f "$swap_config" ]; then
        log_info "  • Swap Config: $swap_config"
    fi
    
    log_info "  • Full Log: $LOG_FILE"
    log_info ""
    log_info "Next Steps:"
    log_info "  1. Review benchmark report for performance insights"
    log_info "  2. Reboot to apply all changes"
    log_info "  3. Monitor: ./swap-monitor.sh (if available)"
    log_info ""
}

main() {
    mkdir -p "$LOG_DIR"
    # Ensure we always have a log file even before stage parsing.
    if [ -z "$LOG_FILE" ]; then
        LOG_FILE="${LOG_DIR}/bootstrap-${RUN_TS}.log"
    fi
    log_info "Debian System Setup Bootstrap"
    log_info "Log: $LOG_FILE"

    parse_stage_from_args "$@"

    # Switch to stage-specific log file for the bulk of the run.
    select_log_file_for_stage "$BOOTSTRAP_STAGE"
    log_info "Stage: $BOOTSTRAP_STAGE"
    log_info "Stage log: $LOG_FILE"

    # Send system summary
    log_info "==> Collecting system summary"
    SYSTEM_SUMMARY=$(get_system_summary)
    echo "$SYSTEM_SUMMARY" | tee -a "$LOG_FILE"
    # NOTE: We deliberately do NOT Telegram-send the system summary yet.
    # In stage1, python3-requests (used by telegram_client.py) is installed later.
    # We send the summary after tg_init_thread() so it lands in the install topic.
    
    if [ "$EUID" -ne 0 ]; then log_error "Must run as root"; exit 1; fi
    
    # Install git first
    if ! command -v git >/dev/null 2>&1; then
        log_info "Installing git..."
        apt-get update -qq && apt-get install -y -qq git
    fi
    
    # Clone/update repo
    if [ -d "$CLONE_DIR/.git" ]; then
        log_info "Updating repository..."
        cd "$CLONE_DIR" && git fetch origin && git reset --hard "origin/$REPO_BRANCH"
    else
        log_info "Cloning repository..."
        rm -rf "$CLONE_DIR" && git clone -b "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR"
    fi
    
    # Make scripts executable
    chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py 2>/dev/null || true
    cd "$SCRIPT_DIR"
    
    # Test Telegram connectivity if configured
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        test_telegram || log_warn "Telegram test failed, but continuing with bootstrap"
        
        # Send BEFORE system info
        log_info "==> Sending system info (BEFORE setup)"
        ./sysinfo-notify.py --notify --caption "📊 System Info (BEFORE setup)" 2>&1 | tee -a "$LOG_FILE" || true
    fi
    
    # Staged execution
    case "$BOOTSTRAP_STAGE" in
        stage1)
            run_stage1
            return 0
            ;;
        stage2)
            run_stage2
            return 0
            ;;
        full)
            log_info "==> Running full (one-shot) bootstrap"
            ;;
    esac

    # Legacy full run continues below

    # Configure APT repositories BEFORE installing packages
    if [ "$RUN_APT_CONFIG" = "yes" ]; then
        log_info "==> Configuring APT repositories (before package installation)"
        if ./configure-apt.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ APT configured"
        else
            log_warn "APT config had issues (non-critical, continuing)"
        fi
    else
        log_info "==> APT configuration skipped (RUN_APT_CONFIG=$RUN_APT_CONFIG)"
    fi

    # Install packages for full bootstrap
    install_stage1_packages
    install_stage2_packages
    
    # Export all config (new naming convention)
    export SWAP_RAM_SOLUTION SWAP_RAM_TOTAL_GB
    export ZRAM_COMPRESSOR ZRAM_ALLOCATOR ZRAM_PRIORITY
    export ZSWAP_COMPRESSOR ZSWAP_ZPOOL
    export SWAP_DISK_TOTAL_GB SWAP_BACKING_TYPE SWAP_STRIPE_WIDTH
    export SWAP_PRIORITY EXTEND_ROOT
    export ZFS_POOL
    export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID LOG_FILE
    export DEBUG_MODE

    
    # Run benchmarks BEFORE swap setup for smart auto-configuration
    if [ "$RUN_BENCHMARKS" = "yes" ]; then
        # New flow: create swap partitions first so benchmarks can run on real devices.
        if [ "$CREATE_SWAP_PARTITIONS" = "yes" ]; then
            log_info "==> Creating swap partitions (no-activate; count=${SWAP_PARTITION_COUNT})"
            log_info "This will modify disk partition table (root may be resized)"

            log_info "==> Root layout BEFORE repartitioning"
            log_root_layout

            export PRESERVE_ROOT_SIZE_GB SWAP_PARTITION_COUNT
            set +e
            ./create-swap-partitions.sh --no-activate --swap-partition-count="$SWAP_PARTITION_COUNT" 2>&1 | tee -a "$LOG_FILE"
            rc=${PIPESTATUS[0]}
            set -e

            if [ "$rc" -eq 0 ]; then
                log_info "✓ Swap partitions created successfully"
                log_info "==> Root layout AFTER repartitioning"
                log_root_layout
            elif [ "$rc" -eq 42 ]; then
                log_warn "Swap partitioning requires offline ext* resize. Scheduled initramfs job for next reboot."
                log_warn "Continuing bootstrap without forcing a reboot."
            else
                log_error "✗ Swap partition creation failed"
                log_warn "Continuing without repartitioned swap"
            fi
        fi

        log_info "==> Running system benchmarks (for smart swap auto-configuration)"
        BENCHMARK_DURATION="${BENCHMARK_DURATION:-5}"  # Default to 5 seconds per test
        BENCHMARK_OUTPUT="/tmp/benchmark-results-$(date +%Y%m%d-%H%M%S).json"
        BENCHMARK_CONFIG="/tmp/benchmark-optimal-config.sh"
        
        # Run benchmark with telegram notification if configured, and export optimal config
        swap_parts_arg=""
        if [[ "${SWAP_PARTITION_COUNT:-}" =~ ^[0-9]+$ ]] && [ "${SWAP_PARTITION_COUNT:-0}" -gt 0 ]; then
            swap_parts_arg="--swap-partitions-max ${SWAP_PARTITION_COUNT}"
        fi
        if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            BENCHMARK_ARGS="--test-all --duration $BENCHMARK_DURATION $swap_parts_arg --output $BENCHMARK_OUTPUT --shell-config $BENCHMARK_CONFIG --telegram"
        else
            BENCHMARK_ARGS="--test-all --duration $BENCHMARK_DURATION $swap_parts_arg --output $BENCHMARK_OUTPUT --shell-config $BENCHMARK_CONFIG"
        fi
        
        if ./benchmark.py $BENCHMARK_ARGS 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Benchmarks complete"
            # Benchmark results are automatically sent via Telegram if configured
            # Optimal configuration exported to $BENCHMARK_CONFIG for use by setup-swap.sh
            export SWAP_BENCHMARK_CONFIG="$BENCHMARK_CONFIG"
            
            # Optional: Run ZSWAP latency tests with real partitions
            if [ "$TEST_ZSWAP_LATENCY" = "yes" ]; then
                log_info "==> Testing ZSWAP latency with real disk backing"
                if ./benchmark.py --test-zswap-latency 2>&1 | tee -a "$LOG_FILE"; then
                    log_info "✓ ZSWAP latency test complete"
                else
                    log_warn "ZSWAP latency test had issues (non-critical)"
                fi
            else
                log_info "==> ZSWAP latency test skipped (TEST_ZSWAP_LATENCY=$TEST_ZSWAP_LATENCY)"
            fi
        else
            log_warn "Benchmarks had issues (non-critical, continuing)"
        fi
    else
        log_info "==> Benchmarks skipped (RUN_BENCHMARKS=$RUN_BENCHMARKS)"
    fi

    # Benchmark results will be used by setup-swap.sh to optimize swap configuration
    # (compressor, allocator, stripe width, page-cluster)
    
    # Run swap setup
    log_info "==> Configuring swap"
    if ./setup-swap.sh 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ Swap configured"
    else
        log_error "✗ Swap config failed"
        exit 1
    fi
    
    # Sync log file (removed telegram_send for swap configuration)
    sync
    
    # User configuration
    if [ "$RUN_USER_CONFIG" = "yes" ]; then
        log_info "==> Configuring users"
        if ./configure-users.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Users configured"
        else
            log_warn "User config had issues"
        fi
    else
        log_info "==> User configuration skipped (RUN_USER_CONFIG=$RUN_USER_CONFIG)"
    fi
    
    # Journald configuration
    if [ "$RUN_JOURNALD_CONFIG" = "yes" ]; then
        log_info "==> Configuring journald"
        if ./configure-journald.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Journald configured"
        else
            log_warn "Journald config had issues"
        fi
    else
        log_info "==> Journald configuration skipped (RUN_JOURNALD_CONFIG=$RUN_JOURNALD_CONFIG)"
    fi
    
    # Docker installation
    if [ "$RUN_DOCKER_INSTALL" = "yes" ]; then
        log_info "==> Installing Docker"
        if ./install-docker.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Docker installed"
        else
            log_warn "Docker installation had issues"
        fi
    else
        log_info "==> Docker installation skipped (RUN_DOCKER_INSTALL=$RUN_DOCKER_INSTALL)"
    fi
    
    # SSH key generation and setup
    if [ "$RUN_SSH_SETUP" = "yes" ]; then
        log_info "==> Generating SSH key for root user"

        # Use the unified Python tool in server mode (local install + optional Telegram delivery)
        export HOME="/root"
        export NONINTERACTIVE="yes"

        if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            log_info "Telegram configured - will send private key via Telegram"
            if python3 ../ssh-keygen-deploy.py --user root --send-private --non-interactive 2>&1 | tee -a "$LOG_FILE"; then
                log_info "✓ SSH key generated and private key sent via Telegram"
            else
                log_warn "SSH key generation had issues"
            fi
        else
            log_warn "Telegram not configured - SSH key will be generated but not sent"
            if python3 ../ssh-keygen-deploy.py --user root --non-interactive 2>&1 | tee -a "$LOG_FILE"; then
                log_info "✓ SSH key generated (no Telegram delivery)"
            else
                log_warn "SSH key generation had issues"
            fi
        fi
    else
        log_info "==> SSH key generation skipped (RUN_SSH_SETUP=$RUN_SSH_SETUP)"
    fi
    
    # Geekbench (MOVED HERE - after swap configuration to avoid influencing benchmark results)
    if [ "$RUN_GEEKBENCH" = "yes" ]; then
        log_info "==> Running Geekbench (5-10 min)"
        GEEKBENCH_START=$(date +%s)
        
        # Add --notify flag if Telegram is configured
        GEEKBENCH_ARGS="--geekbench-only"
        if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            GEEKBENCH_ARGS="--geekbench --notify"
        fi
        
        # Run geekbench and capture exit code properly
        set +e  # Temporarily disable exit on error
        ./sysinfo-notify.py $GEEKBENCH_ARGS 2>&1 | tee -a "$LOG_FILE"
        GEEKBENCH_EXIT_CODE=${PIPESTATUS[0]}
        set -e  # Re-enable exit on error
        
        GEEKBENCH_END=$(date +%s)
        GEEKBENCH_DURATION=$((GEEKBENCH_END - GEEKBENCH_START))
        
        if [ "$GEEKBENCH_EXIT_CODE" -eq 0 ]; then
            log_info "✓ Geekbench complete (took ${GEEKBENCH_DURATION}s)"
        else
            log_error "✗ Geekbench failed (exit code: $GEEKBENCH_EXIT_CODE, took ${GEEKBENCH_DURATION}s)"
            log_error "Check logs for details: $LOG_FILE"
            
            # Send failure notification via Telegram
            if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
                GEEKBENCH_ERROR_MSG="❌ <b>Geekbench Failed</b>

Exit code: ${GEEKBENCH_EXIT_CODE}
Duration: ${GEEKBENCH_DURATION}s
Log: ${LOG_FILE}

Possible causes:
• Download failure (network/URL issue)
• Extraction failure (corrupt archive)
• Runtime failure (insufficient resources)
• Timeout (benchmark took >15 min)

Check the log file for detailed error messages."
                tg_send "$GEEKBENCH_ERROR_MSG"
            fi
        fi
    else
        log_info "==> Geekbench skipped (RUN_GEEKBENCH=$RUN_GEEKBENCH)"
    fi
    
    # Print bootstrap summary
    print_bootstrap_summary
    
    log_info "🎉 System setup complete!"
    log_info "Log: $LOG_FILE"
    
    # Send comprehensive completion message with log file as attachment
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -f "$LOG_FILE" ]; then
        log_info "Sending final summary and log file..."
        sync
        
        # Build comprehensive completion message
        local completion_msg="🎉 <b>Bootstrap Complete</b>

<b>📊 Final System Status:</b>"
        
        # Add system summary
        local hostname=$(hostname -f 2>/dev/null || hostname)
        local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
        completion_msg="${completion_msg}
• System: ${hostname} (${ip})
• RAM: ${ram_gb}GB"
        
        # Add swap configuration
        if [ -n "${SWAP_RAM_SOLUTION:-}" ] && [ "${SWAP_RAM_SOLUTION}" != "auto" ]; then
            completion_msg="${completion_msg}
• Swap: ${SWAP_RAM_SOLUTION}"
        fi
        
        # Add Docker if installed
        if command -v docker >/dev/null 2>&1; then
            local docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
            completion_msg="${completion_msg}
• Docker: ${docker_version}"
        fi
        
        completion_msg="${completion_msg}

<b>📝 Log File:</b> See attachment for full details
<b>⏱️ Completed:</b> $(date '+%Y-%m-%d %H:%M:%S')"
        
        # Send message with log as attachment
        tg_send "$completion_msg"
        tg_send_file "$LOG_FILE" "📋 Bootstrap Complete - Full Installation Log"
    fi
}

main "$@"
