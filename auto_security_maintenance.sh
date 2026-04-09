#!/usr/bin/env bash
#
# ============================================================
# Auto Security Maintenance Script
# ============================================================
#
# Purpose:
#   Configure and maintain automatic security-only updates
#   across most Linux distributions in a safe, unattended way.
#
# Supported OS families:
#   - Debian, Ubuntu, Linux Mint, Raspberry Pi OS, Pop!_OS,
#     DietPi, Elementary, Zorin, Kali, MX Linux
#   - RHEL, Rocky, Alma, CentOS Stream, Oracle Linux
#   - Fedora
#
# Usage:
#   sudo ./auto_security_maintenance.sh [OPTION]
#
# Options:
#   --setup, -s       Interactive setup wizard (default when a terminal is available)
#   --run, -r         Run maintenance cycle (used by systemd timer)
#   --status          Show current configuration and service health
#   --uninstall       Remove all installed components
#   --help, -h        Show usage information
#
# Also works via:
#   curl -fsSL https://github.com/Graybound/linux_scripts/blob/main/auto_security_maintenance.sh | sudo bash
#   curl -fsSL https://github.com/Graybound/linux_scripts/blob/main/auto_security_maintenance.sh | sudo bash -s -- --status
#
# Safe to run multiple times. Re-running --setup overwrites the
# previous configuration.
#
# ============================================================

set -euo pipefail
IFS=$'\n\t'
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ============================================================
# CONSTANTS
# ============================================================

readonly SCRIPT_NAME="auto-security-maintenance"
readonly CONFIG_FILE="/etc/${SCRIPT_NAME}.conf"
readonly LOG_FILE="/var/log/${SCRIPT_NAME}.log"
readonly LOCK_FILE="/var/run/${SCRIPT_NAME}.lock"
readonly SCRIPT_INSTALL_PATH="/usr/local/sbin/${SCRIPT_NAME}"
readonly REBOOT_SERVICE="${SCRIPT_NAME}-reboot"
readonly REBOOT_CHECK_SCRIPT="/usr/local/sbin/${SCRIPT_NAME}-check-reboot"

# ============================================================
# DEFAULT CONFIGURATION
# ============================================================

MIN_FREE_MB=512
AUTO_REBOOT="false"
REBOOT_SCHEDULE="daily"
REBOOT_TIME="03:00"
REBOOT_DAY="Sun"
REBOOT_ONCALENDAR=""
CLEANUP_PKG_CACHE="true"
CLEANUP_OLD_LOGS="true"
CLEANUP_JOURNAL="true"
CLEANUP_TMP="false"
CLEANUP_CRASH="true"
CLEANUP_CUSTOM_PATHS=""
UPDATE_TIME="06:00"

# Detected at runtime (not user-configurable)
OS_FAMILY="unknown"
OS_NAME="Unknown Linux"
OS_ID=""
IS_DIETPI="false"

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

msg() {
    # Print to terminal and log
    echo "$*"
    log "$*"
}

die() {
    echo "ERROR: $*" >&2
    log "FATAL: $*"
    exit 1
}

bool_to_onoff() {
    [ "${1:-false}" = "true" ] && echo "ON" || echo "OFF"
}

# ============================================================
# OS DETECTION
# ============================================================

detect_os() {
    OS_FAMILY="unknown"
    OS_NAME="Unknown Linux"
    OS_ID=""
    IS_DIETPI="false"

    if [ ! -f /etc/os-release ]; then
        return
    fi

    # shellcheck source=/dev/null
    . /etc/os-release
    OS_NAME="${PRETTY_NAME:-${NAME:-Unknown}}"
    OS_ID="${ID:-}"

    # DietPi detection (works even when ID=debian)
    if [ -f /boot/dietpi/.version ] || [ "$OS_ID" = "dietpi" ]; then
        IS_DIETPI="true"
    fi

    # Primary match on ID
    case "$OS_ID" in
        debian|ubuntu|linuxmint|raspbian|dietpi|pop|elementary|zorin|kali|mx|parrot)
            OS_FAMILY="debian"
            ;;
        rhel|rocky|almalinux|centos|ol|scientific)
            OS_FAMILY="rhel"
            ;;
        fedora)
            OS_FAMILY="fedora"
            ;;
        *)
            # Fallback to ID_LIKE for derivatives
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*)
                    OS_FAMILY="debian"
                    ;;
                *rhel*|*fedora*|*centos*)
                    OS_FAMILY="rhel"
                    ;;
            esac
            ;;
    esac
}

# ============================================================
# TUI FUNCTIONS
# ============================================================

TUI_CMD=""

detect_tui() {
    # A graphical TUI (whiptail/dialog) needs a capable terminal.
    # If TERM is missing, empty, or "dumb", ncurses cannot draw and
    # the tool hangs on a blank screen.  Fall back to plain text.
    local term_ok="false"
    case "${TERM:-dumb}" in
        dumb|"") term_ok="false" ;;
        *)       term_ok="true"  ;;
    esac

    if [ "$term_ok" = "true" ] && command -v whiptail >/dev/null 2>&1; then
        # Quick smoke-test: whiptail --version exits 0 when functional
        if whiptail --version </dev/tty >/dev/null 2>&1; then
            TUI_CMD="whiptail"
            return
        fi
    fi

    if [ "$term_ok" = "true" ] && command -v dialog >/dev/null 2>&1; then
        if dialog --version </dev/tty >/dev/null 2>&1; then
            TUI_CMD="dialog"
            return
        fi
    fi

    TUI_CMD="plain"
}

