#!/bin/bash
# Create optimal swap partitions based on benchmark matrix test results
# Supports two disk layouts:
# 1. MINIMAL ROOT: Extend root and place swap at end
# 2. FULL ROOT: Shrink root and place swap at end
# Always uses sfdisk dump-modify-write pattern

set -euo pipefail

# Configuration
BENCHMARK_RESULTS="${BENCHMARK_RESULTS:-/var/log/debian-install/benchmark-results-*.json}"
LOG_FILE="${LOG_FILE:-/var/log/debian-install/partition-creation.log}"
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"

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

# Find the most recent benchmark results file
RESULTS_FILE=$(ls -t $BENCHMARK_RESULTS 2>/dev/null | head -1)

if [ -z "$RESULTS_FILE" ] || [ ! -f "$RESULTS_FILE" ]; then
    log_error "No benchmark results found at: $BENCHMARK_RESULTS"
    log_info "Run: sudo ./benchmark.py --test-all"
    exit 1
fi

log_info "Using benchmark results: $RESULTS_FILE"

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required but not installed"
    log_info "Install with: apt-get install -y jq"
    exit 1
fi

# Extract optimal device count from matrix test results
if ! OPTIMAL_DEVICES=$(jq -r '.matrix.optimal.best_combined.concurrency // empty' "$RESULTS_FILE" 2>/dev/null); then
    log_error "Failed to extract optimal concurrency from benchmark results"
    log_error "Matrix test may not have completed successfully"
    exit 1
fi

if [ -z "$OPTIMAL_DEVICES" ] || [ "$OPTIMAL_DEVICES" = "null" ]; then
    log_error "No optimal device count found in benchmark results"
    log_error "Ensure matrix test completed: jq '.matrix' $RESULTS_FILE"
    exit 1
fi

log_info "Optimal swap device count from benchmark: $OPTIMAL_DEVICES"

# Get system specifications
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
TOTAL_SWAP_GB=$((RAM_GB * 2))  # 2x RAM sizing policy

log_info "System RAM: ${RAM_GB}GB"
log_info "Total swap needed: ${TOTAL_SWAP_GB}GB"

# Calculate per-device size
PER_DEVICE_GB=$((TOTAL_SWAP_GB / OPTIMAL_DEVICES))
if [ "$PER_DEVICE_GB" -lt 1 ]; then
    PER_DEVICE_GB=1
    log_warn "Per-device size < 1GB, using 1GB minimum"
fi

log_info "Per-device swap size: ${PER_DEVICE_GB}GB"
log_info "Will create ${OPTIMAL_DEVICES} swap partitions of ${PER_DEVICE_GB}GB each"

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

# Determine disk layout scenario
TOTAL_SWAP_SECTORS=$((TOTAL_SWAP_GB * 1024 * 2048))

if [ "$FREE_SECTORS" -gt "$TOTAL_SWAP_SECTORS" ]; then
    DISK_LAYOUT="minimal_root"
    log_info "Disk layout: MINIMAL ROOT (sufficient free space available)"
else
    DISK_LAYOUT="full_root"
    log_info "Disk layout: FULL ROOT (need to shrink root partition)"
fi

# Get filesystem type
FS_TYPE=$(findmnt -n -o FSTYPE /)
log_info "Root filesystem: $FS_TYPE"

# Validate filesystem type for shrinking (if needed)
if [ "$DISK_LAYOUT" = "full_root" ]; then
    case "$FS_TYPE" in
        btrfs)
            log_info "Filesystem supports online shrinking: $FS_TYPE"
            ;;
        ext4|ext3|ext2)
            log_warn "FULL ROOT on $FS_TYPE: will shrink partition end only (no online filesystem shrink)"
            log_warn "Assumption: filesystem has free space at the end; this is NOT validated here"
            log_warn "Expected follow-up: reboot and let fsck reconcile filesystem/partition size"
            ;;
        xfs)
            log_error "XFS does not support shrinking - cannot proceed with full_root layout"
            log_info "Options:"
            log_info "  1. Reinstall with smaller root partition"
            log_info "  2. Use file-based swap instead of partitions"
            exit 1
            ;;
        *)
            log_warn "Unknown filesystem type: $FS_TYPE - proceeding with caution"
            ;;
    esac
fi

# Backup partition table
BACKUP_FILE="/tmp/ptable-backup-$(date +%s).dump"
if ! sfdisk --dump "/dev/$ROOT_DISK" > "$BACKUP_FILE" 2>&1; then
    log_error "Failed to backup partition table"
    exit 1
fi
log_success "Partition table backed up to: $BACKUP_FILE"

# Calculate partition sizes
PER_DEVICE_MIB=$((PER_DEVICE_GB * 1024))
PER_DEVICE_SECTORS=$((PER_DEVICE_MIB * 2048))
TOTAL_SWAP_MIB=$((PER_DEVICE_MIB * OPTIMAL_DEVICES))

