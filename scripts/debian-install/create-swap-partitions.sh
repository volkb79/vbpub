#!/bin/bash
# Create optimal swap partitions based on benchmark matrix test results
# Layout policy:
# - Treat root partition start as fixed
# - Root partition MAY be shrunk to reserve swap-at-end (accepted risk)
# - Rewrite everything after root to a deterministic plan of equal-sized swap partitions
# - Optionally extend root so swap sits at disk end
# Always uses sfdisk dump-modify-write pattern

set -euo pipefail

# Configuration
BENCHMARK_RESULTS="${BENCHMARK_RESULTS:-/var/log/debian-install/benchmark-results-*.json}"
LOG_FILE="${LOG_FILE:-/var/log/debian-install/partition-creation.log}"
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"
PRESERVE_ROOT_SIZE_GB="${PRESERVE_ROOT_SIZE_GB:-10}"
ALLOW_ROOT_SHRINK="${ALLOW_ROOT_SHRINK:-yes}"
OFFLINE_SHRINK_EXIT_CODE=42

# Stage1 pre-shrink support (shrink root offline now; decide swap later)
PRE_SHRINK_ONLY="${PRE_SHRINK_ONLY:-no}"  # yes/no
PRE_SHRINK_ROOT_EXTRA_GB="${PRE_SHRINK_ROOT_EXTRA_GB:-10}"  # keep used + extra GB

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $*" | tee -a "$LOG_FILE"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

log_step "Creating Swap Partitions from Benchmark Results"

for arg in "$@"; do
    case "$arg" in
        --pre-shrink-only)
            PRE_SHRINK_ONLY=yes
            ;;
    esac
done

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required but not installed"
    log_info "Install with: apt-get install -y jq"
    exit 1
fi