tui_msgbox() {
    local title="$1" text="$2"
    case "$TUI_CMD" in
        whiptail|dialog)
            "$TUI_CMD" --title "$title" --msgbox "$text" 14 70 </dev/tty
            ;;
        plain)
            {
                echo ""
                echo "========================================"
                echo "  $title"
                echo "========================================"
                echo ""
                echo -e "$text"
                echo ""
            } >/dev/tty
            read -rp "Press Enter to continue... " </dev/tty >/dev/tty
            ;;
    esac
}

# Returns 0 for yes, 1 for no
tui_yesno() {
    local title="$1" text="$2" default="${3:-yes}"
    case "$TUI_CMD" in
        whiptail|dialog)
            local extra_flag=""
            [ "$default" = "no" ] && extra_flag="--defaultno"
            # shellcheck disable=SC2086
            "$TUI_CMD" --title "$title" $extra_flag --yesno "$text" 12 70 </dev/tty
            return $?
            ;;
        plain)
            local yn="Y/n"
            [ "$default" = "no" ] && yn="y/N"
            {
                echo ""
                echo "--- $title ---"
                echo -e "$text"
            } >/dev/tty
            local answer
            read -rp "[$yn]: " answer </dev/tty >/dev/tty
            case "$answer" in
                [Yy]*) return 0 ;;
                [Nn]*) return 1 ;;
                "")
                    [ "$default" = "no" ] && return 1 || return 0
                    ;;
                *) return 1 ;;
            esac
            ;;
    esac
}

# Prints the selected tag to stdout
tui_menu() {
    local title="$1" text="$2"
    shift 2
    local count=$(( $# / 2 ))
    local height=$(( count + 10 ))
    [ "$height" -gt 22 ] && height=22

    case "$TUI_CMD" in
        whiptail)
            whiptail --title "$title" --menu "$text" "$height" 70 "$count" "$@" 3>&1 1>&2 2>&3 </dev/tty
            ;;
        dialog)
            dialog --title "$title" --menu "$text" "$height" 70 "$count" "$@" 3>&1 1>&2 2>&3 </dev/tty
            ;;
        plain)
            {
                echo ""
                echo "--- $title ---"
                echo -e "$text"
                echo ""
            } >/dev/tty
            local i=1
            local -a tags=()
            while [ $# -ge 2 ]; do
                echo "  $1) $2" >/dev/tty
                tags+=("$1")
                shift 2
            done
            echo "" >/dev/tty
            local choice
            read -rp "Selection [${tags[0]}]: " choice </dev/tty >/dev/tty
            choice="${choice:-${tags[0]}}"
            echo "$choice"
            ;;
    esac
}

# Prints space-separated quoted tags to stdout
tui_checklist() {
    local title="$1" text="$2"
    shift 2
    local count=$(( $# / 3 ))
    local height=$(( count + 10 ))
    [ "$height" -gt 22 ] && height=22

    case "$TUI_CMD" in
        whiptail)
            whiptail --title "$title" --checklist "$text" "$height" 70 "$count" "$@" 3>&1 1>&2 2>&3 </dev/tty
            ;;
        dialog)
            dialog --title "$title" --checklist "$text" "$height" 70 "$count" "$@" 3>&1 1>&2 2>&3 </dev/tty
            ;;
        plain)
            {
                echo ""
                echo "--- $title ---"
                echo -e "$text"
                echo ""
            } >/dev/tty
            local selections=""
            while [ $# -ge 3 ]; do
                local tag="$1" item="$2" status="$3"
                local default_hint="n"
                [ "$status" = "ON" ] && default_hint="Y"
                local answer
                read -rp "  [$( [ "$status" = "ON" ] && echo "x" || echo " " )] $item ($tag) — keep? [${default_hint}]: " answer </dev/tty >/dev/tty
                case "$answer" in
                    [Yy]*) selections="$selections \"$tag\"" ;;
                    [Nn]*) ;;
                    "")
                        [ "$status" = "ON" ] && selections="$selections \"$tag\""
                        ;;
                esac
                shift 3
            done
            echo "$selections"
            ;;
    esac
}

tui_inputbox() {
    local title="$1" text="$2" default="$3"
    case "$TUI_CMD" in
        whiptail)
            whiptail --title "$title" --inputbox "$text" 10 70 "$default" 3>&1 1>&2 2>&3 </dev/tty
            ;;
        dialog)
            dialog --title "$title" --inputbox "$text" 10 70 "$default" 3>&1 1>&2 2>&3 </dev/tty
            ;;
        plain)
            {
                echo ""
                echo "--- $title ---"
            } >/dev/tty
            local answer
            read -rp "$text [$default]: " answer </dev/tty >/dev/tty
            echo "${answer:-$default}"
            ;;
    esac
}