log_info "Per-device: ${PER_DEVICE_MIB}MiB (${PER_DEVICE_SECTORS} sectors)"
log_info "Total swap: ${TOTAL_SWAP_MIB}MiB (${TOTAL_SWAP_SECTORS} sectors)"

# Create modified partition table
PTABLE_NEW="/tmp/ptable-new-$(date +%s).dump"
SWAP_TYPE_GUID="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"  # Linux swap GUID for GPT

log_step "Creating modified partition table..."

if [ "$DISK_LAYOUT" = "minimal_root" ]; then
    # Scenario 1: MINIMAL ROOT - extend root to use most of disk, place swap at end
    NEW_ROOT_SIZE_SECTORS=$((DISK_SIZE_SECTORS - ROOT_START - TOTAL_SWAP_SECTORS - 2048))
    NEW_ROOT_SIZE_GB=$((NEW_ROOT_SIZE_SECTORS / 2048 / 1024))
    
    log_info "New root size: ${NEW_ROOT_SIZE_GB}GB (${NEW_ROOT_SIZE_SECTORS} sectors)"
    log_info "Root will be extended from ${ROOT_SIZE_GB}GB to ${NEW_ROOT_SIZE_GB}GB"
    
    # Generate modified partition table
    {
        # Copy header
        grep -E "^(label|label-id|device|unit|first-lba|last-lba|sector-size):" "$BACKUP_FILE"
        echo ""
        
        # Process existing partitions
        while IFS= read -r line; do
            if [[ "$line" =~ ^/dev/ ]]; then
                PART_NUM=$(echo "$line" | grep -oE '[0-9]+' | head -1)
                if [ "$PART_NUM" = "$ROOT_PART_NUM" ]; then
                    # Extend root partition
                    echo "$line" | sed -E "s/size= *[0-9]+/size=${NEW_ROOT_SIZE_SECTORS}/"
                else
                    # Keep other partitions
                    echo "$line"
                fi
            fi
        done < "$BACKUP_FILE"
        
        # Add swap partitions
        SWAP_START=$((ROOT_START + NEW_ROOT_SIZE_SECTORS))
        for i in $(seq 1 "$OPTIMAL_DEVICES"); do
            SWAP_PART_NUM=$((ROOT_PART_NUM + i))
            if [[ "$ROOT_DISK" =~ nvme ]]; then
                PART_NAME="/dev/${ROOT_DISK}p${SWAP_PART_NUM}"
            else
                PART_NAME="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
            fi
            echo "${PART_NAME} : start=${SWAP_START}, size=${PER_DEVICE_SECTORS}, type=${SWAP_TYPE_GUID}"
            SWAP_START=$((SWAP_START + PER_DEVICE_SECTORS))
            SWAP_START=$(( (SWAP_START + 2047) / 2048 * 2048 ))  # Align to 2048 sectors
        done
    } > "$PTABLE_NEW"
    
else
    # Scenario 2: FULL ROOT - shrink root, add swap at end
    NEW_ROOT_SIZE_SECTORS=$((DISK_SIZE_SECTORS - ROOT_START - TOTAL_SWAP_SECTORS - 2048))
    NEW_ROOT_SIZE_GB=$((NEW_ROOT_SIZE_SECTORS / 2048 / 1024))
    
    log_info "New root size: ${NEW_ROOT_SIZE_GB}GB (${NEW_ROOT_SIZE_SECTORS} sectors)"
    log_info "Root will be shrunk from ${ROOT_SIZE_GB}GB to ${NEW_ROOT_SIZE_GB}GB"
    
    if [ "$NEW_ROOT_SIZE_SECTORS" -le 0 ]; then
        log_error "Not enough space: disk too small for desired swap configuration"
        log_error "Disk: ${DISK_SIZE_GB}GB, Root start: $((ROOT_START / 2048 / 1024))GB, Swap needed: ${TOTAL_SWAP_GB}GB"
        exit 1
    fi
    
    # Generate modified partition table
    {
        # Copy header
        grep -E "^(label|label-id|device|unit|first-lba|last-lba|sector-size):" "$BACKUP_FILE"
        echo ""
        
        # Process existing partitions
        while IFS= read -r line; do
            if [[ "$line" =~ ^/dev/ ]]; then
                PART_NUM=$(echo "$line" | grep -oE '[0-9]+' | head -1)
                if [ "$PART_NUM" = "$ROOT_PART_NUM" ]; then
                    # Shrink root partition
                    echo "$line" | sed -E "s/size= *[0-9]+/size=${NEW_ROOT_SIZE_SECTORS}/"
                else
                    # Keep other partitions
                    echo "$line"
                fi
            fi
        done < "$BACKUP_FILE"
        
        # Add swap partitions
        SWAP_START=$((ROOT_START + NEW_ROOT_SIZE_SECTORS))
        for i in $(seq 1 "$OPTIMAL_DEVICES"); do
            SWAP_PART_NUM=$((ROOT_PART_NUM + i))
            if [[ "$ROOT_DISK" =~ nvme ]]; then
                PART_NAME="/dev/${ROOT_DISK}p${SWAP_PART_NUM}"
            else
                PART_NAME="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
            fi
            echo "${PART_NAME} : start=${SWAP_START}, size=${PER_DEVICE_SECTORS}, type=${SWAP_TYPE_GUID}"
            SWAP_START=$((SWAP_START + PER_DEVICE_SECTORS))
            SWAP_START=$(( (SWAP_START + 2047) / 2048 * 2048 ))  # Align to 2048 sectors
        done
    } > "$PTABLE_NEW"