select_benchmark_results_file() {
    local candidate
    local value
    local chosen=""

    # Walk newest -> oldest and pick the newest file that contains the matrix/optimal output.
    while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        [ -f "$candidate" ] || continue

        # Prefer the concurrency-derived optimal device count.
        value=$(jq -r '.matrix.optimal.best_combined.concurrency // .matrix.optimal.best_read.concurrency // .matrix.optimal.best_write.concurrency // empty' "$candidate" 2>/dev/null || true)
        if [[ -n "$value" && "$value" != "null" && "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]]; then
            chosen="$candidate"
            echo "$chosen"
            return 0
        fi

        # Fallback: some result formats export a recommended stripe width.
        value=$(jq -r '.matrix.optimal.recommended_swap_stripe_width // empty' "$candidate" 2>/dev/null || true)
        if [[ -n "$value" && "$value" != "null" && "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]]; then
            chosen="$candidate"
            echo "$chosen"
            return 0
        fi
    done < <(ls -t $BENCHMARK_RESULTS 2>/dev/null || true)

    return 1
}

OPTIMAL_DEVICES=1
if [ "$PRE_SHRINK_ONLY" != "yes" ]; then
    # Find the most recent *complete* benchmark results file (newest that contains matrix.optimal).
    RESULTS_FILE="$(select_benchmark_results_file || true)"
    if [ -z "$RESULTS_FILE" ] || [ ! -f "$RESULTS_FILE" ]; then
        log_error "No usable benchmark results found at: $BENCHMARK_RESULTS"
        log_error "Need one file with: .matrix.optimal.best_*\.concurrency or .matrix.optimal.recommended_swap_stripe_width"
        log_info "Run: sudo ./benchmark.py --test-all"
        exit 1
    fi

    log_info "Using benchmark results: $RESULTS_FILE"

    # Extract benchmark-optimal stripe width / device count.
    OPTIMAL_DEVICES=$(jq -r '.matrix.optimal.best_combined.concurrency // .matrix.optimal.best_read.concurrency // .matrix.optimal.best_write.concurrency // empty' "$RESULTS_FILE" 2>/dev/null || true)
    if [[ -z "$OPTIMAL_DEVICES" || "$OPTIMAL_DEVICES" = "null" ]]; then
        OPTIMAL_DEVICES=$(jq -r '.matrix.optimal.recommended_swap_stripe_width // empty' "$RESULTS_FILE" 2>/dev/null || true)
    fi

    if [[ -z "$OPTIMAL_DEVICES" || "$OPTIMAL_DEVICES" = "null" ]]; then
        log_error "No benchmark-optimal swap stripe width found in benchmark results"
        log_error "Expected one of: .matrix.optimal.best_*\.concurrency or .matrix.optimal.recommended_swap_stripe_width"
        log_error "Inspect: jq '.matrix.optimal' $RESULTS_FILE"
        exit 1
    fi

    if [[ ! "$OPTIMAL_DEVICES" =~ ^[0-9]+$ ]] || [ "$OPTIMAL_DEVICES" -lt 1 ]; then
        log_error "Invalid benchmark-optimal device count: '$OPTIMAL_DEVICES'"
        log_error "Inspect: jq '.matrix.optimal' $RESULTS_FILE"
        exit 1
    fi

    log_info "Benchmark-optimal swap device count: $OPTIMAL_DEVICES"
else
    log_step "Pre-shrink-only mode: reserving disk tail space; swap layout will be decided later"
fi

# Get system specifications
RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
log_info "MemTotal: ${RAM_TOTAL_KB} kB"

# Convert to GiB for policy decisions.
RAM_GB=$(((RAM_TOTAL_KB + 524287) / 1048576))

TOTAL_SWAP_GB=$((RAM_GB * 2))  # default sizing policy
if [ "$PRE_SHRINK_ONLY" != "yes" ]; then
    log_info "System RAM: ${RAM_GB}GB"
    log_info "Total swap needed: ${TOTAL_SWAP_GB}GB"
fi

SWAP_DEVICES="$OPTIMAL_DEVICES"
TOTAL_SWAP_TARGET_MIB=$((TOTAL_SWAP_GB * 1024))

# Guard rails for tiny systems / weird benchmark output.
if [ "$SWAP_DEVICES" -lt 1 ]; then
    SWAP_DEVICES=1
fi

# Ensure we can allocate at least 1MiB per device.
if [ "$TOTAL_SWAP_TARGET_MIB" -lt "$SWAP_DEVICES" ]; then
    SWAP_DEVICES="$TOTAL_SWAP_TARGET_MIB"
    [ "$SWAP_DEVICES" -lt 1 ] && SWAP_DEVICES=1
fi

PER_DEVICE_MIB=$((TOTAL_SWAP_TARGET_MIB / SWAP_DEVICES))
if [ "$PER_DEVICE_MIB" -lt 1 ]; then
    PER_DEVICE_MIB=1
fi

TOTAL_SWAP_USED_MIB=$((PER_DEVICE_MIB * SWAP_DEVICES))

if [ "$PRE_SHRINK_ONLY" != "yes" ]; then
    log_info "Swap stripe width chosen: ${SWAP_DEVICES} (benchmark optimal: ${OPTIMAL_DEVICES})"
    log_info "Initial per-device swap target: ${PER_DEVICE_MIB}MiB (may be capped by available disk tail space)"
    log_info "Initial total swap target: ${TOTAL_SWAP_TARGET_MIB}MiB; initial total swap used: ${TOTAL_SWAP_USED_MIB}MiB"
fi

# Detect root partition and disk
ROOT_PARTITION=$(findmnt -n -o SOURCE / 2>/dev/null)
if [ -z "$ROOT_PARTITION" ]; then
    log_error "Failed to detect root partition"
    exit 1
fi

log_info "Root partition: $ROOT_PARTITION"

# Extract disk device from partition
# Handle various naming schemes: vda3 -> vda, nvme0n1p3 -> nvme0n1, sda3 -> sda
if [[ "$ROOT_PARTITION" =~ nvme ]]; then
    # nvme: /dev/nvme0n1p3 -> nvme0n1
    ROOT_DISK=$(echo "$ROOT_PARTITION" | sed -E 's|/dev/||; s|p[0-9]+$||')
    ROOT_PART_NUM=$(echo "$ROOT_PARTITION" | grep -oE '[0-9]+$')
elif [[ "$ROOT_PARTITION" =~ /dev/mapper ]]; then
    log_error "LVM detected: $ROOT_PARTITION"
    log_error "This script requires direct partition access, not LVM"
    log_error "LVM setup should use lvresize/lvcreate commands"
    exit 1
else
    # Regular: /dev/vda3 -> vda, /dev/sda3 -> sda
    ROOT_DISK=$(echo "$ROOT_PARTITION" | sed -E 's|/dev/||; s|[0-9]+$||')
    ROOT_PART_NUM=$(echo "$ROOT_PARTITION" | grep -oE '[0-9]+$')
fi

log_info "Root disk: /dev/$ROOT_DISK"
log_info "Root partition number: $ROOT_PART_NUM"

# Verify disk exists
if [ ! -b "/dev/$ROOT_DISK" ]; then
    log_error "Disk /dev/$ROOT_DISK not found"
    exit 1
fi

# Get disk size and partition info using sfdisk
log_info "Analyzing disk layout..."

# Get disk size in sectors
DISK_SIZE_SECTORS=$(sfdisk -l "/dev/$ROOT_DISK" 2>/dev/null | grep "^Disk /dev/$ROOT_DISK:" | awk '{print $(NF-1)}')
DISK_SIZE_GB=$((DISK_SIZE_SECTORS / 2048 / 1024))

log_info "Disk capacity: ${DISK_SIZE_GB}GB (${DISK_SIZE_SECTORS} sectors)"

# Get root partition info
ROOT_START=$(sfdisk -d "/dev/$ROOT_DISK" 2>/dev/null | grep "^$ROOT_PARTITION" | sed -E 's/.*start= *([0-9]+).*/\1/')
ROOT_SIZE=$(sfdisk -d "/dev/$ROOT_DISK" 2>/dev/null | grep "^$ROOT_PARTITION" | sed -E 's/.*size= *([0-9]+).*/\1/')

if [ -z "$ROOT_START" ] || [ -z "$ROOT_SIZE" ]; then
    log_error "Failed to extract root partition information"
    exit 1
fi

ROOT_END=$((ROOT_START + ROOT_SIZE))
ROOT_SIZE_GB=$((ROOT_SIZE / 2048 / 1024))

log_info "Root partition: start=${ROOT_START}, size=${ROOT_SIZE} sectors (${ROOT_SIZE_GB}GB)"

# Calculate free space after root partition
FREE_SECTORS=$((DISK_SIZE_SECTORS - ROOT_END))
FREE_GB=$((FREE_SECTORS / 2048 / 1024))

log_info "Free space after root: ${FREE_GB}GB (${FREE_SECTORS} sectors)"

# Get filesystem type
FS_TYPE=$(findmnt -n -o FSTYPE /)
log_info "Root filesystem: $FS_TYPE"

# If this script is re-run, swap may already be active on partitions we are about to recreate.
# Turn it off early to reduce partition-table update friction.
log_step "Disabling active swap (rerun safety)..."
swapoff -a 2>/dev/null || true

align_up_2048() {
    local v="$1"
    echo $(( (v + 2047) / 2048 * 2048 ))
}

align_down_2048() {
    local v="$1"
    echo $(( (v / 2048) * 2048 ))
}

require_mib_aligned() {
    local what="$1"
    local sectors="$2"
    if [ $((sectors % 2048)) -ne 0 ]; then
        log_error "$what is not 1MiB-aligned (sectors=$sectors; mod2048=$((sectors % 2048)))"
        exit 1
    fi
}

schedule_offline_ext_shrink() {
    local mode
    mode=${MODE:-swap}
    # Prepare one-shot initramfs task that will:
    #   e2fsck -f -y -> resize2fs to NEW_BLOCKS -> e2fsck -f -y -> sfdisk apply ptable
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

    export DEBIAN_FRONTEND=noninteractive
    # Ensure prerequisites for initramfs-based ext shrink exist.
    if ! command -v update-initramfs >/dev/null 2>&1 || ! command -v dumpe2fs >/dev/null 2>&1; then
        log_info "Installing prerequisites for offline ext* shrink (initramfs-tools, e2fsprogs, util-linux)..."
        apt-get update -qq || true
        apt-get install -y -qq initramfs-tools e2fsprogs util-linux || true
    fi

    if ! command -v update-initramfs >/dev/null 2>&1; then
        log_error "update-initramfs not found; cannot schedule offline shrink automatically"
        return 1
    fi
    if ! command -v dumpe2fs >/dev/null 2>&1; then
        log_error "dumpe2fs not found; cannot compute ext block size"
        return 1
    fi

    # Compute target filesystem block count for the new partition boundary.
    local block_size
    block_size=$(dumpe2fs -h "$ROOT_PARTITION" 2>/dev/null | awk -F: '/Block size/ {gsub(/ /,"",$2); print $2; exit}')
    if [[ -z "${block_size:-}" || ! "$block_size" =~ ^[0-9]+$ || "$block_size" -le 0 ]]; then
        log_error "Failed to determine ext block size via dumpe2fs"
        return 1
    fi
    local new_bytes
    new_bytes=$((NEW_ROOT_SIZE_SECTORS * 512))
    local new_blocks
    new_blocks=$((new_bytes / block_size))
    if [ "$new_blocks" -le 0 ]; then
        log_error "Computed NEW_BLOCKS is invalid: $new_blocks"
        return 1
    fi

    mkdir -p /etc/vbpub
    cp "$PTABLE_NEW" /etc/vbpub/offline-ptable.sfdisk

    local swap_first_num
    local swap_last_num
    if [ "$mode" = "swap" ]; then
        swap_first_num=$((ROOT_PART_NUM + 1))
        swap_last_num=$((ROOT_PART_NUM + SWAP_DEVICES))
    else
        swap_first_num=0
        swap_last_num=0
    fi

    cat > /etc/vbpub/offline-repartition.conf <<EOF
MODE=${mode}
ROOT_DISK=${ROOT_DISK}
ROOT_PARTITION=${ROOT_PARTITION}
NEW_BLOCKS=${new_blocks}
PTABLE_PATH=/etc/vbpub/offline-ptable.sfdisk
SWAP_FIRST_NUM=${swap_first_num}
SWAP_LAST_NUM=${swap_last_num}
SWAP_PRIORITY=${SWAP_PRIORITY}
EOF

    mkdir -p /etc/initramfs-tools/scripts/local-premount /etc/initramfs-tools/hooks
    cp "$script_dir/initramfs/vbpub-offline-repartition-premount.sh" /etc/initramfs-tools/scripts/local-premount/vbpub-offline-repartition
    cp "$script_dir/initramfs/vbpub-offline-repartition-hook.sh" /etc/initramfs-tools/hooks/vbpub-offline-repartition
    chmod +x /etc/initramfs-tools/scripts/local-premount/vbpub-offline-repartition /etc/initramfs-tools/hooks/vbpub-offline-repartition

    if [ "$mode" = "swap" ]; then
        # Install a one-shot finalizer that formats/enables swap partitions and updates /etc/fstab
        # on the next successful boot. This is important because cloud-init is often disabled after
        # first boot, and the initramfs stage may not be able to mount the root FS read-write.
        mkdir -p /usr/local/sbin /etc/systemd/system
        cat > /usr/local/sbin/vbpub-finalize-swap <<'EOF'
#!/bin/bash
set -euo pipefail

CONF=/etc/vbpub/offline-repartition.conf
PT=/etc/vbpub/offline-ptable.sfdisk

if [ ! -f "$CONF" ] || [ ! -f "$PT" ]; then
    exit 0
fi

# shellcheck disable=SC1090
source "$CONF"

SWAP_PRIORITY=${SWAP_PRIORITY:-10}
SWAP_FIRST_NUM=${SWAP_FIRST_NUM:-0}
SWAP_LAST_NUM=${SWAP_LAST_NUM:-0}

if [ -z "${ROOT_DISK:-}" ] || [ -z "${SWAP_FIRST_NUM:-}" ] || [ -z "${SWAP_LAST_NUM:-}" ]; then
    echo "vbpub-finalize-swap: missing required config values" >&2
    exit 0
fi

part_path() {
    local disk="$1" num="$2"
    if [[ "$disk" =~ nvme ]]; then
        echo "/dev/${disk}p${num}"
    else
        echo "/dev/${disk}${num}"
    fi
}

for n in $(seq "$SWAP_FIRST_NUM" "$SWAP_LAST_NUM"); do
    p=$(part_path "$ROOT_DISK" "$n")
    [ -b "$p" ] || continue
    t=$(blkid -s TYPE -o value "$p" 2>/dev/null || true)
    if [ "$t" != "swap" ]; then
        mkswap "$p" >/dev/null 2>&1 || true
    fi
    swapon -p "$SWAP_PRIORITY" "$p" >/dev/null 2>&1 || true

    pu=$(blkid -s PARTUUID -o value "$p" 2>/dev/null || true)
    if [ -n "$pu" ]; then
        grep -q "^PARTUUID=${pu}\\b" /etc/fstab 2>/dev/null || echo "PARTUUID=${pu} none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
    else
        grep -q "^${p}\\b" /etc/fstab 2>/dev/null || echo "${p} none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
    fi
done

rm -f "$CONF" "$PT" || true
exit 0
EOF
        chmod +x /usr/local/sbin/vbpub-finalize-swap

        cat > /etc/systemd/system/vbpub-finalize-swap.service <<'EOF'
[Unit]
Description=vbpub: finalize swap after offline repartition
After=local-fs.target
ConditionPathExists=/etc/vbpub/offline-repartition.conf
ConditionPathExists=/etc/vbpub/offline-ptable.sfdisk

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vbpub-finalize-swap

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable vbpub-finalize-swap.service 2>/dev/null || true
    fi

    log_info "Updating initramfs to include resize2fs + offline repartition job..."
    if ! update-initramfs -u; then
        log_error "update-initramfs failed; offline shrink was NOT scheduled"
        return 1
    fi

    log_warn "Offline shrink+repartition scheduled. Reboot is required."
    log_warn "If anything goes wrong, initramfs log: /run/vbpub-offline-repartition.log"
    touch /forcefsck 2>/dev/null || true
    return 0
}

# Determine how much space is safely usable at the end of the disk for swap.
# Keep a small tail buffer so we don't press against GPT end-of-disk structures.
END_BUFFER_SECTORS=2048
TOTAL_SWAP_TARGET_SECTORS=$((TOTAL_SWAP_TARGET_MIB * 2048))

if [ "$PRE_SHRINK_ONLY" = "yes" ]; then
    # Pre-shrink goal: shrink root to (used + extra) GB.
    # This is intended to be conservative and work on small disks.
    if [[ ! "$PRE_SHRINK_ROOT_EXTRA_GB" =~ ^[0-9]+$ ]] || [ "$PRE_SHRINK_ROOT_EXTRA_GB" -lt 1 ]; then
        log_error "Invalid PRE_SHRINK_ROOT_EXTRA_GB=$PRE_SHRINK_ROOT_EXTRA_GB"
        exit 1
    fi

    # Refuse to run if there are partitions after root (would be destructive).
    dump_tmp="/tmp/ptable-current-$(date +%s).dump"
    if ! sfdisk --dump "/dev/$ROOT_DISK" > "$dump_tmp" 2>/dev/null; then
        log_error "Failed to dump partition table"
        exit 1
    fi
    # Any /dev/${disk}N entries with N > root part num indicate other partitions.
    if grep -E "^/dev/${ROOT_DISK}(p)?[0-9]+" "$dump_tmp" | awk '{print $1}' | \
        sed -E "s|^/dev/${ROOT_DISK}p?||" | \
        awk -v rpn="$ROOT_PART_NUM" '$1 ~ /^[0-9]+$/ && $1 > rpn {found=1} END{exit(found?0:1)}'; then
        log_error "Pre-shrink-only refuses to run: found partitions after root on /dev/$ROOT_DISK"
        log_error "Run full stage2 partitioning instead (or wipe/reinstall)."
        exit 1
    fi

    # Minimum root size policy reused.
    PRESERVE_ROOT_SECTORS=$((PRESERVE_ROOT_SIZE_GB * 1024 * 1024 * 1024 / 512))
    ROOT_USED_BYTES=$(df -B1 --output=used / 2>/dev/null | tail -n 1 | tr -d ' ' || echo 0)
    if [[ -z "${ROOT_USED_BYTES:-}" || ! "${ROOT_USED_BYTES}" =~ ^[0-9]+$ ]]; then
        ROOT_USED_BYTES=0
    fi

    extra_bytes=$((PRE_SHRINK_ROOT_EXTRA_GB * 1024 * 1024 * 1024))
    # keep a bit of headroom for metadata/fragmentation (2GiB) in addition to the requested extra.
    ROOT_TARGET_BYTES=$((ROOT_USED_BYTES + extra_bytes + 2 * 1024 * 1024 * 1024))
    ROOT_TARGET_SECTORS=$(((ROOT_TARGET_BYTES + 511) / 512))
    if [ "$ROOT_TARGET_SECTORS" -lt "$PRESERVE_ROOT_SECTORS" ]; then
        ROOT_TARGET_SECTORS="$PRESERVE_ROOT_SECTORS"
    fi

    NEW_ROOT_END=$((ROOT_START + ROOT_TARGET_SECTORS))
    NEW_ROOT_END=$(align_up_2048 "$NEW_ROOT_END")

    # Also ensure we don't collide with the GPT tail.
    DISK_MAX_END=$((DISK_SIZE_SECTORS - END_BUFFER_SECTORS))
    DISK_MAX_END=$(align_down_2048 "$DISK_MAX_END")
    if [ "$NEW_ROOT_END" -gt "$DISK_MAX_END" ]; then
        log_warn "Pre-shrink target exceeds disk size; skipping shrink"
        exit 0
    fi

    NEW_ROOT_SIZE_SECTORS=$((NEW_ROOT_END - ROOT_START))
    NEW_ROOT_SIZE_SECTORS=$(align_down_2048 "$NEW_ROOT_SIZE_SECTORS")
    require_mib_aligned "New root size" "$NEW_ROOT_SIZE_SECTORS"

    if [ "$NEW_ROOT_SIZE_SECTORS" -ge "$ROOT_SIZE" ]; then
        log_info "Root already small enough (no pre-shrink needed)"
        exit 0
    fi

    NEW_ROOT_SIZE_GB=$((NEW_ROOT_SIZE_SECTORS / 2048 / 1024))
    log_info "Pre-shrink target: root ${ROOT_SIZE_GB}GB -> ${NEW_ROOT_SIZE_GB}GB (used=$((${ROOT_USED_BYTES} / 1024 / 1024 / 1024))GB + ${PRE_SHRINK_ROOT_EXTRA_GB}GB)"

    # Create modified partition table: only change root size.
    PTABLE_NEW="/tmp/ptable-pre-shrink-$(date +%s).dump"
    awk -v rp="$ROOT_PARTITION" -v ns="$NEW_ROOT_SIZE_SECTORS" '
      $1==rp {
        line=$0
        if (line ~ /size=/) {
          sub(/size=[[:space:]]*[0-9]+/, "size=" ns, line)
        }
        print line
        next
      }
      {print}
    ' "$dump_tmp" > "$PTABLE_NEW"

    # Schedule offline ext* shrink (shrink-only mode).
    if [ "$FS_TYPE" = "ext4" ] || [ "$FS_TYPE" = "ext3" ] || [ "$FS_TYPE" = "ext2" ]; then
        # Reuse scheduler with MODE=shrink-only and no swaps.
        MODE=shrink-only
        SWAP_DEVICES=0
        if schedule_offline_ext_shrink; then
            exit "$OFFLINE_SHRINK_EXIT_CODE"
        fi
        log_error "Failed to schedule offline ext* shrink"
        exit 1
    fi

    log_error "Pre-shrink-only currently supports only ext2/3/4 root filesystem (found: $FS_TYPE)"
    exit 1
fi

# Minimum root size policy:
# - Respect PRESERVE_ROOT_SIZE_GB
# - Also ensure root stays larger than current used space (+2GiB safety)
PRESERVE_ROOT_SECTORS=$((PRESERVE_ROOT_SIZE_GB * 1024 * 1024 * 1024 / 512))
ROOT_USED_BYTES=$(df -B1 --output=used / 2>/dev/null | tail -n 1 | tr -d ' ' || echo 0)
if [[ -z "${ROOT_USED_BYTES:-}" || ! "${ROOT_USED_BYTES}" =~ ^[0-9]+$ ]]; then
    ROOT_USED_BYTES=0
fi
ROOT_MIN_BYTES=$((ROOT_USED_BYTES + 2 * 1024 * 1024 * 1024))
ROOT_MIN_SECTORS=$(((ROOT_MIN_BYTES + 511) / 512))
if [ "$ROOT_MIN_SECTORS" -lt "$PRESERVE_ROOT_SECTORS" ]; then
    ROOT_MIN_SECTORS="$PRESERVE_ROOT_SECTORS"
fi
ROOT_MIN_END_ALIGNED=$(align_up_2048 $((ROOT_START + ROOT_MIN_SECTORS)))

if [ "$ALLOW_ROOT_SHRINK" != "yes" ] && [ "$FREE_SECTORS" -le 0 ]; then
    log_error "No free space after root and ALLOW_ROOT_SHRINK!=yes"
    log_error "Set ALLOW_ROOT_SHRINK=yes to carve swap by shrinking the root partition."
    exit 1
fi

MAX_SWAP_SECTORS=$((DISK_SIZE_SECTORS - END_BUFFER_SECTORS - ROOT_MIN_END_ALIGNED))
MAX_SWAP_SECTORS=$(align_down_2048 "$MAX_SWAP_SECTORS")
if [ "$MAX_SWAP_SECTORS" -le 0 ]; then
    log_error "No usable space for swap after enforcing minimum root size (min_root=${PRESERVE_ROOT_SIZE_GB}GB; used_bytes=${ROOT_USED_BYTES})."
    exit 1
fi

TOTAL_SWAP_USED_SECTORS=$TOTAL_SWAP_TARGET_SECTORS
if [ "$TOTAL_SWAP_USED_SECTORS" -gt "$MAX_SWAP_SECTORS" ]; then
    log_warn "Capping swap to fit disk after minimum root size: target=${TOTAL_SWAP_TARGET_MIB}MiB -> max=$((MAX_SWAP_SECTORS / 2048))MiB"
    TOTAL_SWAP_USED_SECTORS=$MAX_SWAP_SECTORS
fi

# Align per-device size down to 1MiB (2048 sectors) so all partitions are equal and aligned.
PER_DEVICE_SECTORS=$((TOTAL_SWAP_USED_SECTORS / SWAP_DEVICES))
PER_DEVICE_SECTORS=$(align_down_2048 "$PER_DEVICE_SECTORS")

require_mib_aligned "Per-device swap size" "$PER_DEVICE_SECTORS"

if [ "$PER_DEVICE_SECTORS" -lt 2048 ]; then
    # Too many devices for available space; reduce device count so each gets at least 1MiB.
    MAX_DEVICES=$((TOTAL_SWAP_USED_SECTORS / 2048))
    if [ "$MAX_DEVICES" -lt 1 ]; then
        MAX_DEVICES=1
    fi
    log_warn "Available space too small for ${SWAP_DEVICES} swap devices; reducing to ${MAX_DEVICES} to maintain >=1MiB per device"
    SWAP_DEVICES=$MAX_DEVICES
    PER_DEVICE_SECTORS=$((TOTAL_SWAP_USED_SECTORS / SWAP_DEVICES))
    PER_DEVICE_SECTORS=$(( (PER_DEVICE_SECTORS / 2048) * 2048 ))
fi

TOTAL_SWAP_USED_SECTORS=$((PER_DEVICE_SECTORS * SWAP_DEVICES))
PER_DEVICE_MIB=$((PER_DEVICE_SECTORS / 2048))
TOTAL_SWAP_USED_MIB=$((PER_DEVICE_MIB * SWAP_DEVICES))

log_info "Total usable tail space for swap: $((MAX_SWAP_SECTORS / 2048))MiB (after min root)"
log_info "Per-device: ${PER_DEVICE_MIB}MiB (${PER_DEVICE_SECTORS} sectors)"
log_info "Total swap used: ${TOTAL_SWAP_USED_MIB}MiB (${TOTAL_SWAP_USED_SECTORS} sectors)"

# Disk layout: we only ever EXTEND root (never shrink). If there's more free space than needed,
# extend root so swap sits at the end and root uses the remainder.
DISK_LAYOUT="minimal_root"
log_info "Disk layout: MINIMAL ROOT (root is never shrunk)"

# Backup partition table
BACKUP_FILE="/tmp/ptable-backup-$(date +%s).dump"
if ! sfdisk --dump "/dev/$ROOT_DISK" > "$BACKUP_FILE" 2>&1; then
    log_error "Failed to backup partition table"
    exit 1
fi
log_success "Partition table backed up to: $BACKUP_FILE"

# Emit summary with final (possibly capped) values
log_info "Total swap target: ${TOTAL_SWAP_TARGET_MIB}MiB (${TOTAL_SWAP_TARGET_SECTORS} sectors)"
log_info "Total swap used:   ${TOTAL_SWAP_USED_MIB}MiB (${TOTAL_SWAP_USED_SECTORS} sectors)"

# Create modified partition table
PTABLE_NEW="/tmp/ptable-new-$(date +%s).dump"
SWAP_TYPE_GUID="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"  # Linux swap GUID for GPT

log_step "Creating modified partition table..."

# Place swap at the end of the disk and resize root partition (extend OR shrink) accordingly.
# Root start remains fixed.
DESIRED_SWAP_START=$((DISK_SIZE_SECTORS - END_BUFFER_SECTORS - TOTAL_SWAP_USED_SECTORS))
DESIRED_SWAP_START=$(align_down_2048 "$DESIRED_SWAP_START")

require_mib_aligned "Desired swap start" "$DESIRED_SWAP_START"

if [ "$DESIRED_SWAP_START" -lt "$ROOT_MIN_END_ALIGNED" ]; then
    # Should not happen due to MAX_SWAP_SECTORS cap, but keep it safe.
    log_warn "Desired swap start would violate minimum root size; shrinking swap to fit minimum root"
    DESIRED_SWAP_START="$ROOT_MIN_END_ALIGNED"
    TOTAL_SWAP_USED_SECTORS=$((DISK_SIZE_SECTORS - END_BUFFER_SECTORS - DESIRED_SWAP_START))
    TOTAL_SWAP_USED_SECTORS=$(align_down_2048 "$TOTAL_SWAP_USED_SECTORS")
    PER_DEVICE_SECTORS=$((TOTAL_SWAP_USED_SECTORS / SWAP_DEVICES))
    PER_DEVICE_SECTORS=$(align_down_2048 "$PER_DEVICE_SECTORS")
    TOTAL_SWAP_USED_SECTORS=$((PER_DEVICE_SECTORS * SWAP_DEVICES))
    PER_DEVICE_MIB=$((PER_DEVICE_SECTORS / 2048))
    TOTAL_SWAP_USED_MIB=$((PER_DEVICE_MIB * SWAP_DEVICES))
fi

NEW_ROOT_SIZE_SECTORS=$((DESIRED_SWAP_START - ROOT_START))
NEW_ROOT_SIZE_SECTORS=$(align_down_2048 "$NEW_ROOT_SIZE_SECTORS")

require_mib_aligned "New root size" "$NEW_ROOT_SIZE_SECTORS"

NEW_ROOT_SIZE_GB=$((NEW_ROOT_SIZE_SECTORS / 2048 / 1024))
log_info "New root size: ${NEW_ROOT_SIZE_GB}GB (${NEW_ROOT_SIZE_SECTORS} sectors)"
if [ "$NEW_ROOT_SIZE_SECTORS" -gt "$ROOT_SIZE" ]; then
    log_info "Root will be extended from ${ROOT_SIZE_GB}GB to ${NEW_ROOT_SIZE_GB}GB"
elif [ "$NEW_ROOT_SIZE_SECTORS" -lt "$ROOT_SIZE" ]; then
    log_warn "Root partition will be SHRUNK from ${ROOT_SIZE_GB}GB to ${NEW_ROOT_SIZE_GB}GB (accepted risk)"
    if [ "$FS_TYPE" = "ext4" ] || [ "$FS_TYPE" = "ext3" ] || [ "$FS_TYPE" = "ext2" ]; then
        log_warn "ext* cannot shrink online. Scheduling an OFFLINE shrink+repartition in initramfs is required to avoid boot failure."
    else
        log_warn "Filesystem type '$FS_TYPE' may not tolerate shrink; proceed at your own risk."
    fi
else
    log_info "Root will remain unchanged (no shrink performed)"
fi

# Generate modified partition table
{
    # Copy header
    grep -E "^(label|label-id|device|unit|first-lba|last-lba|sector-size):" "$BACKUP_FILE"
    echo ""

    # Process existing partitions
    # Policy: keep partitions strictly before root (e.g. EFI), keep root,
    # and DROP anything after root so the disk is fully rewritten to the new plan.
    while IFS= read -r line; do
        if [[ "$line" =~ ^/dev/ ]]; then
            PART_NUM=$(echo "$line" | grep -oE '[0-9]+' | head -1)
            if [ "$PART_NUM" = "$ROOT_PART_NUM" ]; then
                echo "$line" | sed -E "s/size= *[0-9]+/size=${NEW_ROOT_SIZE_SECTORS}/"
            else
                PART_START=$(echo "$line" | sed -E 's/.*start= *([0-9]+).*/\1/' | tr -d ' ')
                if [[ -n "$PART_START" ]] && [ "$PART_START" -lt "$ROOT_START" ]; then
                    echo "$line"
                fi
            fi
        fi
    done < "$BACKUP_FILE"

    # Add swap partitions
    SWAP_START=$((ROOT_START + NEW_ROOT_SIZE_SECTORS))
    SWAP_START=$(( (SWAP_START + 2047) / 2048 * 2048 ))  # Align to 2048 sectors

    require_mib_aligned "First swap partition start" "$SWAP_START"
    for i in $(seq 1 "$SWAP_DEVICES"); do
        SWAP_PART_NUM=$((ROOT_PART_NUM + i))
        if [[ "$ROOT_DISK" =~ nvme ]]; then
            PART_NAME="/dev/${ROOT_DISK}p${SWAP_PART_NUM}"
        else
            PART_NAME="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
        fi

        require_mib_aligned "Swap partition ${i} start" "$SWAP_START"
        require_mib_aligned "Swap partition ${i} size" "$PER_DEVICE_SECTORS"
        echo "${PART_NAME} : start=${SWAP_START}, size=${PER_DEVICE_SECTORS}, type=${SWAP_TYPE_GUID}"
        SWAP_START=$((SWAP_START + PER_DEVICE_SECTORS))
        SWAP_START=$(( (SWAP_START + 2047) / 2048 * 2048 ))  # Align to 2048 sectors
    done
} > "$PTABLE_NEW"

log_success "Modified partition table created: $PTABLE_NEW"

# Show changes
log_info "Partition table changes:"
log_info "  Root partition: ${ROOT_SIZE_GB}GB -> ${NEW_ROOT_SIZE_GB}GB"
log_info "  New swap partitions: ${SWAP_DEVICES} × ${PER_DEVICE_MIB}MiB (total ${TOTAL_SWAP_USED_MIB}MiB; target ${TOTAL_SWAP_TARGET_MIB}MiB)"

# If we are shrinking an ext* filesystem, do not apply the smaller partition table online.
# Instead, schedule an initramfs one-shot that shrinks the filesystem FIRST, then applies the table.
if [ "$NEW_ROOT_SIZE_SECTORS" -lt "$ROOT_SIZE" ] && { [ "$FS_TYPE" = "ext4" ] || [ "$FS_TYPE" = "ext3" ] || [ "$FS_TYPE" = "ext2" ]; }; then
    if schedule_offline_ext_shrink; then
        exit "$OFFLINE_SHRINK_EXIT_CODE"
    fi
    log_error "Failed to schedule offline ext* shrink; refusing to shrink partition online"
    exit 1
fi

# Write modified partition table
log_step "Writing modified partition table to disk..."

if sfdisk --force --no-reread "/dev/$ROOT_DISK" < "$PTABLE_NEW" 2>&1 | tee -a "$LOG_FILE"; then
    log_info "Partition table written (Device or resource busy is NORMAL)"
else
    log_warn "sfdisk returned non-zero (expected sometimes for in-use disk); verifying state instead"
fi

log_step "Verifying partition table state (dump + expected entries)..."

READBACK_FILE="/tmp/ptable-readback-$(date +%s).dump"
if ! sfdisk --dump "/dev/$ROOT_DISK" > "$READBACK_FILE" 2>&1; then
    log_error "Failed to read back partition table after write"
    log_error "Backup: $BACKUP_FILE"
    exit 1
fi

# Root size check
READBACK_ROOT_SIZE=$(grep -E "^${ROOT_PARTITION}[[:space:]]" "$READBACK_FILE" | sed -E 's/.*size= *([0-9]+).*/\1/' | head -1)
if [ -z "${READBACK_ROOT_SIZE:-}" ]; then
    log_error "Could not find root partition entry in readback dump"
    log_error "Readback: $READBACK_FILE"
    exit 1
fi
if [ "$READBACK_ROOT_SIZE" != "$NEW_ROOT_SIZE_SECTORS" ]; then
    log_error "Root partition size mismatch after write"
    log_error "Expected: $NEW_ROOT_SIZE_SECTORS sectors; Found: $READBACK_ROOT_SIZE sectors"
    log_error "Restore with: sfdisk --force /dev/$ROOT_DISK < $BACKUP_FILE"
    exit 1
fi

# Swap partition entries check
missing=0
for i in $(seq 1 "$SWAP_DEVICES"); do
    SWAP_PART_NUM=$((ROOT_PART_NUM + i))
    if [[ "$ROOT_DISK" =~ nvme ]]; then
        EXPECTED_PART="/dev/${ROOT_DISK}p${SWAP_PART_NUM}"
    else
        EXPECTED_PART="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
    fi
    if ! grep -q -E "^${EXPECTED_PART}[[:space:]]" "$READBACK_FILE"; then
        log_warn "Missing expected swap partition entry in table: $EXPECTED_PART"
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    log_error "Partition table does not contain all expected swap partitions"
    log_error "Readback: $READBACK_FILE"
    log_error "Restore with: sfdisk --force /dev/$ROOT_DISK < $BACKUP_FILE"
    exit 1
fi
log_success "Partition table state verified via readback dump"

# Sync and force write
log_info "Syncing disk writes..."
sync
sleep 2

# Notify kernel of partition table changes
log_step "Notifying kernel of partition table changes..."

# Method 0: blockdev --rereadpt (force re-read; may fail on in-use disks)
if command -v blockdev >/dev/null 2>&1; then
    log_info "Using blockdev --rereadpt..."
    if blockdev --rereadpt "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "blockdev completed"
    else
        log_warn "blockdev reported errors (expected for in-use disk)"
    fi
fi

# Method 1: partprobe (preferred)
if command -v partprobe >/dev/null 2>&1; then
    log_info "Using partprobe..."
    if partprobe "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "partprobe completed"
    else
        log_warn "partprobe reported errors (expected for in-use disk)"
    fi
fi

# Method 2: partx (fallback)
if command -v partx >/dev/null 2>&1; then
    log_info "Using partx -u..."
    if partx -u "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "partx completed"
    else
        log_warn "partx reported errors (expected for in-use disk)"
    fi
fi

# Settle udev events so device nodes show up (when possible)
if command -v udevadm >/dev/null 2>&1; then
    udevadm settle 2>&1 | tee -a "$LOG_FILE" || true
fi

# Wait for device nodes to appear
log_info "Waiting for device nodes to appear..."
sleep 1

log_info "Waiting for kernel to expose new partitions..."
expected_last_num=$((ROOT_PART_NUM + SWAP_DEVICES))
if [[ "$ROOT_DISK" =~ nvme ]]; then
    expected_last_name="${ROOT_DISK}p${expected_last_num}"
else
    expected_last_name="${ROOT_DISK}${expected_last_num}"
fi

for retry in {1..20}; do
    if lsblk -n -o NAME "/dev/$ROOT_DISK" 2>/dev/null | grep -q "^${expected_last_name}$"; then
        break
    fi
    sleep 1
done

if ! lsblk -n -o NAME "/dev/$ROOT_DISK" 2>/dev/null | grep -q "^${expected_last_name}$"; then
    log_warn "Kernel does not yet show expected last partition: /dev/${expected_last_name}"
    log_warn "Continuing, but swap partition formatting may fail until nodes appear"
fi

# Verify partitions are visible
log_info "Verifying new partitions..."
lsblk "/dev/$ROOT_DISK" | tee -a "$LOG_FILE"

# Resize root filesystem
log_step "Resizing root filesystem..."

case "$FS_TYPE" in
    ext4|ext3|ext2)
        # Check filesystem first (read-only check)
        log_info "Checking ext filesystem (read-only)..."
        e2fsck -n -v "$ROOT_PARTITION" 2>&1 | tee -a "$LOG_FILE" || true
        
        if [ "$NEW_ROOT_SIZE_SECTORS" -gt "$ROOT_SIZE" ]; then
            log_info "Expanding filesystem to fill partition..."
            if resize2fs "$ROOT_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Filesystem expanded"
            else
                log_error "Failed to expand filesystem"
                exit 1
            fi
        elif [ "$NEW_ROOT_SIZE_SECTORS" -lt "$ROOT_SIZE" ]; then
            log_warn "Root partition was shrunk; skipping online filesystem shrink. Reboot + fsck is recommended."
        else
            log_info "Root partition unchanged; no filesystem resize needed"
        fi
        ;;
    xfs)
        # XFS can only grow
        if [ "$NEW_ROOT_SIZE_SECTORS" -gt "$ROOT_SIZE" ]; then
            log_info "Growing XFS filesystem..."
            if xfs_growfs / 2>&1 | tee -a "$LOG_FILE"; then
                log_success "XFS filesystem grown"
            else
                log_error "Failed to grow XFS filesystem"
                exit 1
            fi
        else
            log_info "Root partition unchanged; no filesystem resize needed"
        fi
        ;;
    btrfs)
        if [ "$NEW_ROOT_SIZE_SECTORS" -gt "$ROOT_SIZE" ]; then
            log_info "Growing btrfs filesystem..."
            if btrfs filesystem resize max / 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Btrfs filesystem grown"
            else
                log_error "Failed to grow btrfs filesystem"
                exit 1
            fi
        else
            log_info "Root partition unchanged; no filesystem resize needed"
        fi
        ;;
    *)
        log_error "Unsupported filesystem: $FS_TYPE"
        exit 1
        ;;