# ============================================================
# CONFIG FILE
# ============================================================

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# Auto Security Maintenance Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Re-run setup: sudo ${SCRIPT_INSTALL_PATH} --setup

MIN_FREE_MB=${MIN_FREE_MB}
AUTO_REBOOT=${AUTO_REBOOT}
REBOOT_SCHEDULE=${REBOOT_SCHEDULE}
REBOOT_TIME=${REBOOT_TIME}
REBOOT_DAY=${REBOOT_DAY}
REBOOT_ONCALENDAR=${REBOOT_ONCALENDAR}
CLEANUP_PKG_CACHE=${CLEANUP_PKG_CACHE}
CLEANUP_OLD_LOGS=${CLEANUP_OLD_LOGS}
CLEANUP_JOURNAL=${CLEANUP_JOURNAL}
CLEANUP_TMP=${CLEANUP_TMP}
CLEANUP_CRASH=${CLEANUP_CRASH}
CLEANUP_CUSTOM_PATHS=${CLEANUP_CUSTOM_PATHS}
UPDATE_TIME=${UPDATE_TIME}
EOF
    chmod 600 "$CONFIG_FILE"
    log "Configuration saved to $CONFIG_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
        log "Configuration loaded from $CONFIG_FILE"
    fi
}

# ============================================================
# DISK MANAGEMENT
# ============================================================

free_mb() {
    df -Pm / | awk 'NR==2 {print $4}'
}

cleanup_disk() {
    log "Running disk cleanup..."

    # Package manager caches
    if [ "${CLEANUP_PKG_CACHE}" = "true" ]; then
        log "  Cleaning package manager cache"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get clean 2>/dev/null || true
            apt-get autoclean 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
        fi
        if command -v dnf >/dev/null 2>&1; then
            dnf clean all 2>/dev/null || true
        elif command -v yum >/dev/null 2>&1; then
            yum clean all 2>/dev/null || true
        fi
    fi

    # Old rotated log files (NOT active logs — only completed rotations)
    if [ "${CLEANUP_OLD_LOGS}" = "true" ]; then
        log "  Removing old rotated log files"
        find /var/log -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.bz2" \
            -o -name "*.1" -o -name "*.[2-9]" -o -name "*.old" \) \
            -mtime +7 -delete 2>/dev/null || true
    fi

    # Systemd journal (safe: uses journalctl's own vacuum)
    if [ "${CLEANUP_JOURNAL}" = "true" ]; then
        if command -v journalctl >/dev/null 2>&1; then
            log "  Vacuuming systemd journal"
            journalctl --vacuum-time=7d 2>/dev/null || true
            journalctl --vacuum-size=200M 2>/dev/null || true
        fi
    fi

    # Temporary files
    if [ "${CLEANUP_TMP}" = "true" ]; then
        log "  Cleaning temporary files"
        find /tmp -type f -atime +7 -delete 2>/dev/null || true
        find /var/tmp -type f -atime +30 -delete 2>/dev/null || true
    fi

    # Crash dumps
    if [ "${CLEANUP_CRASH}" = "true" ]; then
        log "  Removing crash dumps"
        rm -rf /var/crash/* 2>/dev/null || true
        if [ -d /var/lib/systemd/coredump ]; then
            find /var/lib/systemd/coredump -type f -mtime +7 -delete 2>/dev/null || true
        fi
    fi

    # Custom paths
    if [ -n "${CLEANUP_CUSTOM_PATHS}" ]; then
        IFS=',' read -ra custom_paths <<< "$CLEANUP_CUSTOM_PATHS"
        for cpath in "${custom_paths[@]}"; do
            cpath="$(echo "$cpath" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [ -d "$cpath" ]; then
                log "  Cleaning custom path: $cpath"
                find "$cpath" -type f -mtime +7 -delete 2>/dev/null || true
            fi
        done
    fi

    log "Disk cleanup complete. Free space: $(free_mb) MB"
}

require_space_or_exit() {
    local current_free
    current_free="$(free_mb)"

    if [ "$current_free" -lt "$MIN_FREE_MB" ]; then
        log "Low disk space (${current_free} MB free, need ${MIN_FREE_MB} MB). Attempting cleanup..."
        cleanup_disk
    fi

    current_free="$(free_mb)"
    if [ "$current_free" -lt "$MIN_FREE_MB" ]; then
        log "Disk space still below threshold after cleanup (${current_free} MB < ${MIN_FREE_MB} MB). Aborting."
        exit 0
    fi

    log "Disk space OK: ${current_free} MB free (minimum: ${MIN_FREE_MB} MB)"
}

# ============================================================
# SECURITY UPDATE CONFIGURATION — DEBIAN FAMILY
# ============================================================

configure_debian() {
    log "Configuring Debian-family security updates"
    export DEBIAN_FRONTEND=noninteractive

    # Install unattended-upgrades if not present
    if ! dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq unattended-upgrades apt-listchanges >/dev/null 2>&1
    fi

    # Pin kernel metapackage for the actual architecture (only if installed)
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
    for pkg in "linux-image-${arch}" "linux-image-generic" "linux-generic"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            apt-mark manual "$pkg" >/dev/null 2>&1 || true
        fi
    done

    # Enable periodic updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Determine the correct security origin
    local origin label
    case "$OS_ID" in
        ubuntu|pop|elementary|zorin)
            origin="Ubuntu"
            label="Ubuntu-Security"
            ;;
        linuxmint)
            # Mint uses Ubuntu's security repos
            origin="Ubuntu"
            label="Ubuntu-Security"
            ;;
        *)
            # Debian, DietPi, Raspbian, Kali, MX, and other Debian derivatives
            origin="Debian"
            label="Debian-Security"
            ;;
    esac

    # For Debian, also accept the updated codename-security format (Debian 11+)
    local extra_origin=""
    if [ "$origin" = "Debian" ]; then
        extra_origin='    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
    fi

    # Reboot: always disabled in unattended-upgrades config.
    # Reboots are handled by the dedicated reboot timer when enabled.
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Origins-Pattern {
    "origin=${origin},codename=\${distro_codename},label=${label}";
${extra_origin}
};

Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    systemctl enable unattended-upgrades 2>/dev/null || true
    systemctl start unattended-upgrades 2>/dev/null || true

    # DietPi: also set native config if available
    if [ "$IS_DIETPI" = "true" ] && [ -f /boot/dietpi.txt ]; then
        log "DietPi detected — enabling native APT update check"
        if grep -q '^CONFIG_CHECK_APT_UPDATES=' /boot/dietpi.txt; then
            sed -i 's/^CONFIG_CHECK_APT_UPDATES=.*/CONFIG_CHECK_APT_UPDATES=2/' /boot/dietpi.txt
        fi
        # Unmask apt timers if DietPi masked them
        systemctl unmask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
        systemctl enable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
        systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    fi

    log "Debian-family security updates configured (origin=${origin}, label=${label})"
}

