#!/usr/bin/env bash
# ============================================================
#  Auto Disk Expand - Ubuntu / Debian
#  Detects unallocated space and expands partitions/filesystems
#  automatically. Supports standard ext4/xfs/btrfs and LVM.
#  Run as root. No user interaction required.
# ============================================================

set -euo pipefail

# ---------- colours ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- root check ----------
[[ $EUID -ne 0 ]] && error "Please run as root (sudo)."

# ---------- install dependencies ----------
info "Checking dependencies..."
DEPS=(cloud-guest-utils parted util-linux)
for pkg in "${DEPS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || {
        info "Installing $pkg..."
        apt-get install -y -qq "$pkg"
    }
done
success "Dependencies satisfied."

# ---------- find disk with unallocated space ----------
info "Scanning for disks with unallocated space..."
TARGET_DISK=""
TARGET_PART_NUM=""

for disk in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
    DISK_PATH="/dev/$disk"
    DISK_BYTES=$(blockdev --getsize64 "$DISK_PATH" 2>/dev/null) || continue

    # Get the end byte of the last partition on this disk
    LAST_END=$(parted -s "$DISK_PATH" unit B print 2>/dev/null \
        | awk '/^ [0-9]/{print $3}' \
        | tr -d 'B' \
        | sort -n \
        | tail -1)

    [[ -z "$LAST_END" ]] && continue

    # Check if there is more than 100 MB of unallocated space
    UNALLOC=$(( DISK_BYTES - LAST_END ))
    if (( UNALLOC > 104857600 )); then
        info "Found ~$(( UNALLOC / 1024 / 1024 )) MB unallocated on $DISK_PATH"
        TARGET_DISK="$DISK_PATH"
        TARGET_PART_NUM=$(parted -s "$DISK_PATH" print 2>/dev/null \
            | awk '/^ [0-9]/{print $1}' \
            | tail -1)
        break
    fi
done

[[ -z "$TARGET_DISK" ]] && error "No disk with unallocated space found (>100 MB threshold)."
TARGET_PART="${TARGET_DISK}${TARGET_PART_NUM}"

# Handle nvme/mmcblk partition naming (e.g. nvme0n1p1)
if [[ "$TARGET_DISK" == *"nvme"* || "$TARGET_DISK" == *"mmcblk"* ]]; then
    TARGET_PART="${TARGET_DISK}p${TARGET_PART_NUM}"
fi

success "Target disk: $TARGET_DISK  |  Partition: $TARGET_PART"

# ---------- grow the partition ----------
info "Expanding partition $TARGET_PART_NUM on $TARGET_DISK..."
growpart "$TARGET_DISK" "$TARGET_PART_NUM" \
    && success "Partition expanded." \
    || warn "growpart returned non-zero — partition may already be at full size."

# Inform the kernel of the partition table change
partprobe "$TARGET_DISK" 2>/dev/null || true
sleep 1

# ---------- detect LVM ----------
IS_LVM=false
LVM_VG="" ; LVM_LV="" ; LVM_LV_PATH=""

if pvs "$TARGET_PART" &>/dev/null; then
    IS_LVM=true
    info "LVM detected on $TARGET_PART"

    info "Resizing physical volume..."
    pvresize "$TARGET_PART"
    success "Physical volume resized."

    LVM_VG=$(pvs --noheadings -o vg_name "$TARGET_PART" | tr -d ' ')
    LVM_LV=$(lvs --noheadings -o lv_name,vg_name \
        | awk -v vg="$LVM_VG" '$2==vg{print $1}' \
        | head -1)
    LVM_LV_PATH="/dev/${LVM_VG}/${LVM_LV}"

    info "Extending logical volume $LVM_LV_PATH..."
    lvextend -l +100%FREE "$LVM_LV_PATH"
    success "Logical volume extended."

    RESIZE_TARGET="$LVM_LV_PATH"
else
    RESIZE_TARGET="$TARGET_PART"
fi

# ---------- detect filesystem and resize ----------
FS_TYPE=$(blkid -o value -s TYPE "$RESIZE_TARGET" 2>/dev/null || echo "unknown")
info "Filesystem detected: ${BOLD}${FS_TYPE}${NC}"

case "$FS_TYPE" in
    ext2|ext3|ext4)
        info "Running resize2fs on $RESIZE_TARGET..."
        resize2fs "$RESIZE_TARGET"
        success "ext filesystem resized successfully."
        ;;
    xfs)
        MOUNT_POINT=$(findmnt -n -o TARGET "$RESIZE_TARGET" 2>/dev/null || echo "/")
        info "Running xfs_growfs on $MOUNT_POINT..."
        xfs_growfs "$MOUNT_POINT"
        success "XFS filesystem resized successfully."
        ;;
    btrfs)
        MOUNT_POINT=$(findmnt -n -o TARGET "$RESIZE_TARGET" 2>/dev/null || echo "/")
        info "Running btrfs filesystem resize on $MOUNT_POINT..."
        btrfs filesystem resize max "$MOUNT_POINT"
        success "Btrfs filesystem resized successfully."
        ;;
    *)
        warn "Filesystem type '$FS_TYPE' not automatically handled."
        warn "Manually resize the filesystem on $RESIZE_TARGET."
        ;;
esac

# ---------- summary ----------
echo ""
echo -e "${BOLD}===== Disk Usage After Resize =====${NC}"
df -h "$RESIZE_TARGET" 2>/dev/null || df -h /
echo -e "${BOLD}===================================${NC}"
success "All done!"