esac

# Format and enable swap partitions
log_step "Formatting and enabling swap partitions..."

# Ensure we are not using any swap while repartitioning / reformatting.
swapoff -a 2>/dev/null || true

# Rewrite /etc/fstab swap entries so repeated runs don't accumulate stale PARTUUIDs.
if [ -f /etc/fstab ]; then
    FSTAB_BACKUP="/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/fstab "$FSTAB_BACKUP"
    awk '
        /^[[:space:]]*#/ {print; next}
        NF>=3 && $3=="swap" {next}
        {print}
    ' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
    log_info "Cleaned swap entries from /etc/fstab (backup: $FSTAB_BACKUP)"
fi

missing_dev=0
for i in $(seq 1 "$SWAP_DEVICES"); do
    SWAP_PART_NUM=$((ROOT_PART_NUM + i))
    
    if [[ "$ROOT_DISK" =~ nvme ]]; then
        SWAP_PARTITION="/dev/${ROOT_DISK}p${SWAP_PART_NUM}"
    else
        SWAP_PARTITION="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
    fi
    
    log_info "Processing swap partition ${i}/${SWAP_DEVICES}: ${SWAP_PARTITION}"
    
    # Wait for device node
    for retry in {1..10}; do
        if [ -b "$SWAP_PARTITION" ]; then
            break
        fi
        log_info "Waiting for ${SWAP_PARTITION} (attempt ${retry}/10)..."
        sleep 1
    done
    
    if [ ! -b "$SWAP_PARTITION" ]; then
        log_error "Device ${SWAP_PARTITION} not found"
        missing_dev=1
        continue
    fi
    
    # Format as swap
    log_info "Formatting ${SWAP_PARTITION} as swap..."
    if mkswap "$SWAP_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Formatted swap partition ${i}"
    else
        log_error "Failed to format swap partition ${i}"
        continue
    fi
    
    # Enable swap
    log_info "Enabling swap partition ${i}..."
    if swapon -p "$SWAP_PRIORITY" "$SWAP_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Enabled swap partition ${i}"
    else
        log_error "Failed to enable swap partition ${i}"
        continue
    fi
    
    # Add to /etc/fstab using PARTUUID
    PARTUUID=$(lsblk -no PARTUUID "$SWAP_PARTITION" 2>/dev/null | tr -d ' ')
    if [ -z "$PARTUUID" ]; then
        PARTUUID=$(blkid -s PARTUUID -o value "$SWAP_PARTITION" 2>/dev/null || true)
    fi
    if [ -z "$PARTUUID" ]; then
        log_error "Failed to resolve PARTUUID for ${SWAP_PARTITION}; refusing to write unstable fstab entry"
        missing_dev=1
        continue
    fi

    if ! grep -q "^PARTUUID=${PARTUUID}\\b" /etc/fstab 2>/dev/null; then
        echo "PARTUUID=${PARTUUID} none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
        log_info "Added swap ${i} to /etc/fstab (PARTUUID=${PARTUUID})"
    else
        log_info "Swap ${i} already in /etc/fstab"
    fi
done

if [ "$missing_dev" -ne 0 ]; then
    log_error "One or more swap partitions failed to appear or be configured"
    log_error "Do not reboot until you verify the partition table and swap devices"
    exit 1
fi

# Show final status
log_step "Final Status"

log_info "Root filesystem:"
df -h / | tee -a "$LOG_FILE"

log_info ""
log_info "Active swap devices:"
swapon --show | tee -a "$LOG_FILE"

log_info ""
log_info "/etc/fstab swap entries:"
grep "swap" /etc/fstab | tee -a "$LOG_FILE"

log_success "Swap partition creation complete!"
log_info "Created ${SWAP_DEVICES} swap partitions totaling ${TOTAL_SWAP_USED_MIB}MiB (target ${TOTAL_SWAP_TARGET_MIB}MiB)"
log_info "Backup partition table: $BACKUP_FILE"
log_info "Log file: $LOG_FILE"

echo ""
log_info "Next steps:"
log_info "  1. Verify: swapon --show"
log_info "  2. Test: free -h"
log_info "  3. If using ZSWAP, configure: sudo ./setup-swap.sh"
log_info "  4. Run latency tests: sudo ./benchmark.py --test-zswap-latency"