# ============================================================
# SECURITY UPDATE CONFIGURATION — RHEL / FEDORA FAMILY
# ============================================================

configure_rhel() {
    log "Configuring RHEL/Fedora-family security updates"

    if ! rpm -q dnf-automatic >/dev/null 2>&1; then
        dnf install -y -q dnf-automatic >/dev/null 2>&1
    fi

    local conf="/etc/dnf/automatic.conf"

    # Ensure the key settings are present and correct, whether
    # the line is commented out, uncommented, or missing entirely.
    for kv in \
        "apply_updates = yes" \
        "upgrade_type = security" \
        "random_sleep = 0"; do
        local key="${kv%% =*}"
        if grep -qE "^#?\s*${key}\s*=" "$conf"; then
            sed -i "s/^#*\s*${key}\s*=.*/${kv}/" "$conf"
        else
            # Append under [commands] section
            sed -i "/^\[commands\]/a ${kv}" "$conf"
        fi
    done

    systemctl enable --now dnf-automatic.timer 2>/dev/null || true

    log "RHEL/Fedora-family security updates configured"
}

# ============================================================
# REBOOT SCHEDULING
# ============================================================

build_oncalendar() {
    # Build a systemd OnCalendar expression from the config
    case "${REBOOT_SCHEDULE}" in
        daily)
            echo "*-*-* ${REBOOT_TIME}:00"
            ;;
        weekly)
            echo "${REBOOT_DAY} *-*-* ${REBOOT_TIME}:00"
            ;;
        monthly)
            echo "*-*-01 ${REBOOT_TIME}:00"
            ;;
        custom)
            echo "${REBOOT_ONCALENDAR:-*-*-* ${REBOOT_TIME}:00}"
            ;;
    esac
}