fi

log_success "Modified partition table created: $PTABLE_NEW"

# Show changes
log_info "Partition table changes:"
log_info "  Root partition: ${ROOT_SIZE_GB}GB -> ${NEW_ROOT_SIZE_GB}GB"
log_info "  New swap partitions: ${OPTIMAL_DEVICES} × ${PER_DEVICE_GB}GB"

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
for i in $(seq 1 "$OPTIMAL_DEVICES"); do
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

# Wait for device nodes to appear
log_info "Waiting for device nodes to appear..."
sleep 1

log_info "Waiting for kernel to expose new partitions..."
expected_last_num=$((ROOT_PART_NUM + OPTIMAL_DEVICES))
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
        
        if [ "$DISK_LAYOUT" = "minimal_root" ]; then
            log_info "Expanding filesystem to fill partition..."
            if resize2fs "$ROOT_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Filesystem expanded"
            else
                log_error "Failed to expand filesystem"
                exit 1
            fi
        else
            log_warn "Skipping online filesystem shrink on mounted ext* root"
            log_warn "Partition table was updated to a smaller root size; schedule a reboot and fsck"
            log_warn "If the filesystem had allocated blocks beyond the new end, corruption is possible"
        fi
        ;;
    xfs)
        # XFS can only grow
        if [ "$DISK_LAYOUT" = "minimal_root" ]; then
            log_info "Growing XFS filesystem..."
            if xfs_growfs / 2>&1 | tee -a "$LOG_FILE"; then
                log_success "XFS filesystem grown"
            else
                log_error "Failed to grow XFS filesystem"
                exit 1
            fi
        else
            log_error "Cannot shrink XFS filesystem"
            exit 1
        fi
        ;;
    btrfs)
        if [ "$DISK_LAYOUT" = "minimal_root" ]; then
            log_info "Growing btrfs filesystem..."
            if btrfs filesystem resize max / 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Btrfs filesystem grown"
            else
                log_error "Failed to grow btrfs filesystem"
                exit 1
            fi
        else
            log_info "Shrinking btrfs filesystem..."
            TARGET_SIZE=$((NEW_ROOT_SIZE_SECTORS * 512))
            if btrfs filesystem resize "${TARGET_SIZE}" / 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Btrfs filesystem shrunk"
            else
                log_error "Failed to shrink btrfs filesystem"
                exit 1
            fi
        fi
        ;;
    *)
        log_error "Unsupported filesystem: $FS_TYPE"
        exit 1
        ;;
esac

# Format and enable swap partitions
log_step "Formatting and enabling swap partitions..."

for i in $(seq 1 "$OPTIMAL_DEVICES"); do
    SWAP_PART_NUM=$((ROOT_PART_NUM + i))
    
    if [[ "$ROOT_DISK" =~ nvme ]]; then
        SWAP_PARTITION="/dev/${ROOT_DISK}p${SWAP_PART_NUM}"
    else
        SWAP_PARTITION="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
    fi
    
    log_info "Processing swap partition ${i}/${OPTIMAL_DEVICES}: ${SWAP_PARTITION}"
    
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
    PARTUUID=$(blkid -s PARTUUID -o value "$SWAP_PARTITION" 2>/dev/null)
    if [ -n "$PARTUUID" ]; then
        if ! grep -q "$PARTUUID" /etc/fstab 2>/dev/null; then
            echo "PARTUUID=${PARTUUID} none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
            log_info "Added swap ${i} to /etc/fstab (PARTUUID=${PARTUUID})"
        else
            log_info "Swap ${i} already in /etc/fstab"
        fi
    else
        log_warn "No PARTUUID found for ${SWAP_PARTITION}, using device path"
        if ! grep -q "$SWAP_PARTITION" /etc/fstab 2>/dev/null; then
            echo "${SWAP_PARTITION} none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
            log_info "Added swap ${i} to /etc/fstab (device path)"
        fi
    fi
done

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
log_info "Created ${OPTIMAL_DEVICES} swap partitions of ${PER_DEVICE_GB}GB each"
log_info "Total swap: ${TOTAL_SWAP_GB}GB"
log_info "Backup partition table: $BACKUP_FILE"
log_info "Log file: $LOG_FILE"

echo ""
log_info "Next steps:"
log_info "  1. Verify: swapon --show"
log_info "  2. Test: free -h"
log_info "  3. If using ZSWAP, configure: sudo ./setup-swap.sh"
log_info "  4. Run latency tests: sudo ./benchmark.py --test-zswap-latency"
