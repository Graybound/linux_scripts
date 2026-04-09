#!/usr/bin/env bash
#
# ============================================================
# Auto Security Maintenance Script
# ============================================================
#
# Purpose:
#   Automatically configure and maintain security updates only
#   across most Linux distributions in a safe, unattended way.
#
# Supported OS families:
#   - Debian, Ubuntu, Linux Mint, DietPi
#   - RHEL, Rocky, Alma, CentOS Stream
#   - Fedora
#
# What this script does:
#   - Enables vendor-supported automatic SECURITY updates only
#   - Performs safe disk cleanup before updates
#   - Skips updates if disk space is critically low
#   - Protects kernels and boot-critical packages
#   - Optionally schedules automatic reboots if required
#
# What this script intentionally does NOT do:
#   - No distro upgrades
#   - No feature updates
#   - No forced reboots unless explicitly enabled
#   - No Hypervisor host support
#
# Safe to run multiple times.
#
# Designed to be run via:
#   curl -fsSL <url> | sudo bash
#
# ============================================================

set -euo pipefail
IFS=$'\n\t'
PATH=/usr/sbin:/usr/bin:/sbin:/bin

LOG="/var/log/auto-security-maintenance.log"
exec >> "$LOG" 2>&1

echo "=== Auto security maintenance started at $(date) ==="

# ============================================================
# USER CONFIGURATION
# ============================================================

# Minimum free space (MB) required to proceed with updates
MIN_FREE_MB=512

# Automatic reboot control
# Set to "true" to allow automatic reboots when required
AUTO_REBOOT="false"

# Reboot schedule if AUTO_REBOOT is true
# Format examples:
#   Daily at 23:00        "*-*-* 23:00"
#   Sundays at 03:00     "Sun *-*-* 03:00"
#   First day monthly    "*-*-01 02:00"
AUTO_REBOOT_ONCALENDAR="*-*-* 23:00"

# ============================================================
# FUNCTIONS
# ============================================================

free_mb() {
    df -Pm / | awk 'NR==2 {print $4}'
}

cleanup_disk() {
    echo "Running disk cleanup"

    if command -v apt >/dev/null; then
        apt clean || true
        apt autoclean || true
        apt autoremove -y || true
    fi

    if command -v dnf >/dev/null; then
        dnf clean all || true
    fi

    if command -v yum >/dev/null; then
        yum clean all || true
    fi

    find /var/log -type f -name "*.log" -size +20M -exec truncate -s 0 {} \; || true
}

require_space_or_exit() {
    if [ "$(free_mb)" -lt "$MIN_FREE_MB" ]; then
        echo "Insufficient disk space, attempting cleanup"
        cleanup_disk
    fi

    if [ "$(free_mb)" -lt "$MIN_FREE_MB" ]; then
        echo "Disk space still below threshold, aborting safely"
        exit 0
    fi
}

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root"
    exit 1
fi

require_space_or_exit

# ============================================================
# OS DETECTION
# ============================================================

OS_FAMILY="unknown"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        debian|ubuntu|linuxmint|dietpi)
            OS_FAMILY="debian"
            ;;
        rhel|rocky|almalinux|centos)
            OS_FAMILY="rhel"
            ;;
        fedora)
            OS_FAMILY="fedora"
            ;;
    esac
fi

echo "Detected OS family: $OS_FAMILY"

# ============================================================
# DEBIAN FAMILY CONFIGURATION
# ============================================================

if [ "$OS_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive

    apt update
    apt install -y unattended-upgrades apt-listchanges

    apt-mark manual linux-image-amd64 linux-generic 2>/dev/null || true

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

    if grep -qi ubuntu /etc/os-release; then
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Origins-Pattern {
    "origin=Ubuntu,codename=\${distro_codename},label=Ubuntu-Security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$AUTO_REBOOT";
Unattended-Upgrade::Automatic-Reboot-Time "00:00";
EOF
    else
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=\${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$AUTO_REBOOT";
Unattended-Upgrade::Automatic-Reboot-Time "00:00";
EOF
    fi

    systemctl enable unattended-upgrades

    if [ "$AUTO_REBOOT" = "true" ]; then
        mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
        cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<EOF
[Timer]
OnCalendar=$AUTO_REBOOT_ONCALENDAR
RandomizedDelaySec=0
EOF
        systemctl daemon-reexec
        systemctl restart apt-daily-upgrade.timer
    fi
fi

# ============================================================
# RHEL AND FEDORA FAMILY CONFIGURATION
# ============================================================

if [ "$OS_FAMILY" = "rhel" ] || [ "$OS_FAMILY" = "fedora" ]; then
    dnf install -y dnf-automatic

    sed -i \
        -e 's/^apply_updates.*/apply_updates = yes/' \
        -e 's/^upgrade_type.*/upgrade_type = security/' \
        -e 's/^random_sleep.*/random_sleep = 0/' \
        /etc/dnf/automatic.conf

    systemctl enable --now dnf-automatic.timer

    if [ "$AUTO_REBOOT" = "true" ]; then
        mkdir -p /etc/systemd/system/dnf-automatic.timer.d
        cat > /etc/systemd/system/dnf-automatic.timer.d/override.conf <<EOF
[Timer]
OnCalendar=$AUTO_REBOOT_ONCALENDAR
RandomizedDelaySec=0
EOF
        systemctl daemon-reexec
        systemctl restart dnf-automatic.timer
    fi
fi

echo "=== Auto security maintenance completed at $(date) ==="