configure_reboot_timer() {
    if [ "$AUTO_REBOOT" != "true" ]; then
        # Disable and remove any existing reboot timer
        systemctl disable --now "${REBOOT_SERVICE}.timer" 2>/dev/null || true
        rm -f "/etc/systemd/system/${REBOOT_SERVICE}.timer"
        rm -f "/etc/systemd/system/${REBOOT_SERVICE}.service"
        rm -f "$REBOOT_CHECK_SCRIPT"
        rm -rf "/etc/systemd/system/dnf-automatic.service.d/reboot-check.conf"
        systemctl daemon-reload 2>/dev/null || true
        log "Auto-reboot disabled; reboot timer removed"
        return
    fi

    local on_calendar
    on_calendar="$(build_oncalendar)"
    log "Configuring reboot timer: OnCalendar=${on_calendar}"

    # Create a reboot-required check script for RHEL/Fedora
    # (Debian/Ubuntu already create /var/run/reboot-required natively)
    if [ "$OS_FAMILY" = "rhel" ] || [ "$OS_FAMILY" = "fedora" ]; then
        cat > "$REBOOT_CHECK_SCRIPT" <<'REBOOTCHECK'
#!/bin/bash
# Check whether a reboot is required after security updates.
# Creates /var/run/reboot-required if so.
if command -v needs-restarting >/dev/null 2>&1; then
    if ! needs-restarting -r >/dev/null 2>&1; then
        touch /var/run/reboot-required
    fi
else
    running="$(uname -r)"
    installed="$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -1)"
    if [ -n "$installed" ] && [ "$running" != "$installed" ]; then
        touch /var/run/reboot-required
    fi
fi
REBOOTCHECK
        chmod 755 "$REBOOT_CHECK_SCRIPT"

        # Run the check after dnf-automatic finishes
        mkdir -p /etc/systemd/system/dnf-automatic.service.d
        cat > /etc/systemd/system/dnf-automatic.service.d/reboot-check.conf <<EOF
[Service]
ExecStartPost=${REBOOT_CHECK_SCRIPT}
EOF
    fi

    # Service: only reboots if /var/run/reboot-required exists
    cat > "/etc/systemd/system/${REBOOT_SERVICE}.service" <<EOF
[Unit]
Description=Auto Security Maintenance — Conditional Reboot
Documentation=man:shutdown(8)
ConditionPathExists=/var/run/reboot-required

[Service]
Type=oneshot
ExecStart=/sbin/shutdown -r +1 "Automatic reboot after security updates"
EOF

    # Timer: runs on the configured schedule
    cat > "/etc/systemd/system/${REBOOT_SERVICE}.timer" <<EOF
[Unit]
Description=Auto Security Maintenance — Reboot Schedule

[Timer]
OnCalendar=${on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now "${REBOOT_SERVICE}.timer" >/dev/null 2>&1
    log "Reboot timer enabled: ${on_calendar}"
}

# ============================================================
# MAINTENANCE TIMER (for --run mode)
# ============================================================

install_maintenance_timer() {
    log "Installing maintenance script and timer"

    # Copy this script to a stable location
    if [ "$(readlink -f "$0" 2>/dev/null)" != "$SCRIPT_INSTALL_PATH" ]; then
        cp "$0" "$SCRIPT_INSTALL_PATH" 2>/dev/null || {
            # If $0 is /dev/stdin (curl pipe), write from /proc
            if [ -f /proc/$$/fd/255 ]; then
                cp /proc/$$/fd/255 "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
            fi
        }
    fi

    # Ensure the installed script is executable
    if [ -f "$SCRIPT_INSTALL_PATH" ]; then
        chmod 755 "$SCRIPT_INSTALL_PATH"
    fi

    # Systemd service
    cat > "/etc/systemd/system/${SCRIPT_NAME}.service" <<EOF
[Unit]
Description=Auto Security Maintenance — Pre-Update Cleanup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_INSTALL_PATH} --run
Nice=10
IOSchedulingClass=idle
EOF

    # Systemd timer — runs before the native update tools
    cat > "/etc/systemd/system/${SCRIPT_NAME}.timer" <<EOF
[Unit]
Description=Auto Security Maintenance — Daily Cleanup Timer

[Timer]
OnCalendar=*-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now "${SCRIPT_NAME}.timer" >/dev/null 2>&1
    log "Maintenance timer installed (daily at ${UPDATE_TIME})"
}

# ============================================================
# MODE: SETUP (interactive TUI wizard)
# ============================================================

mode_setup() {
    # Ensure we have a terminal for interactive input
    if [ ! -e /dev/tty ]; then
        die "No terminal available for interactive setup. Run with --help for options."
    fi

    detect_tui
    detect_os
    load_config  # Load existing config as defaults

    # --- Welcome ---
    tui_msgbox "Auto Security Maintenance Setup" \
"Welcome! This wizard configures automatic security
updates for your system.

Detected OS: ${OS_NAME}
OS Family:   ${OS_FAMILY}$( [ "$IS_DIETPI" = "true" ] && echo "  (DietPi)" )

What this sets up:
 - Security patches only (no distro upgrades)
 - Disk cleanup before updates
 - Optional automatic reboots

Safe to run again to change settings."

    if [ "$OS_FAMILY" = "unknown" ]; then
        tui_msgbox "Unsupported OS" \
"Your operating system could not be identified
or is not currently supported.

Supported families:
  Debian, Ubuntu, DietPi, Mint, Raspberry Pi OS
  RHEL, Rocky, Alma, CentOS Stream, Oracle Linux
  Fedora"
        exit 1
    fi

    # --- Auto Reboot ---
    if tui_yesno "Automatic Reboots" \
"Enable automatic reboots when a security update
requires one (e.g., kernel updates)?

Reboots only happen if the system flags a restart
as needed. They will never be forced otherwise." "no"; then
        AUTO_REBOOT="true"

        # Schedule type
        REBOOT_SCHEDULE=$(tui_menu "Reboot Frequency" \
            "How often should the system check for pending reboots?" \
            "daily"   "Every day at a set time" \
            "weekly"  "Once a week on a chosen day" \
            "monthly" "First day of each month") || REBOOT_SCHEDULE="daily"

        # Day of week (weekly only)
        if [ "$REBOOT_SCHEDULE" = "weekly" ]; then
            REBOOT_DAY=$(tui_menu "Reboot Day" \
                "Which day of the week?" \
                "Mon" "Monday"    \
                "Tue" "Tuesday"   \
                "Wed" "Wednesday" \
                "Thu" "Thursday"  \
                "Fri" "Friday"    \
                "Sat" "Saturday"  \
                "Sun" "Sunday") || REBOOT_DAY="Sun"
        fi

        # Reboot time
        REBOOT_TIME=$(tui_inputbox "Reboot Time" \
            "What time should reboots occur? (24-hour format HH:MM)" \
            "${REBOOT_TIME}") || REBOOT_TIME="03:00"

    else
        AUTO_REBOOT="false"
    fi

    # --- Cleanup Locations ---
    local cleanup_result
    cleanup_result=$(tui_checklist "Disk Cleanup Locations" \
"Select locations that are safe to clean when disk
space is low. Cleanup runs before each update check." \
        "pkg_cache" "Package manager cache (apt/dnf)" "$(bool_to_onoff "$CLEANUP_PKG_CACHE")" \
        "old_logs"  "Old rotated logs in /var/log"    "$(bool_to_onoff "$CLEANUP_OLD_LOGS")" \
        "journal"   "Systemd journal (keep 7 days)"   "$(bool_to_onoff "$CLEANUP_JOURNAL")" \
        "tmp"       "Temp files (/tmp, /var/tmp)"      "$(bool_to_onoff "$CLEANUP_TMP")" \
        "crash"     "Crash dumps (/var/crash)"         "$(bool_to_onoff "$CLEANUP_CRASH")") || cleanup_result=""

    # Parse checklist results
    CLEANUP_PKG_CACHE="false"
    CLEANUP_OLD_LOGS="false"
    CLEANUP_JOURNAL="false"
    CLEANUP_TMP="false"
    CLEANUP_CRASH="false"
    [[ "$cleanup_result" == *pkg_cache* ]] && CLEANUP_PKG_CACHE="true"
    [[ "$cleanup_result" == *old_logs* ]]  && CLEANUP_OLD_LOGS="true"
    [[ "$cleanup_result" == *journal* ]]   && CLEANUP_JOURNAL="true"
    [[ "$cleanup_result" == *tmp* ]]       && CLEANUP_TMP="true"
    [[ "$cleanup_result" == *crash* ]]     && CLEANUP_CRASH="true"

    # Custom cleanup paths
    if tui_yesno "Custom Cleanup Paths" \
"Do you have additional directories that are safe
to clean when disk space is low?

(e.g., /home/backups/old, /opt/logs/archive)" "no"; then
        CLEANUP_CUSTOM_PATHS=$(tui_inputbox "Custom Paths" \
            "Enter comma-separated directory paths:" \
            "${CLEANUP_CUSTOM_PATHS}") || CLEANUP_CUSTOM_PATHS=""
    fi

    # --- Minimum Free Space ---
    MIN_FREE_MB=$(tui_inputbox "Minimum Free Space" \
"Minimum free disk space (in MB) required before
updates will run. If space is below this after
cleanup, the update is skipped." \
        "${MIN_FREE_MB}") || MIN_FREE_MB=512

    # --- Update Schedule ---
    UPDATE_TIME=$(tui_inputbox "Daily Update Time" \
"When should the daily maintenance check run?
(24-hour format HH:MM)

This runs cleanup and checks for pending updates." \
        "${UPDATE_TIME}") || UPDATE_TIME="06:00"

    # --- Confirmation Summary ---
    local reboot_summary="Disabled"
    if [ "$AUTO_REBOOT" = "true" ]; then
        case "$REBOOT_SCHEDULE" in
            daily)   reboot_summary="Daily at ${REBOOT_TIME}" ;;
            weekly)  reboot_summary="Every ${REBOOT_DAY} at ${REBOOT_TIME}" ;;
            monthly) reboot_summary="1st of month at ${REBOOT_TIME}" ;;
        esac
    fi

    local cleanup_list=""
    [ "$CLEANUP_PKG_CACHE" = "true" ] && cleanup_list="${cleanup_list}  - Package cache\n"
    [ "$CLEANUP_OLD_LOGS" = "true" ]  && cleanup_list="${cleanup_list}  - Old rotated logs\n"
    [ "$CLEANUP_JOURNAL" = "true" ]   && cleanup_list="${cleanup_list}  - Systemd journal\n"
    [ "$CLEANUP_TMP" = "true" ]       && cleanup_list="${cleanup_list}  - Temp files\n"
    [ "$CLEANUP_CRASH" = "true" ]     && cleanup_list="${cleanup_list}  - Crash dumps\n"
    [ -n "$CLEANUP_CUSTOM_PATHS" ]    && cleanup_list="${cleanup_list}  - Custom: ${CLEANUP_CUSTOM_PATHS}\n"
    [ -z "$cleanup_list" ]            && cleanup_list="  (none)\n"

    if ! tui_yesno "Confirm & Apply" \
"Ready to apply these settings?

OS:             ${OS_NAME}
Auto Reboot:    ${reboot_summary}
Update Check:   Daily at ${UPDATE_TIME}
Min Free Space: ${MIN_FREE_MB} MB

Cleanup locations:
${cleanup_list}
Proceed?"; then
        tui_msgbox "Cancelled" "No changes were made."
        exit 0
    fi

    # --- Apply everything (all command output goes to log only) ---
    # Show a progress indicator while configuration runs
    case "$TUI_CMD" in
        whiptail|dialog)
            {
                save_config
                case "$OS_FAMILY" in
                    debian)  configure_debian ;;
                    rhel)    configure_rhel ;;
                    fedora)  configure_rhel ;;
                esac
                configure_reboot_timer
                install_maintenance_timer
            } >> "$LOG_FILE" 2>&1 &
            local apply_pid=$!
            # Show a non-blocking info box while the background work runs
            (
                local pct=0
                while kill -0 "$apply_pid" 2>/dev/null; do
                    pct=$(( pct + 2 ))
                    [ "$pct" -gt 90 ] && pct=90
                    echo "$pct"
                    sleep 1
                done
                echo 100
            ) | "$TUI_CMD" --title "Applying" --gauge \
                "Configuring security updates...\nThis may take a moment." 8 50 0 </dev/tty
            wait "$apply_pid" || true
            ;;
        plain)
            echo "Configuring security updates... " >/dev/tty
            {
                save_config
                case "$OS_FAMILY" in
                    debian)  configure_debian ;;
                    rhel)    configure_rhel ;;
                    fedora)  configure_rhel ;;
                esac
                configure_reboot_timer
                install_maintenance_timer
            } >> "$LOG_FILE" 2>&1
            echo "done." >/dev/tty
            ;;
    esac

    log "Setup completed successfully"

    # Final success message
    local final_msg
    final_msg="Auto security maintenance is now active!

  Security updates: Daily at ${UPDATE_TIME}
  Auto reboot:      ${reboot_summary}

  Config file: ${CONFIG_FILE}
  Log file:    ${LOG_FILE}

  To change settings:
    sudo ${SCRIPT_INSTALL_PATH} --setup

  To check status:
    sudo ${SCRIPT_INSTALL_PATH} --status"

    tui_msgbox "Setup Complete" "$final_msg"
}

# ============================================================
# MODE: RUN (automated, called by systemd timer)
# ============================================================

mode_run() {
    # Acquire an exclusive lock to prevent concurrent runs
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "Another instance is already running. Exiting."
        exit 0
    fi

    log "=== Maintenance run started ==="

    load_config
    detect_os

    if [ "$OS_FAMILY" = "unknown" ]; then
        log "Unsupported OS — skipping maintenance"
        exit 1
    fi

    require_space_or_exit

    # Trigger an update check via the native tool
    case "$OS_FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq 2>/dev/null || true
            # unattended-upgrades runs on its own timer; we can also
            # trigger a manual run for immediate effect
            if command -v unattended-upgrades >/dev/null 2>&1; then
                unattended-upgrades -v 2>&1 || true
            fi
            ;;
        rhel|fedora)
            if command -v dnf-automatic >/dev/null 2>&1; then
                dnf-automatic 2>&1 || true
            fi
            ;;
    esac

    log "=== Maintenance run completed ==="
}

# ============================================================
# MODE: STATUS
# ============================================================

mode_status() {
    detect_os
    load_config

    echo "========================================"
    echo "  Auto Security Maintenance — Status"
    echo "========================================"
    echo ""
    echo "System"
    echo "  OS:           ${OS_NAME}"
    echo "  OS Family:    ${OS_FAMILY}"
    [ "$IS_DIETPI" = "true" ] && echo "  DietPi:       Yes"
    echo "  Architecture: $(uname -m)"
    echo "  Disk free:    $(free_mb) MB on /"
    echo ""

    if [ -f "$CONFIG_FILE" ]; then
        echo "Configuration (${CONFIG_FILE})"
        echo "  Min Free Space: ${MIN_FREE_MB} MB"
        echo "  Update Time:    Daily at ${UPDATE_TIME}"
        echo "  Auto Reboot:    ${AUTO_REBOOT}"
        if [ "$AUTO_REBOOT" = "true" ]; then
            local sched_desc=""
            case "$REBOOT_SCHEDULE" in
                daily)   sched_desc="Daily at ${REBOOT_TIME}" ;;
                weekly)  sched_desc="Every ${REBOOT_DAY} at ${REBOOT_TIME}" ;;
                monthly) sched_desc="1st of month at ${REBOOT_TIME}" ;;
                custom)  sched_desc="${REBOOT_ONCALENDAR}" ;;
            esac
            echo "  Reboot Sched:   ${sched_desc}"
        fi

        local active_cleanups=""
        [ "$CLEANUP_PKG_CACHE" = "true" ] && active_cleanups="${active_cleanups} pkg-cache"
        [ "$CLEANUP_OLD_LOGS" = "true" ]  && active_cleanups="${active_cleanups} old-logs"
        [ "$CLEANUP_JOURNAL" = "true" ]   && active_cleanups="${active_cleanups} journal"
        [ "$CLEANUP_TMP" = "true" ]       && active_cleanups="${active_cleanups} tmp"
        [ "$CLEANUP_CRASH" = "true" ]     && active_cleanups="${active_cleanups} crash"
        echo "  Cleanup:       ${active_cleanups:- (none)}"
        [ -n "$CLEANUP_CUSTOM_PATHS" ] && echo "  Custom Paths:   ${CLEANUP_CUSTOM_PATHS}"
    else
        echo "Configuration"
        echo "  Not configured yet. Run: sudo ${SCRIPT_INSTALL_PATH} --setup"
    fi

    echo ""
    echo "Reboot Pending"
    if [ -f /var/run/reboot-required ]; then
        echo "  YES — a reboot is required"
        [ -f /var/run/reboot-required.pkgs ] && \
            echo "  Packages: $(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')"
    else
        echo "  No"
    fi

    echo ""
    echo "Systemd Timers"
    local timers_found=false
    for pattern in "$SCRIPT_NAME" "$REBOOT_SERVICE" "unattended" "apt-daily" "dnf-automatic"; do
        if systemctl list-timers --all --no-pager 2>/dev/null | grep -q "$pattern"; then
            timers_found=true
        fi
    done
    if [ "$timers_found" = true ]; then
        systemctl list-timers --all --no-pager 2>/dev/null | \
            grep -E "(NEXT|${SCRIPT_NAME}|${REBOOT_SERVICE}|unattended|apt-daily|dnf-automatic)" || true
    else
        echo "  No related timers found"
    fi

    echo ""
    echo "Recent Log Entries (${LOG_FILE})"
    if [ -f "$LOG_FILE" ]; then
        tail -15 "$LOG_FILE" | sed 's/^/  /'
    else
        echo "  No log file yet"
    fi
    echo ""
}

# ============================================================
# MODE: UNINSTALL
# ============================================================

mode_uninstall() {
    # Check for terminal for interactive confirmation
    if [ -e /dev/tty ]; then
        detect_tui
        if ! tui_yesno "Uninstall Auto Security Maintenance" \
"This will:
 - Disable and remove maintenance timers
 - Remove the reboot timer
 - Remove the configuration file
 - Remove the installed script

Existing packages (unattended-upgrades, dnf-automatic)
will NOT be removed.

The log file is kept for your records.

Proceed?"; then
            echo "Cancelled."
            exit 0
        fi
    fi

    echo "Uninstalling..."

    # Stop and disable timers/services
    for unit in \
        "${SCRIPT_NAME}.timer" \
        "${SCRIPT_NAME}.service" \
        "${REBOOT_SERVICE}.timer" \
        "${REBOOT_SERVICE}.service"; do
        systemctl disable --now "$unit" 2>/dev/null || true
        rm -f "/etc/systemd/system/${unit}"
    done

    # Remove reboot check infrastructure
    rm -f "$REBOOT_CHECK_SCRIPT"
    rm -rf "/etc/systemd/system/dnf-automatic.service.d/reboot-check.conf"

    # Reload systemd
    systemctl daemon-reload 2>/dev/null || true

    # Revert DietPi setting if applicable
    if [ -f /boot/dietpi.txt ]; then
        if grep -q '^CONFIG_CHECK_APT_UPDATES=2' /boot/dietpi.txt; then
            sed -i 's/^CONFIG_CHECK_APT_UPDATES=2/CONFIG_CHECK_APT_UPDATES=1/' /boot/dietpi.txt
            echo "  Reverted DietPi auto-update setting"
        fi
    fi

    # Remove config and script
    rm -f "$CONFIG_FILE"
    rm -f "$SCRIPT_INSTALL_PATH"
    rm -f "$LOCK_FILE"

    echo ""
    echo "Uninstalled."
    echo "  Log preserved at: ${LOG_FILE}"
    echo "  APT/DNF config files were not removed."
    echo ""

    log "Auto security maintenance uninstalled"
}

# ============================================================
# HELP
# ============================================================

show_help() {
    cat <<HELP
Auto Security Maintenance

Configures and maintains automatic security-only updates across
Debian, Ubuntu, DietPi, RHEL, Rocky, Alma, CentOS, and Fedora.

Usage:
  sudo $(basename "$0") [OPTION]

Options:
  --setup, -s       Run interactive setup wizard (default)
  --run, -r         Run maintenance cycle (used by systemd timer)
  --status          Show configuration and service health
  --uninstall       Remove all installed components
  --help, -h        Show this help message

When run without arguments:
  - With a terminal attached: starts the setup wizard
  - Without a terminal (piped/cron): runs maintenance

Examples:
  sudo ./$(basename "$0")                      # Interactive setup
  sudo ./$(basename "$0") --status             # Check status
  curl -fsSL <url> | sudo bash                 # Setup via curl
  curl -fsSL <url> | sudo bash -s -- --status  # Check status via curl
HELP
}

# ============================================================
# ENTRY POINT
# ============================================================

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    echo "  Usage: sudo $(basename "$0") [--setup|--run|--status|--uninstall|--help]"
    exit 1
fi

# Ensure log file is writable
touch "$LOG_FILE" 2>/dev/null || true

case "${1:-}" in
    --setup|-s)
        mode_setup
        ;;
    --run|-r)
        mode_run >> "$LOG_FILE" 2>&1
        ;;
    --status)
        mode_status
        ;;
    --uninstall|--remove)
        mode_uninstall
        ;;
    --help|-h)
        show_help
        ;;
    "")
        # Default: setup if terminal is available, run otherwise
        if [ -e /dev/tty ]; then
            mode_setup
        else
            mode_run >> "$LOG_FILE" 2>&1
        fi
        ;;
    *)
        echo "Unknown option: $1"
        echo "Try: sudo $(basename "$0") --help"
        exit 1
        ;;
esac
