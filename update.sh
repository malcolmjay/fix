#!/bin/bash
# =============================================================================
# WLV-01 Camera System Update Script (update.sh)
#
# Combined system-optimization + EEPROM-configuration script for the WLV-01
# waist-level camera (Raspberry Pi 5). Merges two earlier scripts:
#
#   1. set_psu_max_current.sh — writes a known-good bootloader EEPROM config
#      (PSU_MAX_CURRENT=5000, BOOT_ORDER=0xf41, POWER_OFF_ON_HALT=1).
#   2. Pi camera optimization script — boot-speed and battery optimizations
#      (service/timer trimming, audio stack removal, config.txt tweaks,
#      bytecode precompile, auto-update lockdown, ...).
#
# CONFLICT RESOLUTION: the first script set BOOT_UART=1 while the second
# disables it for a ~3 s firmware boot saving. On a dedicated camera the
# serial console is not needed, so the merged EEPROM config uses BOOT_UART=0
# (plus BOOT_DELAY=0). Everything else from both scripts is preserved.
#
# WHAT THIS DOES:
#   - Disables unnecessary systemd services (wayvnc, cron, udisks2,
#     triggerhappy, serial-getty, NetworkManager-at-boot, ssh -> socket, ...)
#   - Disables background timers (battery savings)
#   - Kills audio stack at session start (frees ~55MB RAM)
#   - Trims the labwc session (wf-panel-pi, pcmanfm, xcompmgr, polkit agent)
#   - Adds firmware-level optimizations (config.txt: Wi-Fi powersave
#     restored, auto_initramfs=0; stock 2.4 GHz ceiling kept for boot speed,
#     the app clamps to 1.5 GHz at first frame) and cmdline.txt fixes
#     (no serial console, fsck.repair contradiction resolved)
#   - Rewrites the bootloader EEPROM config (BOOT_UART=0, BOOT_DELAY=0,
#     PSU_MAX_CURRENT=5000, BOOT_ORDER=0xf41, POWER_OFF_ON_HALT=1)
#   - Switches boot to HEADLESS (Phase 7c): system camera.service at
#     multi-user.target, desktop (lightdm/labwc/Xwayland) disabled — the
#     firmware drives the DSI panel via DRM/KMS and reads touch via evdev.
#     Needs only python3-kms++ (already present via Picamera2); applied
#     when it imports, otherwise the desktop boot is kept (still supported).
#   - Precompiles Python bytecode + tunes libcamera
#   - Pre-warms camera binaries into page cache
#   - Creates + enables camera.service when missing (new-camera
#     provisioning: freshly imaged Pi + wlf8.py + this script = working
#     camera), and patches an existing unit (Restart=on-failure, no Nice=,
#     bytecode-import launch instead of per-boot source compile)
#   - Locks down every automatic-update mechanism
#
# REQUIREMENTS: root. When started unprivileged (e.g. by the camera's OTA
#   update runner) it re-execs itself via passwordless sudo if available.
# REVERSIBILITY: every change has a documented undo command (see SUMMARY).
# REBOOT: changes need a reboot. When run interactively the script reboots
#   after 5 seconds; when run non-interactively (the camera firmware's
#   update.sh runner) it exits cleanly and asks for a power-cycle instead,
#   so the runner can finish its own cleanup and never re-triggers.
# =============================================================================

set -euo pipefail

# Print the failing command and line number on any error.
trap 'rc=$?; echo "Error: line ${LINENO} exited with status ${rc} (last command: ${BASH_COMMAND})" >&2' ERR

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[SKIP]${NC} $1"; }
info()  { echo -e "     $1"; }
err()   { echo -e "${RED}[ERR]${NC} $1"; }

# --- Privilege check (with sudo re-exec for the OTA runner) -----------------

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        exec sudo -n bash "$0" "$@"
    fi
    err "This script must be run as root: sudo bash $0"
    exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

BACKUP_DIR="/home/pi/pi-optimize-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "Backup directory: $BACKUP_DIR"

# Save current state for rollback
systemctl list-unit-files --state=enabled > "$BACKUP_DIR/enabled-services.txt"
cp /boot/firmware/config.txt "$BACKUP_DIR/config.txt.bak" 2>/dev/null || true

if [[ -r /proc/device-tree/model ]]; then
    MODEL="$(tr -d '\0' < /proc/device-tree/model)"
    if [[ "${MODEL}" != *"Raspberry Pi 5"* ]]; then
        warn "Detected '${MODEL}', not a Pi 5. Proceeding anyway."
    fi
fi

echo ""
echo "============================================"
echo " PHASE 1: Disable Unnecessary Boot Services"
echo "============================================"
echo ""

# --- Services safe to disable ---
# Each one listed with boot-time cost from systemd-analyze blame

# accounts-daemon: 425ms - D-Bus user account management, not needed.
# Must be MASKED not just disabled — lightdm triggers it via D-Bus activation
# which bypasses the disabled state entirely.
systemctl mask accounts-daemon.service 2>/dev/null || true
systemctl stop accounts-daemon.service 2>/dev/null || true
log "Masked accounts-daemon.service (prevents D-Bus reactivation by lightdm)"

# e2scrub_reap: 530ms - Ext4 online scrubbing cleanup, not needed
if systemctl is-enabled e2scrub_reap.service &>/dev/null; then
    systemctl disable e2scrub_reap.service
    log "Disabled e2scrub_reap.service (saves ~530ms boot)"
else
    warn "e2scrub_reap.service already disabled"
fi

# rpi-eeprom-update: 335ms - Checks for EEPROM updates at boot. Run manually instead.
if systemctl is-enabled rpi-eeprom-update.service &>/dev/null; then
    systemctl disable rpi-eeprom-update.service
    log "Disabled rpi-eeprom-update.service (saves ~335ms boot)"
    info "  Run 'sudo rpi-eeprom-update' manually when needed"
else
    warn "rpi-eeprom-update.service already disabled"
fi

# wayvnc-control: VNC remote desktop - user confirmed not needed
if systemctl is-enabled wayvnc-control.service &>/dev/null; then
    systemctl disable wayvnc-control.service
    systemctl stop wayvnc-control.service 2>/dev/null || true
    log "Disabled wayvnc-control.service (VNC not needed)"
else
    warn "wayvnc-control.service already disabled"
fi

# wayvnc: misconfigured as a *system* service — it tries to attach to the
# user's Wayland compositor before the session exists, times out (~3-5s on
# the boot clock), is SIGKILLed, then gets restarted anyway and runs as a
# permanent VNC server on a battery-powered camera. The firmware's own MJPEG
# live view covers remote use. Not stopped here (this run may be watched over
# VNC) — takes effect on reboot. Bench re-enable:
#   sudo systemctl enable --now wayvnc.service
if systemctl is-enabled wayvnc.service &>/dev/null; then
    systemctl disable wayvnc.service
    log "Disabled wayvnc.service (fails+retries every boot; always-on VNC drains battery)"
else
    warn "wayvnc.service already disabled"
fi

# cron: no crontab exists on the camera; logrotate/fstrim run from systemd timers.
if systemctl is-enabled cron.service &>/dev/null; then
    systemctl disable cron.service
    systemctl stop cron.service 2>/dev/null || true
    log "Disabled cron.service (no crontabs; systemd timers cover logrotate/fstrim)"
else
    warn "cron.service already disabled"
fi

# udisks2: 580ms of boot (top of blame), and only pcmanfm's desktop volume
# handling needed it — the firmware mounts the offload USB stick itself
# (_usb_mount_thread). Masked, not just disabled: D-Bus activation would
# otherwise resurrect it.
systemctl mask udisks2.service 2>/dev/null || true
systemctl stop udisks2.service 2>/dev/null || true
log "Masked udisks2.service (firmware mounts USB itself; pcmanfm trimmed in Phase 4)"

# triggerhappy: thd isn't running, so its udev hook (th-cmd) spawns and FAILS
# once per input device at every boot. Disable the units and neutralize the
# udev rule so the failing exec stops entirely.
systemctl disable triggerhappy.service triggerhappy.socket 2>/dev/null || true
systemctl stop triggerhappy.service triggerhappy.socket 2>/dev/null || true
ln -sf /dev/null /etc/udev/rules.d/60-triggerhappy.rules
log "Disabled triggerhappy + neutralized its udev rule (th-cmd failed per device each boot)"

# Serial console getty: BOOT_UART=0 already removes the firmware side (5b);
# the kernel console goes with the cmdline.txt edit in Phase 5. Mask the
# getty as well so nothing respawns on ttyAMA10.
systemctl mask serial-getty@ttyAMA10.service 2>/dev/null || true
log "Masked serial-getty@ttyAMA10.service (no serial console on the camera)"

# ssh: switch to socket activation — zero boot cost and no idle daemon; sshd
# is spawned per connection instead. The running service is deliberately not
# stopped so an active SSH session survives this script; applies on reboot.
if systemctl is-enabled ssh.service &>/dev/null; then
    systemctl disable ssh.service
    systemctl enable ssh.socket
    log "Switched ssh to socket activation (ssh.service -> ssh.socket, applies on reboot)"
else
    warn "ssh.service already disabled (verify ssh.socket if SSH access is still wanted)"
fi

# NetworkManager on demand: with Wi-Fi off (the persisted firmware default)
# the daemon does nothing but burn CPU and run background scans — and a
# hidden-SSID profile forces full-power *active* scans. wlf8.py now starts
# NetworkManager when the Wi-Fi toggle goes on (including a persisted
# wifi_enabled=true at boot) and stops it, with wpa_supplicant, when the
# toggle goes off. Deliberately not stopped here — this script may be running
# over an SSH-over-Wi-Fi session.
if systemctl is-enabled NetworkManager.service &>/dev/null; then
    systemctl disable NetworkManager.service
    systemctl disable wpa_supplicant.service 2>/dev/null || true
    log "Disabled NetworkManager + wpa_supplicant at boot (firmware starts them on demand)"
    info "  Bench recovery: sudo systemctl start NetworkManager"
else
    warn "NetworkManager.service already disabled"
fi

# packagekit: moved to Phase 4 (must be masked, not disabled, due to D-Bus activation)

echo ""
echo "============================================"
echo " PHASE 2: Disable Background Timers"
echo "============================================"
echo ""

# These run periodically and waste CPU/battery on a dedicated camera device

TIMERS_TO_DISABLE=(
    "apt-daily.timer"           # Daily apt cache update
    "apt-daily-upgrade.timer"   # Daily unattended upgrades
    "dpkg-db-backup.timer"      # Daily dpkg database backup
    "e2scrub_all.timer"         # Weekly filesystem scrub
    "man-db.timer"              # Daily man page index rebuild
)

for timer in "${TIMERS_TO_DISABLE[@]}"; do
    if systemctl is-enabled "$timer" &>/dev/null; then
        systemctl disable "$timer"
        systemctl stop "$timer" 2>/dev/null || true
        log "Disabled $timer"
    else
        warn "$timer already disabled"
    fi
done

info "Kept logrotate.timer (prevents log disk overflow)"
info "Kept fstrim.timer (extends SD card life)"

echo ""
echo "============================================"
echo " PHASE 3: Disable Audio Stack"
echo "============================================"
echo ""

# wlf8.py does not use audio. PipeWire + WirePlumber + PulseAudio use
# ~55MB RAM. These are user-session services, so we mask them for the 'pi' user.

AUDIO_SERVICES=(
    "pipewire.service"
    "pipewire.socket"
    "pipewire-pulse.service"
    "pipewire-pulse.socket"
    "wireplumber.service"
    "pipewire-session-manager.service"
    "filter-chain.service"
    "pulseaudio.service"
    "pulseaudio.socket"
)

for svc in "${AUDIO_SERVICES[@]}"; do
    sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user disable "$svc" 2>/dev/null || true
    sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user mask "$svc" 2>/dev/null || true
    sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user stop "$svc" 2>/dev/null || true
    log "Masked user service: $svc"
done

info "  NOTE: pulseaudio.service was taking 1.5s in user session startup"

# Also disable ALSA restore (no sound card needed)
systemctl mask alsa-restore.service 2>/dev/null || true
log "Masked alsa-restore.service"

echo ""
echo "============================================"
echo " PHASE 4: Disable Unnecessary Desktop Daemons"
echo "============================================"
echo ""

# These desktop services are not needed for the camera UI (cv2 fullscreen window).
# The core desktop (lightdm + labwc + Xwayland) is preserved HERE — it is the
# fallback path. Phase 7c below switches the boot to headless (the firmware's
# own DRM/KMS backend, multi-user.target) whenever the runtime deps are
# available; this trim still matters for cameras that keep the desktop and
# for bench sessions that re-enable it.
#
# IMPORTANT: Services that other components activate via D-Bus must be MASKED,
# not just disabled. Disabling only prevents systemd from starting them at boot,
# but D-Bus activation bypasses this entirely. Masking points the unit file at
# /dev/null so D-Bus activation fails instantly instead of timing out.

# Create an autostart override directory
AUTOSTART_DISABLE="/home/pi/.config/autostart-disabled"
mkdir -p "$AUTOSTART_DISABLE"

# packagekit: wf-panel-pi triggers this via D-Bus during session startup.
# When only disabled (not masked), D-Bus waits for the activation timeout before
# returning failure to wf-panel-pi, adding seconds to desktop readiness.
systemctl mask packagekit.service 2>/dev/null || true
systemctl stop packagekit.service 2>/dev/null || true
log "Masked packagekit.service (prevents D-Bus activation timeout from wf-panel-pi)"

# xdg-desktop-portal and friends: ~100MB combined, not needed for cv2 window
for portal_svc in xdg-desktop-portal.service xdg-desktop-portal-gtk.service xdg-desktop-portal-wlr.service; do
    sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user mask "$portal_svc" 2>/dev/null || true
    sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user stop "$portal_svc" 2>/dev/null || true
done
log "Masked xdg-desktop-portal services (~100MB RAM saved)"

# gnome-keyring-daemon: not needed for camera operation
sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user mask gnome-keyring-daemon.service 2>/dev/null || true
log "Masked gnome-keyring-daemon"

# --- XDG Autostart entries (/etc/xdg/autostart/) ---
# These .desktop files launch during every session and add to the time
# between lightdm starting and the desktop being interactive.
# Disabling is done by creating a user-level override with Hidden=true.
XDG_OVERRIDE="/home/pi/.config/autostart"
mkdir -p "$XDG_OVERRIDE"

# Disable by creating override .desktop files with Hidden=true
# This is the correct XDG way — doesn't modify system files in /etc
XDG_DISABLE_LIST=(
    "pulseaudio.desktop"                        # PulseAudio via XDG (bypasses systemd mask)
    "gnome-keyring-pkcs11.desktop"              # PKCS11 token manager — not needed
    "gnome-keyring-secrets.desktop"             # Secret storage — not needed
    "gnome-keyring-ssh.desktop"                 # SSH agent via keyring — not needed
    "lxpolkit.desktop"                          # Duplicate polkit agent
    "polkit-mate-authentication-agent-1.desktop" # GUI auth prompts — camera has no desktop dialogs
    "xcompmgr.desktop"                          # X11 compositor is useless under rootless Xwayland (labwc composites)
    "xdg-user-dirs.desktop"                     # User dirs scaffolding — only needed on first boot
    "xdg-user-dirs-kde.desktop"                 # KDE variant — not relevant
)

for entry in "${XDG_DISABLE_LIST[@]}"; do
    override="$XDG_OVERRIDE/$entry"
    if [ -f "/etc/xdg/autostart/$entry" ] && [ ! -f "$override" ]; then
        cat > "$override" << DESKTOP
[Desktop Entry]
Hidden=true
DESKTOP
        log "Disabled XDG autostart: $entry"
    elif [ -f "$override" ]; then
        warn "Already overridden: $entry"
    else
        warn "Not found: /etc/xdg/autostart/$entry"
    fi
done

info "  Kept: autotouch, env-display, pprompt, pwrkey, xwayauth"

# --- labwc session trim: wf-panel-pi + pcmanfm --desktop ---
# The taskbar (~65MB) and desktop file manager (~40MB) render underneath a
# permanently fullscreen camera window — pure RAM/CPU/boot cost. They are
# launched from labwc's autostart, not XDG .desktop entries. labwc uses the
# FIRST autostart it finds (user config dir wins over /etc/xdg/labwc), so a
# user-level copy with those lines commented out overrides the system file
# without touching /etc.
LABWC_SYS="/etc/xdg/labwc/autostart"
LABWC_USER="/home/pi/.config/labwc/autostart"
if [ -f "$LABWC_USER" ]; then
    cp "$LABWC_USER" "$BACKUP_DIR/labwc-autostart.bak"
    if grep -Eq '^[^#]*(wf-panel-pi|pcmanfm)' "$LABWC_USER"; then
        sed -i -E 's/^([^#]*(wf-panel-pi|pcmanfm).*)$/# camera-trim: \1/' "$LABWC_USER"
        log "Commented wf-panel-pi/pcmanfm in existing $LABWC_USER (backed up)"
    else
        warn "User labwc autostart already free of wf-panel-pi/pcmanfm"
    fi
elif [ -f "$LABWC_SYS" ] && grep -Eq '^[^#]*(wf-panel-pi|pcmanfm)' "$LABWC_SYS"; then
    mkdir -p /home/pi/.config/labwc
    sed -E 's/^([^#]*(wf-panel-pi|pcmanfm).*)$/# camera-trim: \1/' "$LABWC_SYS" > "$LABWC_USER"
    chown -R pi:pi /home/pi/.config/labwc
    log "Created $LABWC_USER without wf-panel-pi/pcmanfm (~100MB RAM + session startup time)"
    info "  Undo: rm $LABWC_USER (system default takes over again)"
else
    warn "wf-panel-pi/pcmanfm not launched from labwc autostart — nothing to trim"
fi

# --- Fix camera.service parse error ---
CAMERA_SVC="/home/pi/.config/systemd/user/camera.service"
if [ -f "$CAMERA_SVC" ]; then
    cp "$CAMERA_SVC" "$BACKUP_DIR/camera.service.bak"
    # Fix Restart=No → Restart=no (case-sensitive, "No" is invalid)
    if grep -q "Restart=No" "$CAMERA_SVC" 2>/dev/null; then
        sed -i 's/Restart=No/Restart=no/' "$CAMERA_SVC"
        log "Fixed camera.service: Restart=No → Restart=no"
    fi
    # Reload user daemon to pick up the fix
    sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload 2>/dev/null || true
fi

echo ""
echo "============================================"
echo " PHASE 5: Firmware & Boot Config Tweaks"
echo "============================================"
echo ""

CONFIG="/boot/firmware/config.txt"

# Helper: add a line to config.txt if not already present
add_config() {
    local line="$1"
    local comment="$2"
    if grep -qF "$line" "$CONFIG" 2>/dev/null; then
        warn "Already in config.txt: $line"
    else
        echo "" >> "$CONFIG"
        echo "# $comment" >> "$CONFIG"
        echo "$line" >> "$CONFIG"
        log "Added to config.txt: $line"
    fi
}

# Disable Bluetooth (saves ~30mA continuous draw)
add_config "dtoverlay=disable-bt" "Disable Bluetooth to save power"

# Disable onboard audio (not needed, saves power)
# Check if audio is currently enabled
if grep -q "^dtparam=audio=on" "$CONFIG" 2>/dev/null; then
    sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$CONFIG"
    log "Changed dtparam=audio=on to audio=off"
elif ! grep -q "^dtparam=audio=off" "$CONFIG" 2>/dev/null; then
    add_config "dtparam=audio=off" "Disable onboard audio to save power"
fi

# Wi-Fi power management: an earlier version of this script DISABLED it "for
# stability", which pins the radio at full power (~90mA on the 3V7_WL rail,
# ~0.35W) around the clock. Reverse that: remove the overlay and default
# powersave ON via NetworkManager. The firmware lifts powersave only while an
# MJPEG live-view subscriber is streaming (see _wifi_set_power_save), so the
# remote view stays smooth without paying the battery cost 24/7.
if grep -q "^dtoverlay=disable-wifi-power-management" "$CONFIG" 2>/dev/null; then
    sed -i '/^# Disable WiFi power management for stability$/d;/^dtoverlay=disable-wifi-power-management$/d' "$CONFIG"
    log "Removed dtoverlay=disable-wifi-power-management (saves ~0.35W whenever Wi-Fi is on)"
else
    warn "disable-wifi-power-management overlay not present"
fi

NM_PS_CONF="/etc/NetworkManager/conf.d/wifi-powersave.conf"
if [ ! -f "$NM_PS_CONF" ]; then
    mkdir -p /etc/NetworkManager/conf.d
    cat > "$NM_PS_CONF" <<'EOF'
# Camera battery: default 802.11 powersave ON. The camera firmware lifts it
# temporarily while the MJPEG live view is streaming (iw ... power_save off).
[connection]
wifi.powersave = 3
EOF
    log "Created $NM_PS_CONF (wifi.powersave=3)"
else
    warn "$NM_PS_CONF already exists"
fi

# Hidden-SSID profiles force NetworkManager into full-power ACTIVE scanning
# whenever the radio is up and disconnected. Can't be auto-fixed (the network
# may genuinely be hidden) — surface it so the owner can un-hide the SSID.
HIDDEN_PROFILES="$(grep -l '^hidden=true' /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true)"
if [ -n "$HIDDEN_PROFILES" ]; then
    warn "Wi-Fi profiles with hidden=true force active scanning (battery cost while connected-less):"
    echo "$HIDDEN_PROFILES" | while read -r f; do info "  $f"; done
    info "  If the network isn't actually hidden: nmcli connection modify <name> 802-11-wireless.hidden no"
fi

# Boot speed: leave the firmware ceiling at the stock 2.4 GHz so the whole
# boot-critical path (kernel, session, Python imports, camera bring-up) runs
# flat-out. wlf8.py applies its verified 1.5 GHz clamp on the main loop's
# first iteration — the moment a picture is visible — so only boot runs
# uncapped (~10 J per boot). An earlier revision set arm_freq=1800 as a
# hardware backstop; deliberately reverted (owner's call: every second of
# boot counts), trusting the app cap, which is read-back-verified and backed
# by Restart=on-failure.
if grep -q "^arm_freq=1800$" "$CONFIG" 2>/dev/null; then
    sed -i '/^# Max CPU clock = 4K-video boost ceiling; firmware caps normal use lower$/d;/^arm_freq=1800$/d' "$CONFIG"
    log "Removed arm_freq=1800 (boot at full 2.4 GHz; app clamps to 1.5 GHz at first frame)"
else
    warn "arm_freq=1800 not present — firmware ceiling already stock"
fi

# Skip loading the initramfs: the root filesystem is plain ext4 on SD, which
# the RPi kernel mounts without one. Saves ~0.5-1s of firmware load+unpack.
# The initramfs files stay on disk — undo is flipping this back to 1.
if grep -q "^auto_initramfs=1" "$CONFIG" 2>/dev/null; then
    sed -i 's/^auto_initramfs=1/auto_initramfs=0/' "$CONFIG"
    log "Set auto_initramfs=0 (skip initramfs load; ext4 root mounts directly)"
    info "  Undo if boot fails: set auto_initramfs=1 in config.txt from another machine"
else
    warn "auto_initramfs=1 not present — leaving initramfs setting as-is"
fi

# --- cmdline.txt fixes ---
CMDLINE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE" ]; then
    if [ ! -f "$BACKUP_DIR/cmdline.txt.bak" ]; then
        cp "$CMDLINE" "$BACKUP_DIR/cmdline.txt.bak"
    fi
    # Serial console: BOOT_UART=0 killed the firmware side; drop the kernel
    # side too (also stops serial-getty@ttyAMA10 from being spawned).
    if grep -q "console=serial0,115200" "$CMDLINE"; then
        sed -i 's/console=serial0,115200 \?//' "$CMDLINE"
        log "Removed console=serial0,115200 from cmdline.txt (no serial console)"
    fi
    # fsck.repair must be =yes: the file had accumulated both =yes and =no
    # (last one wins = no) and the FAT volumes were mounting dirty every
    # boot. Normalize unconditionally so a build with only =no also heals.
    if grep -q "fsck.repair=no" "$CMDLINE"; then
        sed -i 's/ \?fsck.repair=no//g' "$CMDLINE"
        log "Removed fsck.repair=no from cmdline.txt"
    fi
    if ! grep -q "fsck.repair=yes" "$CMDLINE"; then
        sed -i 's/$/ fsck.repair=yes/' "$CMDLINE"
        log "Added fsck.repair=yes to cmdline.txt"
    fi
fi

# Reduce GPU memory since camera uses libcamera (not legacy GPU camera stack)
# 64MB is sufficient for desktop compositing + libcamera
if grep -q "^gpu_mem=" "$CONFIG" 2>/dev/null; then
    warn "gpu_mem already set, not changing"
else
    add_config "gpu_mem=64" "Reduce GPU memory (libcamera doesn't need legacy GPU allocation)"
fi

# Disable HDMI audio output
add_config "hdmi_drive=1" "DVI mode - no HDMI audio (saves power)"

echo ""
echo "============================================"
echo " PHASE 5b: Bootloader EEPROM Configuration"
echo "============================================"
echo ""

# Fully overwrites the EEPROM config with the merged known-good camera config.
# From set_psu_max_current.sh: PSU_MAX_CURRENT=5000 (full 5A from the supply,
# needed for the Pi 5 + sensor + DSI panel on the X1200 UPS), BOOT_ORDER=0xf41,
# POWER_OFF_ON_HALT=1 (true power-off on halt — battery critical).
# From the optimization script: BOOT_UART=0 and BOOT_DELAY=0 (the serial
# console adds ~3s of firmware wait per boot; not needed on a camera).
# BOOT_UART=0 deliberately wins over the old script's BOOT_UART=1.
#
# NET_INSTALL_ENABLED=0: measured on hardware, the bootloader phase is ~4.7 s
# (8 s from power-on to first light, of which Linux accounts for ~3.3 s) —
# the largest single block left in the boot. Network install defaults to 1 on
# flagship models and, to spot the keyboard that would trigger it, the
# bootloader initialises the USB controller and enumerates devices: the
# Raspberry Pi docs put that at "approximately 1 second" and say it "may be
# advantageous to disable network install in some embedded applications".
# A camera with no keyboard is exactly that case.
#
# NOT set here: DISABLE_HDMI=1. It would skip the HDMI diagnostics path
# entirely (this body has no HDMI display), but rpi-eeprom issue #466
# reported it causing BOOT_ORDER to be ignored and USB to be preferred —
# and this camera routinely has a USB stick in it for offload/OTA, so a
# regression there could boot the wrong thing. The issue is closed and long
# predates current firmware, but the downside is "camera won't boot", so it
# stays an opt-in to be tested per-camera WITH a USB stick inserted:
#     sudo -E rpi-eeprom-config --edit    # add DISABLE_HDMI=1
# Revert with: sudo rpi-eeprom-config --apply <backup>/eeprom-config.bak

if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    err "rpi-eeprom-config not found — skipping EEPROM phase"
else
    NEW_CFG="${WORKDIR}/new-eeprom.conf"
    cat > "${NEW_CFG}" <<'EOF'
[all]
BOOT_UART=0
BOOT_DELAY=0
POWER_OFF_ON_HALT=1
BOOT_ORDER=0xf41
PSU_MAX_CURRENT=5000
NET_INSTALL_ENABLED=0
EOF

    # Save current EEPROM config for rollback
    rpi-eeprom-config > "$BACKUP_DIR/eeprom-config.bak" 2>/dev/null || true

    # Idempotence: skip the flash if every desired key already matches.
    EEPROM_MATCHES=true
    CURRENT_CFG="$(rpi-eeprom-config 2>/dev/null || true)"
    while IFS= read -r want; do
        case "$want" in
            \[*|"") continue ;;
        esac
        if ! grep -qxF "$want" <<< "$CURRENT_CFG"; then
            EEPROM_MATCHES=false
            break
        fi
    done < "${NEW_CFG}"

    if [ "$EEPROM_MATCHES" = true ]; then
        warn "EEPROM config already matches the target — nothing to flash"
    else
        echo "New EEPROM config:"
        cat "${NEW_CFG}"
        echo

        # rpi-eeprom-config --edit invokes "$EDITOR <staged-config-path>" and
        # expects the editor to modify that path in place. We point EDITOR at a
        # tiny helper that fully overwrites the staged file with our config —
        # wiping anything the migration step may have carried over from the
        # previous EEPROM image. This works across all rpi-eeprom versions
        # (no dependency on --apply).
        EDITOR_HELPER="${WORKDIR}/editor.sh"
        cat > "${EDITOR_HELPER}" <<EOF
#!/bin/sh
cp -f -- "${NEW_CFG}" "\$1"
EOF
        chmod +x "${EDITOR_HELPER}"

        echo "Applying new EEPROM config..."
        if EDITOR="${EDITOR_HELPER}" rpi-eeprom-config --edit; then
            log "Staged EEPROM config (applies on next reboot)"
            info "  Previous config saved to $BACKUP_DIR/eeprom-config.bak"
        else
            err "Could not apply EEPROM config automatically"
            info "  Please run manually: sudo -E rpi-eeprom-config --edit"
        fi
    fi
fi

echo ""
echo "============================================"
echo " PHASE 6: CPU Governor (skipped)"
echo "============================================"
echo ""

# SKIPPED: wlf8.py already manages the CPU governor dynamically:
#   - Boot:     uncapped at the stock 2.4 GHz ceiling for speed; the cap is
#               applied on the main loop's first iteration (first picture)
#   - Normal:   ondemand governor, thermal cap (1.2 GHz requested; the Pi 5
#               OPP table bottoms out at 1.5 GHz so 1.5 GHz is the effective
#               cap — wlf8.py clamps, verifies by read-back, and logs it)
#   - Sleep:    powersave governor, clamped to min frequency
#   - 4K video: ondemand governor, boosted to 1.8 GHz
# The app saves/restores governor state on each transition.
# Installing a system-level governor would conflict with this logic.
info "Skipped: wlf8.py already manages the CPU governor dynamically"
info "  Boot: 2.4 GHz | Normal: ondemand @ 1.5 GHz effective | Sleep: powersave @ min | 4K: 1.8 GHz"

echo ""
echo "============================================"
echo " PHASE 7: Optimize Existing Camera Autostart"
echo "============================================"
echo ""

# The camera launches via a systemd user service (~/.config/systemd/user/camera.service),
# not an XDG .desktop autostart entry. We optimize the service and pre-warm binaries.

# Pre-warm: load Python + camera libraries into page cache early in boot
# This makes the camera service launch faster since the binaries are
# already cached in RAM instead of being read cold from SD card.
# The module paths are RESOLVED, never guessed. The previous version
# globbed `dist-packages/cv2/*.so`, but Debian ships OpenCV as a flat
# `cv2.cpython-311-aarch64-linux-gnu.so` — no such directory exists, so the
# glob matched nothing and the single largest file on the boot path (the
# one whose import costs ~2.9 s) was never actually pre-cached. Layouts
# also move between releases (numpy/core -> numpy/_core in numpy 2.x), so
# hardcoded paths rot silently. importlib.util.find_spec LOCATES a module
# without importing it, which is both correct and cheap (~50 ms for the
# whole list; importing cv2 here would cost seconds and delay boot).
cat > /usr/local/bin/prewarm-camera.sh << 'PREWARM_EOF'
#!/bin/bash
# Pull the camera app's binaries into page cache so the app's imports are
# CPU-bound rather than demand-paging off the SD card. Best-effort: every
# failure is ignored, this must never delay or fail the boot.
set -u

WARMLIST_MODULES="$(mktemp)" || exit 0
WARMLIST="$(mktemp)" || exit 0
WARMLIST_DEPS="$(mktemp)" || exit 0
trap 'rm -f "$WARMLIST_MODULES" "$WARMLIST" "$WARMLIST_DEPS"' EXIT

{
    python3 - <<'PY'
import importlib.util
# EXACTLY the modules wlf8.py imports on its boot path, nothing more.
# Every extra name here is megabytes read off the SD card while the app
# is demand-paging the modules it DOES need, on the same device — the
# prewarm stops being free readahead and becomes a competing reader.
# `av` (PyAV, which bundles ffmpeg) was the worst offender: tens of MB
# for a module wlf8.py never imports at all; `simplejpeg` and `piexif`
# are likewise absent from the source. Verify with a grep before adding
# anything back.
for mod in ("cv2", "numpy", "PIL", "picamera2", "libcamera",
            "pykms", "gpiozero"):
    try:
        spec = importlib.util.find_spec(mod)
    except Exception:
        continue
    if spec is None:
        continue
    if spec.submodule_search_locations:
        for directory in spec.submodule_search_locations:
            print(directory)
    elif spec.origin:
        print(spec.origin)
PY
} 2>/dev/null > "$WARMLIST_MODULES" || true

# Expand package directories to the .so files inside them.
: > "$WARMLIST"
while IFS= read -r target; do
    [ -n "$target" ] || continue
    if [ -d "$target" ]; then
        find "$target" -type f \( -name '*.so' -o -name '*.so.*' \) \
            2>/dev/null >> "$WARMLIST" || true
    elif [ -f "$target" ]; then
        printf '%s\n' "$target" >> "$WARMLIST"
    fi
done < "$WARMLIST_MODULES"

# ...then add every shared library those payloads actually link against.
#
# This is the difference between warming a few MB and warming the import.
# Debian's python3-opencv is a THIN WRAPPER: find_spec("cv2") resolves to
# a ~5 MB cv2.cpython-*.so, and the ~150-200 MB that `import cv2` really
# faults in lives in the libopencv_*.so.4.x it links against (plus their
# own deps — libav*, libgtk, libtbb...). Warming only the wrapper warms
# ~3% of the cost, which is why a prewarm that looked like it was working
# still left a 14.4 s single-threaded `import cv2` in the field. Same
# shape of gap as the /usr/local libcamera one below.
#
# ldd RESOLVES the closure rather than guessing library names, so this
# stays correct across OpenCV/libcamera version bumps and across the
# distro-vs-/usr/local split — the same "resolve, never guess" rule the
# module list already follows.
# Written to a SEPARATE file, never appended to the one being read: ldd
# already returns the full transitive closure, so feeding its output back
# into the same loop would re-resolve every dependency for no gain.
: > "$WARMLIST_DEPS"
while IFS= read -r so; do
    [ -n "$so" ] || continue
    ldd "$so" 2>/dev/null | sed -n 's|.*=> \(/[^ ]*\).*|\1|p' \
        >> "$WARMLIST_DEPS" || true
done < "$WARMLIST"

# Read each file once. sort -u matters: the dependency closures overlap
# heavily (every OpenCV module pulls libopencv_core), and re-reading a
# 40 MB library four times is bandwidth taken from the app.
sort -u "$WARMLIST" "$WARMLIST_DEPS" 2>/dev/null | while IFS= read -r f; do
    [ -f "$f" ] && cat "$f" > /dev/null 2>&1 || true
done
# Fixed paths the resolver can't discover (native libs, IPA + tuning data,
# the interpreter itself, and the app's own bytecode).
#
# BOTH prefixes, and this matters more than it looks: a camera running a
# sensor that needs the custom libcamera (the IMX492/IMX294 fork) loads it
# from /usr/local, which shadows the distro copy in /usr/lib. Pre-warming
# only /usr/lib on such a camera warms the ONE libcamera the process will
# never open, and the fork's several-MB .so plus its IPA and tuning JSONs
# are then demand-paged cold off the SD card on the boot critical path —
# which is exactly the kind of per-sensor boot-time gap this service
# exists to remove. Same reasoning for the IPA data dirs, and vc4 is
# globbed alongside pisp so a Pi 4 is covered too.
# nullglob so unmatched patterns disappear instead of reaching cat as
# literals (a camera has one prefix or the other, rarely both).
shopt -s nullglob
cat /usr/bin/python3 \
    /usr/lib/*/libcamera*.so* \
    /usr/lib/*/libcamera/*.so* \
    /usr/local/lib/*/libcamera*.so* \
    /usr/local/lib/*/libcamera/*.so* \
    /usr/local/lib/libcamera*.so* \
    /usr/share/libcamera/ipa/rpi/*/*.json \
    /usr/local/share/libcamera/ipa/rpi/*/*.json \
    /home/pi/__pycache__/*.pyc \
    > /dev/null 2>&1 || true
shopt -u nullglob
exit 0
PREWARM_EOF
chmod 755 /usr/local/bin/prewarm-camera.sh

cat > /etc/systemd/system/prewarm-camera.service << 'EOF'
[Unit]
Description=Pre-warm camera app binaries into page cache
After=local-fs.target
Before=camera.service lightdm.service

[Service]
# Type=simple, NOT oneshot: reading the library set off the SD card takes
# real time, and a blocking oneshot in sysinit.target would add all of it to
# the boot it is supposed to shorten. Detached, it races the rest of the boot
# and the app's own demand paging cooperates with it — worst case it is
# redundant, never a delay.
Type=simple
# best-effort/7, NOT idle. The idle class only gets the device when nothing
# else wants it, and during boot everything wants it — so on the exact
# camera this service exists to help (slow storage, everything contending)
# it could be starved indefinitely and warm nothing at all. best-effort at
# the lowest priority still yields to normal-priority I/O on the critical
# path, but is actually scheduled, so the prewarm reaches the app's
# libraries before the app faults them in.
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Nice=10
ExecStart=/usr/local/bin/prewarm-camera.sh

[Install]
WantedBy=sysinit.target
EOF

systemctl daemon-reload
systemctl enable prewarm-camera.service
log "Created prewarm-camera.service + /usr/local/bin/prewarm-camera.sh"
info "  Module paths resolved via find_spec (the old cv2 glob matched nothing:"
info "   Debian ships a flat cv2.cpython-*.so, not a cv2/ package directory)"

# --- camera.service: create when missing (new-camera provisioning) ---
# wlf8.py + this script are the only two artifacts applied to a freshly
# imaged camera, so the autostart unit must come from here. Created ONLY
# when absent — an existing (possibly hand-tuned) unit is never replaced,
# just patched by the blocks below.
CAMERA_SVC="/home/pi/.config/systemd/user/camera.service"
if [ ! -f "$CAMERA_SVC" ]; then
    mkdir -p /home/pi/.config/systemd/user
    cat > "$CAMERA_SVC" <<'EOF'
[Unit]
Description=Camera App (user session)

[Service]
# sudo -E: wlf8.py needs root (sysfs CPU cap/backlight, rfkill, mounts) and
# must keep DISPLAY/XAUTHORITY from the lines below for its X11 window.
# RPi OS ships passwordless sudo for pi, which also permits -E.
# Launched as `import wlf8` rather than `python3 wlf8.py`: the entry script
# never uses __pycache__, so the direct form re-compiles the whole 14k-line
# source every boot (~1s). The import form loads precompiled bytecode and
# Python auto-recompiles when the source changes (OTA-safe).
ExecStart=sudo -E /usr/bin/python3 -u -c "import sys; sys.path.insert(0, '/home/pi'); import wlf8"
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/pi/.Xauthority
# Self-heal from boot races and crashes; clean exits and user stops never
# restart, so OTA and manual flows are unaffected.
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    chown -R pi:pi /home/pi/.config/systemd
    log "Created $CAMERA_SVC (new-camera provisioning)"
    grep -rqs "NOPASSWD" /etc/sudoers.d/ || \
        warn "pi may lack passwordless sudo — camera.service ExecStart uses sudo"
fi
# Enable at user login (default.target). systemctl --user needs the user
# bus; fall back to creating the wants-symlink by hand when it isn't up
# (e.g. provisioning from a bare console before any pi login).
# Skipped once the headless system unit exists (Phase 7c) — the user unit
# is retired then and must not be re-enabled by later update runs.
if [ -f /etc/systemd/system/camera.service ]; then
    warn "headless system camera.service present — user-session unit stays disabled"
elif sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user enable camera.service 2>/dev/null; then
    log "Enabled camera.service in the pi user manager"
else
    mkdir -p /home/pi/.config/systemd/user/default.target.wants
    ln -sf ../camera.service /home/pi/.config/systemd/user/default.target.wants/camera.service
    chown -R pi:pi /home/pi/.config/systemd
    warn "user bus unavailable — enabled camera.service via wants-symlink"
fi

# Scheduling priority: an earlier version patched Nice=-5 into camera.service,
# but the systemd *user* manager lacks CAP_SYS_NICE — a negative Nice= there
# can never apply. Remove it; wlf8.py now renices itself at startup
# (os.setpriority to -5, best-effort) with the root privileges it already has.
if [ -f "$CAMERA_SVC" ]; then
    if grep -q "^Nice=" "$CAMERA_SVC" 2>/dev/null; then
        sed -i '/^Nice=/d' "$CAMERA_SVC"
        log "Removed ineffective Nice= from camera.service (wlf8.py renices itself)"
    else
        warn "camera.service has no Nice= line (wlf8.py renices itself)"
    fi

    # Self-heal: with the faster boot the app can start BEFORE the labwc
    # compositor; a fatal X disconnect during session bring-up makes GTK
    # abort() (SIGABRT — not catchable from Python), and Restart=no left the
    # camera dead until a power cycle. wlf8.py now waits for the display to
    # answer before creating its window (_wait_for_display_ready); this is
    # the backstop for anything else that ever kills the app. on-failure
    # never restarts a clean exit or a user stop, so the OTA flow and manual
    # stops are unaffected.
    if grep -q "^Restart=no$" "$CAMERA_SVC"; then
        sed -i 's/^Restart=no$/Restart=on-failure/' "$CAMERA_SVC"
        log "camera.service: Restart=no -> Restart=on-failure (self-heal from boot races)"
    fi
    if grep -q "^Restart=" "$CAMERA_SVC" && ! grep -q "^RestartSec=" "$CAMERA_SVC"; then
        sed -i '0,/^Restart=/s//RestartSec=3\nRestart=/' "$CAMERA_SVC"
        log "camera.service: added RestartSec=3"
    fi

    # Boot speed: `python3 wlf8.py` re-parses and compiles the whole
    # 14k-line source on every boot (~1s on the Pi 5) because Python never
    # uses __pycache__ for the entry script. Importing it as a module does
    # use the bytecode Phase 9 precompiles, and Python auto-recompiles when
    # the source changes, so OTA updates are unaffected.
    if grep -q "import wlf8" "$CAMERA_SVC"; then
        warn "camera.service already launches via bytecode import"
    elif grep -q "python3 -u /home/pi/wlf8.py" "$CAMERA_SVC"; then
        sed -i "s|python3 -u /home/pi/wlf8.py|python3 -u -c \"import sys; sys.path.insert(0, '/home/pi'); import wlf8\"|" "$CAMERA_SVC"
        log "camera.service: launch via bytecode import (skips per-boot source compile)"
    else
        warn "camera.service ExecStart unrecognized — bytecode launch not applied"
    fi

    sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload 2>/dev/null || true
fi

echo ""
echo "============================================"
echo " PHASE 7b: Early Splash Cleanup"
echo "============================================"
echo ""

# The early-DSI-splash experiment (painting /dev/fb0 before the session) is
# ABANDONED: on this stack the panel stays dark until the compositor's
# first modeset regardless of fbdev writes, forced set_par modesets, fbcon
# takeover pokes, or backlight assertions. Remove every artifact a previous
# revision of this script installed so all cameras converge on the plain
# boot path. (The swaybg package itself is left installed; harmless.)

if systemctl is-enabled wlv-splash.service &>/dev/null || [ -f /etc/systemd/system/wlv-splash.service ]; then
    systemctl disable wlv-splash.service 2>/dev/null || true
    rm -f /etc/systemd/system/wlv-splash.service
    systemctl daemon-reload
    log "Removed wlv-splash.service"
else
    warn "wlv-splash.service not installed"
fi
rm -rf /opt/wlv

LABWC_USER="/home/pi/.config/labwc/autostart"
if [ -f "$LABWC_USER" ] && grep -q "swaybg" "$LABWC_USER"; then
    sed -i '/swaybg/d' "$LABWC_USER"
    log "Removed swaybg background from labwc autostart"
fi

CMDLINE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE" ] && grep -q "fbcon=nodefer" "$CMDLINE"; then
    sed -i 's/ \?fbcon=nodefer//; s/ \?vt.global_cursor_default=0//' "$CMDLINE"
    log "Removed splash-era fbcon=nodefer / cursor params from cmdline.txt"
fi

# getty@tty1 was masked purely to stop agetty clearing the splash — restore
# the stock recovery console.
if systemctl is-enabled getty@tty1.service 2>/dev/null | grep -q masked; then
    systemctl unmask getty@tty1.service 2>/dev/null || true
    systemctl enable getty@tty1.service 2>/dev/null || true
    log "Restored getty@tty1.service (stock VT console)"
fi

echo ""
echo "============================================"
echo " PHASE 7c: Headless Boot (no desktop)"
echo "============================================"
echo ""

# The firmware now carries its own DRM/KMS display backend (wlf8.py: with no
# DISPLAY in the environment it becomes DRM master, scans the composited
# canvas straight out to the DSI panel — applying the quarter-turn output
# rotation the desktop compositor used to own — and reads the touchscreen
# directly from evdev).
# That removes the whole lightdm -> labwc -> Xwayland session from the boot
# path AND from the per-frame cost: no compositor GPU pass on every preview
# frame, no X SHM copy, ~10 fewer resident processes, and multi-user.target
# comes up seconds before graphical.target ever did — boot time and battery
# both win.
#
# Staged rollout: only switch when the DRM runtime dep is actually
# importable. A camera that can't get it keeps the desktop boot, which
# remains fully supported (DISPLAY set -> the old cv2 backend).

# --- Dependency check ------------------------------------------------------
# ONE runtime dep: python3-kms++ (pykms, the DRM/KMS binding), which the
# camera already has because Picamera2 pulls it in for DrmPreview. Touch
# needs NO package — the firmware reads /dev/input/event* through the
# kernel's input_event ABI directly, so an apt failure in the field can
# never leave the panel without touch input.
#
# Verified by IMPORT, not dpkg state: the import is what the firmware
# actually needs to succeed. If it is somehow missing, try to install it,
# refreshing the package lists first (this script locks down automatic apt
# activity elsewhere, so a camera's cached lists are typically stale and a
# bare `apt-get install` would fail even with the network up). Failures are
# LOGGED, not swallowed — a silent failure here is undiagnosable in the
# field.

HEADLESS_OK=1
if python3 -c "import pykms" 2>/dev/null; then
    log "Dependency present: python3-kms++ (python module 'pykms')"
else
    info "  python3-kms++ missing — attempting install"
    APT_LOG="$BACKUP_DIR/headless-apt.log"
    apt-get update >"$APT_LOG" 2>&1 || \
        warn "apt-get update failed (offline?) — trying cached lists"
    # --allow-change-held-packages: Phase 10 pins camera packages, and a
    # previous run may have held this one before it could be installed.
    if apt-get install -y --no-install-recommends \
           --allow-change-held-packages python3-kms++ >>"$APT_LOG" 2>&1 \
       && python3 -c "import pykms" 2>/dev/null; then
        log "Installed python3-kms++"
    else
        warn "python3-kms++ could not be installed — keeping desktop boot"
        info "  apt output saved to: $APT_LOG"
        tail -n 3 "$APT_LOG" 2>/dev/null | sed 's/^/       | /'
        info "  (fix: get the camera online, then re-run this script)"
        HEADLESS_OK=0
    fi
fi

if [ "$HEADLESS_OK" = 1 ]; then
    # System unit: runs as root directly — the old user unit's `sudo -E`
    # existed only to carry the session's DISPLAY/XAUTHORITY into the app,
    # which headless has no use for. No DISPLAY selects the DRM backend.
    # The app itself waits for /dev/dri and retries the modeset
    # (_wait_for_display_ready / the open-window retry loop), so ordering
    # after local-fs is enough — no udev-settle serialization on the boot
    # path.
    SYS_CAMERA_SVC="/etc/systemd/system/camera.service"
    [ -f "$SYS_CAMERA_SVC" ] && cp "$SYS_CAMERA_SVC" "$BACKUP_DIR/system-camera.service.bak"
    cat > "$SYS_CAMERA_SVC" <<'EOF'
[Unit]
Description=Camera App (headless DRM)
After=local-fs.target
# Never fight a desktop for the display: if lightdm is ever re-enabled for
# bench work, starting it stops the headless unit (and vice versa).
Conflicts=lightdm.service

[Service]
WorkingDirectory=/home/pi
# The old user unit reached root via `sudo -E`, which PRESERVED HOME=/home/pi.
# A system unit would default to HOME=/root, relocating any library cache
# that writes to ~ (fontconfig, PIL) and rebuilding it once per fresh boot.
# Pin it for exact parity — the firmware itself uses absolute paths.
Environment=HOME=/home/pi
# Bytecode-import launch, same reasoning as the old user unit (skips the
# per-boot 14k-line source compile; auto-recompiles after OTA).
ExecStart=/usr/bin/python3 -u -c "import sys; sys.path.insert(0, '/home/pi'); import wlf8"
# Self-heal from crashes; clean exits and user stops never restart, so OTA
# and manual flows are unaffected (same policy as the old user unit).
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if systemctl enable camera.service >/dev/null 2>&1; then
        log "Installed + enabled system camera.service (headless DRM backend)"
    else
        warn "systemctl enable camera.service failed — check manually"
    fi

    # Retire the user-session unit (file kept on disk for rollback) so the
    # camera can't start twice if the desktop is ever brought back.
    if sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user disable camera.service 2>/dev/null; then
        log "Disabled user-session camera.service"
    else
        rm -f /home/pi/.config/systemd/user/default.target.wants/camera.service
        warn "user bus unavailable — removed user camera.service wants-symlink by hand"
    fi

    # Boot to multi-user; the desktop session never starts. getty@tty1 stays
    # enabled as the recovery console (harmless: the app holds DRM master,
    # so the VT is not shown while the camera runs).
    systemctl set-default multi-user.target >/dev/null 2>&1 || \
        warn "set-default multi-user.target failed"
    systemctl disable lightdm.service 2>/dev/null || true
    log "Default target -> multi-user.target; lightdm disabled"
    info "  Rollback to desktop boot:"
    info "    sudo systemctl set-default graphical.target && sudo systemctl enable lightdm"
    info "    sudo systemctl disable camera.service   # system unit"
    info "    sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user enable camera.service"
elif [ -f /etc/systemd/system/camera.service ]; then
    # The camera was ALREADY converted to headless boot by a previous run,
    # but the deps no longer import (package removed, Python upgrade, ...).
    # "Keeping desktop boot" would be a lie here — the desktop is disabled
    # and the next reboot would come up headless-blind. Roll the boot path
    # back to the desktop: remove the system unit (backed up first),
    # restore graphical.target + lightdm, and re-enable the user-session
    # unit that Phase 7 skipped earlier in this run (its guard saw the
    # system unit file; the unit file itself is kept on disk / recreated by
    # Phase 7). If deps return on a later run, Phase 7c simply converts to
    # headless again.
    warn "headless deps broken on a headless-converted camera — restoring desktop boot"
    systemctl disable camera.service 2>/dev/null || true
    cp /etc/systemd/system/camera.service "$BACKUP_DIR/system-camera.service.broken-deps.bak" 2>/dev/null || true
    rm -f /etc/systemd/system/camera.service
    systemctl daemon-reload
    systemctl set-default graphical.target >/dev/null 2>&1 || \
        warn "set-default graphical.target failed"
    systemctl enable lightdm.service 2>/dev/null || \
        warn "could not enable lightdm — check manually"
    if sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user enable camera.service 2>/dev/null; then
        log "Re-enabled user-session camera.service"
    else
        mkdir -p /home/pi/.config/systemd/user/default.target.wants
        ln -sf ../camera.service /home/pi/.config/systemd/user/default.target.wants/camera.service
        chown -R pi:pi /home/pi/.config/systemd
        warn "user bus unavailable — re-enabled user camera.service via wants-symlink"
    fi
    log "Desktop boot restored (graphical.target + lightdm + user camera.service)"
fi

echo ""
echo "============================================"
echo " PHASE 8: Memory & I/O Tweaks"
echo "============================================"
echo ""

# Reduce swappiness - prefer keeping camera app in RAM
if ! grep -q "vm.swappiness" /etc/sysctl.d/99-camera.conf 2>/dev/null; then
    cat > /etc/sysctl.d/99-camera.conf << 'SYSCTL'
# Camera optimization: keep app in RAM, reduce SD card wear
vm.swappiness=10
vm.dirty_ratio=5
vm.dirty_background_ratio=2
SYSCTL
    sysctl -p /etc/sysctl.d/99-camera.conf 2>/dev/null || true
    log "Set memory/IO tuning (swappiness=10, reduced dirty ratios)"
else
    warn "sysctl camera config already exists"
fi

# --- Compressed-RAM swap backstop for low-memory boards (zram) ---
# A 2 GB board has no headroom for the 47 MP capture transients: the kernel
# OOM-killed the firmware mid-capture (a SIGKILL invisible to every in-app
# guard — the app just exits). zram provides a compressed in-RAM swap device
# using only the stock kernel module: no packages, no SD-card wear, and the
# "noswap" cmdline flag does not apply (it only gates dphys-swapfile). With
# swappiness=10 (above) it is touched only under genuine pressure, so idle
# battery cost is nil. Boards with >= 3 GiB skip this — they don't need it.
MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
if [ "${MEM_TOTAL_KB:-0}" -gt 0 ] && [ "$MEM_TOTAL_KB" -lt 3145728 ]; then
    if [ ! -f /etc/systemd/system/zram-swap.service ]; then
        cat > /etc/systemd/system/zram-swap.service << 'ZRAMUNIT'
[Unit]
Description=zram swap (compressed RAM backstop for capture memory spikes)
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Idempotent: a zram swap that is already active is left alone. zstd is
# preferred but optional (older kernels fall back to the module default).
ExecStart=/bin/sh -c 'grep -q zram0 /proc/swaps && exit 0; modprobe zram && { echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true; } && echo 768M > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p 100 /dev/zram0'
ExecStop=/sbin/swapoff /dev/zram0

[Install]
WantedBy=multi-user.target
ZRAMUNIT
        systemctl daemon-reload
        systemctl enable zram-swap.service 2>/dev/null || true
        systemctl start zram-swap.service 2>/dev/null || true
        log "Enabled zram swap backstop (768M compressed, stock kernel module only)"
    else
        warn "zram-swap.service already present — leaving as-is"
    fi
else
    info "Board has >= 3 GiB RAM — zram backstop not needed"
fi

echo ""
echo "============================================"
echo " PHASE 9: Python & libcamera Startup Tuning"
echo "============================================"
echo ""

# --- Precompile Python bytecode ---
# Without .pyc files, Python recompiles every .py to bytecode on each import.
# This adds latency especially for large packages like picamera2 and PIL.
# Precompiling once means imports go straight to cached bytecode.

python3 -m compileall -q /usr/lib/python3/dist-packages/picamera2/ 2>/dev/null || true
python3 -m compileall -q /usr/lib/python3/dist-packages/cv2/ 2>/dev/null || true
python3 -m compileall -q /usr/lib/python3/dist-packages/numpy/ 2>/dev/null || true
python3 -m compileall -q /usr/lib/python3/dist-packages/PIL/ 2>/dev/null || true
python3 -m compileall -q /usr/lib/python3/dist-packages/av/ 2>/dev/null || true
# wlf8.py — the single-file camera firmware. This cache is what the
# camera.service `import wlf8` launch (Phase 7) actually loads at boot;
# Python refreshes it automatically if wlf8.py changes without this script.
python3 -m compileall -q /home/pi/wlf8.py 2>/dev/null || true
log "Precompiled Python bytecode for camera libraries"
info "  Eliminates .py → bytecode recompilation on every boot"

# --- Install dng_calibrate.py (per-unit DNG calibration tool) ---
# The OTA flow only ever delivers wlf8.py + this script, so the standalone
# calibration tool (NoiseProfile photon-transfer model --
# see the DNG sections in wlf8.py/CLAUDE.md) is materialized here. It must
# live NEXT TO wlf8.py: both the tool and the firmware resolve the
# calibration/ output folder relative to their own location, so side by
# side they agree on /home/pi/calibration/<model>_*.json with no
# configuration. Existing calibration files are never touched by this
# write (the tool only ever writes per-sensor JSONs atomically).
# The heredoc is a byte-for-byte copy of dng_calibrate.py at the source
# repo root -- keep the two in sync when editing either.
cat > /home/pi/dng_calibrate.py <<'DNG_CALIBRATE_EOF'
#!/usr/bin/env python3
"""Per-unit DNG calibration for the WLV-01: the DNG NoiseProfile
photon-transfer model.

Run ON THE CAMERA with the firmware stopped (it owns the camera):

    systemctl stop camera 2>/dev/null; systemctl --user stop camera 2>/dev/null
    python3 dng_calibrate.py noise
    python3 dng_calibrate.py baseline-exposure --ev 0.35
    python3 dng_calibrate.py awb --ct 5600 --label daylight

AWB grey-point calibration (`awb`) measures the sensor's true neutral
response (r = R/G, b = B/G in the linear raw domain) from a grey card
under a light source of known colour temperature, and prints a
ready-to-paste `rpi.awb` `ct_curve` for the platform tuning file.  The
Bayesian AWB can only slide along that curve, so a curve inherited from
another sensor (or the wrong IR-cut stack) guarantees a cast no
algorithm setting can fix.  Procedure:

  1. Fill the frame centre with an evenly lit grey card (18% card, or
     any spectrally flat grey/white surface), NOTHING clipped.
  2. `python3 dng_calibrate.py awb --ct <kelvin> --label <name>` — one
     run per light source.  Use the source's real CT (halogen ~2700,
     warm LED ~3000, cool white ~4000, daylight ~5600, overcast ~6500).
  3. Repeat under at least two, ideally three, sources spanning
     warm -> cool.  Points accumulate in calibration/<id>_awb_points.json
     (re-running a CT replaces that point).
  4. The tool prints the assembled `ct_curve` block and, when it can
     read the installed tuning, the delta against the curve currently
     deployed at each measured CT.  Paste the new curve into the
     tuning's `rpi.awb` section (path is printed; keep a backup) and
     restart the firmware.

  While editing `rpi.awb`, also consider `transverse_pos`/`transverse_neg`
  (how far off the CT curve the search may wander): stock ~0.02 cannot
  reach the green/magenta offset of LED/fluorescent sources — 0.04-0.05
  buys that headroom at some risk of hunting under mixed light.  Note
  the firmware handles clipped-highlight AWB pollution itself (the
  clip-aware AWB hold in wlf8.py); no tuning change addresses that.

BaselineExposure calibration (`baseline-exposure`) stores a measured
per-sensor DNG BaselineExposure (tag 50730).  The firmware's default is
an honest 0.0 EV — the stock PiDNG boilerplate of +1.0 EV made every raw
render exactly one stop brighter than the ISP JPG.  Measure the real
value like this:

  1. Photograph an 18% grey card (or the grey patch of a colour target)
     filling the frame, correctly metered (AUTO exposure, no EV comp).
  2. Open the DNG in Lightroom/ACR at default settings with ALL
     adjustment sliders at zero.
  3. Read the grey patch's sRGB value; correctly rendered mid-grey lands
     at roughly 118/255.  Adjust the Exposure slider until it does, and
     the slider value IS the BaselineExposure to store here.
  4. `python3 dng_calibrate.py baseline-exposure --ev <value>` writes
     calibration/<model>_baseline_exposure.json; restart the firmware.

  Expect a calibrated result around +0.25 to +0.5 EV.  A round 1.0 is a
  red flag that you are re-measuring the old boilerplate, not the sensor.

(There is deliberately NO dead-pixel calibration: direct analysis of
production frames found zero interior dead pixels — every zero-valued
pixel is frame-edge geometry (left optical-black columns + truncated
trailing read-out rows), which the firmware describes with the DNG
ActiveArea/DefaultCrop tags instead.)

Noise calibration (`noise`) sweeps a list of analogue gains; per gain it
captures PAIRED flat frames at several illumination levels (halving
exposures against a static, evenly lit surface), computes the photon
transfer curve per tile (difference-frame variance vs mean, on the DNG
NoiseProfile's normalized 0-1 signal scale) and least-squares fits
variance = a*signal + b — per CFA channel (R/G/B, greens pooled) on
colour cartridges, single-channel on mono.  Saved as
calibration/<id>_noise_profile.json; the firmware interpolates (a, b)
for each capture's analogue gain and writes the NoiseProfile tag.

FILE IDENTITY: <id> is the variant-qualified sensor id (calib_id_for) —
`imx585` for a colour cartridge, `imx585_mono` for the full-spectrum
mono variant.  Colour and mono variants of one sensor report the SAME
libcamera model, so files keyed by model alone would silently collide
across cartridges; the variant is detected from the captured frames
(noise) or a one-shot lit frame / --variant flag (baseline-exposure),
and the firmware resolves the matching file from its runtime mono
verdict, re-resolving on a cartridge swap.

Both cartridge families (IMX294 colour, IMX492 mono, and the rest) use
this same script: everything is derived from the enumerated raw modes and
the captured data, never from a hardcoded sensor model.

DEPLOYMENT: update.sh installs a byte-for-byte copy of this file to
/home/pi/dng_calibrate.py (the OTA flow only ever delivers wlf8.py +
update.sh, so the tool rides along embedded there).  When editing this
file, update the heredoc in update.sh to match.
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

import numpy as np

CALIB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "calibration")

# ---------------------------------------------------------------------------
# Raw helpers.  Deliberately self-contained duplicates of the pure helpers in
# wlf8.py (_raw_unpack_to_u16 / _dng_infer_shift): importing wlf8 executes
# the whole firmware, which this script must not do.  Only the unpacked
# 16-bit container formats the firmware actually configures are needed here.
# ---------------------------------------------------------------------------


def unpack_raw(buf, cfg):
    """Raw stream buffer -> 2-D uint16 array of container values."""
    w, h = cfg["size"]
    stride = cfg.get("stride") or w * 2
    data = np.asarray(buf, dtype=np.uint8).reshape(-1)
    rows = data[: h * stride].reshape(h, stride)[:, : w * 2]
    return np.ascontiguousarray(rows).view(np.uint16).reshape(h, w)


def infer_shift(u16):
    """LSB padding bits in the 16-bit container (12-bit data is stored
    MSB-aligned by the CFE) — same data-driven rule as the firmware."""
    sub = u16[::16, ::16]
    or_all = int(np.bitwise_or.reduce(sub, axis=None))
    if or_all == 0:
        return 0
    shift = (or_all & -or_all).bit_length() - 1
    if shift == 0 and np.array_equal(sub >> 12, sub & 0xF):
        return 4
    return min(shift, 8)


def pick_full_res_mode(picam2):
    """Largest-area 12-bit raw mode — the geometry the firmware's full-res
    captures use, which is the geometry the calibration must be stored in."""
    modes = [m for m in picam2.sensor_modes if m.get("bit_depth") == 12]
    if not modes:
        modes = list(picam2.sensor_modes)
    return max(modes, key=lambda m: m["size"][0] * m["size"][1])


def bayer_planes(frame, mono):
    """Channel-name -> sample-plane mapping.  RGGB phase order matches the
    firmware's raw formats; both greens pool into one G channel (the DNG
    NoiseProfile carries 3 planes for CFA data)."""
    if mono:
        return {"Y": [frame]}
    return {
        "R": [frame[0::2, 0::2]],
        "G": [frame[0::2, 1::2], frame[1::2, 0::2]],
        "B": [frame[1::2, 1::2]],
    }


def detect_mono(frame, black):
    """CFA-less sensors show statistically identical Bayer phases; colour
    sensors diverge strongly under any real illuminant (same rule as the
    firmware's runtime mono classification, simplified).  Returns None on
    a frame too dark to judge — a lens-capped frame reads as phase-flat
    and would misdetect as mono."""
    white = 4095.0
    means = [float(frame[dy::2, dx::2].mean()) - black
             for dy in (0, 1) for dx in (0, 1)]
    if max(means) < 0.03 * (white - black):
        return None
    return max(means) / max(min(means), 1e-6) < 1.04


def calib_id_for(model, mono):
    """Variant-qualified calibration identity — colour and mono variants of
    one sensor report the SAME libcamera model, so files keyed by model
    alone would collide across cartridges.  Must match the firmware's
    _dng_sensor_calib_id (mono gets a `_mono` suffix, the same convention
    as the platform's imx585_mono.json tuning)."""
    return f"{model}_mono" if mono else model


def photon_transfer_points(frame_a, frame_b, black, white, tile=64):
    """Per-tile (mean, variance) photon-transfer samples from a pair of
    identically exposed flats, normalized to the DNG NoiseProfile's [0,1]
    signal scale.  The variance of the frame DIFFERENCE (halved) isolates
    temporal noise — fixed-pattern differences between photosites cancel."""
    span = white - black
    a = frame_a.astype(np.float32)
    d = a - frame_b.astype(np.float32)
    h, w = a.shape
    th, tw = h // tile, w // tile
    a = a[: th * tile, : tw * tile].reshape(th, tile, tw, tile)
    d = d[: th * tile, : tw * tile].reshape(th, tile, tw, tile)
    means = a.mean(axis=(1, 3))
    variances = d.var(axis=(1, 3)) / 2.0
    signal = (means - black) / span
    keep = (signal > 0.02) & (signal < 0.85)   # off the pedestal and clip
    return signal[keep], variances[keep] / (span * span)


def cmd_noise(args):
    from picamera2 import Picamera2

    picam2 = Picamera2()
    model = str(picam2.camera_properties.get("Model", "")).strip().lower()
    if not model:
        print("ERROR: sensor model unavailable")
        return 1
    mode = pick_full_res_mode(picam2)
    w, h = mode["size"]
    print(f"Sensor: {model}  mode: {w}x{h}@{mode.get('bit_depth')}")
    gains = [float(g) for g in args.gains.split(",")]
    levels = [args.max_exposure_us // (2 ** i)
              for i in range(args.levels - 1, -1, -1)]

    config = picam2.create_still_configuration(
        raw={"size": (w, h), "format": "R16"},
        sensor={"output_size": (w, h),
                "bit_depth": mode.get("bit_depth", 12)},
        buffer_count=1,
    )
    picam2.configure(config)
    picam2.start()
    input("\nAim at a STATIC, EVENLY LIT surface (defocused; bright enough "
          "to near-fill the histogram at the longest exposure), then press "
          "Enter... ")

    md = picam2.capture_metadata()
    sbl = md.get("SensorBlackLevels") or (3200,) * 4
    mono = None
    entries = []
    for gain in gains:
        pts = {}
        for exp_us in levels:
            picam2.set_controls({"AeEnable": False, "AnalogueGain": gain,
                                 "ExposureTime": int(exp_us)})
            # Let the controls land before the measured pair.
            for _ in range(3):
                picam2.capture_metadata()
            pair = []
            for _ in range(2):
                req = picam2.capture_request()
                try:
                    buf = req.make_buffer("raw")
                    cfg = req.config["raw"]
                finally:
                    req.release()
                u16 = unpack_raw(buf, cfg)
                shift = infer_shift(u16)
                bits = 16 - shift
                pair.append(u16 >> shift if shift else u16)
            white = float((1 << bits) - 1)
            black = float(np.mean(sbl)) * white / 65535.0
            if mono is None:
                mono = detect_mono(pair[0], black)
                if mono is None:
                    print("  frame too dark to classify the cartridge — "
                          "skipping this level")
                    continue
                print(f"  cartridge reads as "
                      f"{'MONO' if mono else 'COLOUR'}")
            planes_a = bayer_planes(pair[0], mono)
            planes_b = bayer_planes(pair[1], mono)
            for name in planes_a:
                for pa, pb in zip(planes_a[name], planes_b[name]):
                    s, v = photon_transfer_points(pa, pb, black, white)
                    if s.size:
                        pts.setdefault(name, ([], []))
                        pts[name][0].append(s)
                        pts[name][1].append(v)
            print(f"  gain {gain:g} exp {exp_us}us captured")
        channels = {}
        for name, (s_list, v_list) in pts.items():
            s = np.concatenate(s_list)
            v = np.concatenate(v_list)
            if s.size < 32:
                print(f"  gain {gain:g} {name}: too few usable tiles "
                      f"({s.size}) — check illumination; skipping channel")
                continue
            # Least-squares fit of variance = a*signal + b.
            a_fit, b_fit = np.polyfit(s, v, 1)
            channels[name] = [float(max(a_fit, 0.0)),
                              float(max(b_fit, 0.0))]
            print(f"  gain {gain:g} {name}: a={channels[name][0]:.3e} "
                  f"b={channels[name][1]:.3e} ({s.size} tiles)")
        if channels:
            entries.append({"gain": gain, "channels": channels})
    picam2.stop()

    if not entries:
        print("ERROR: no usable photon-transfer data — nothing saved")
        return 1
    payload = {
        "sensor": model, "mono": bool(mono),
        "width": int(w), "height": int(h),
        "created": datetime.now(timezone.utc).isoformat(),
        "levels_us": levels,
        "gains": entries,
    }
    os.makedirs(CALIB_DIR, exist_ok=True)
    out = os.path.join(CALIB_DIR,
                       f"{calib_id_for(model, mono)}_noise_profile.json")
    tmp = out + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(payload, fh, indent=1)
    os.replace(tmp, out)
    print(f"\nSaved {out}")
    print("Restart the camera firmware to pick it up.")
    return 0


def cmd_baseline_exposure(args):
    """Store a measured per-cartridge BaselineExposure (see the module
    docstring for the grey-card measurement procedure).  The cartridge
    VARIANT (colour vs full-spectrum mono) is part of the file identity —
    both variants of one sensor report the same libcamera model — so it is
    detected from a live frame (aim at anything lit), or forced with
    --variant when detection is impractical."""
    from picamera2 import Picamera2

    ev = float(args.ev)
    if not (-4.0 <= ev <= 4.0):
        print("ERROR: --ev out of plausible range (-4..4)")
        return 1
    if abs(ev - 1.0) < 1e-9:
        print("WARNING: exactly +1.00 EV is the old PiDNG boilerplate "
              "value — double-check this is a real measurement")
    picam2 = Picamera2()
    model = str(picam2.camera_properties.get("Model", "")).strip().lower()
    if not model:
        print("ERROR: sensor model unavailable")
        picam2.close()
        return 1
    if args.variant == "auto":
        mode = pick_full_res_mode(picam2)
        w, h = mode["size"]
        config = picam2.create_still_configuration(
            raw={"size": (w, h), "format": "R16"},
            sensor={"output_size": (w, h),
                    "bit_depth": mode.get("bit_depth", 12)},
            buffer_count=1,
        )
        picam2.configure(config)
        picam2.start()
        input("\nAim at anything EVENLY LIT (variant detection needs "
              "signal), then press Enter... ")
        md = picam2.capture_metadata()
        sbl = md.get("SensorBlackLevels") or (3200,) * 4
        req = picam2.capture_request()
        try:
            buf = req.make_buffer("raw")
            cfg = req.config["raw"]
        finally:
            req.release()
        picam2.stop()
        u16 = unpack_raw(buf, cfg)
        shift = infer_shift(u16)
        bits = 16 - shift
        if shift:
            u16 = u16 >> shift
        black = float(np.mean(sbl)) * ((1 << bits) - 1) / 65535.0
        mono = detect_mono(u16, black)
        if mono is None:
            print("ERROR: frame too dark to classify the cartridge — "
                  "aim at a lit scene or pass --variant colour|mono")
            picam2.close()
            return 1
        print(f"Cartridge reads as {'MONO' if mono else 'COLOUR'}")
    else:
        mono = args.variant == "mono"
    picam2.close()
    payload = {
        "sensor": model,
        "mono": bool(mono),
        "ev": ev,
        "created": datetime.now(timezone.utc).isoformat(),
    }
    os.makedirs(CALIB_DIR, exist_ok=True)
    out = os.path.join(
        CALIB_DIR, f"{calib_id_for(model, mono)}_baseline_exposure.json")
    tmp = out + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(payload, fh, indent=1)
    os.replace(tmp, out)
    print(f"Saved {out} ({ev:+.2f} EV)")
    print("Restart the camera firmware to pick it up.")
    return 0


def find_tuning_path(model):
    """Path of the tuning file libcamera would use for this sensor: the env
    override wins, then <model>.json in the standard IPA data dirs —
    /usr/local first, since a self-built libcamera install shadows the
    distro copy at runtime."""
    env = os.environ.get("LIBCAMERA_RPI_TUNING_FILE")
    if env and os.path.isfile(env):
        return env
    for prefix in ("/usr/local", "/usr"):
        for pipe in ("pisp", "vc4"):
            path = os.path.join(prefix, "share/libcamera/ipa/rpi",
                                pipe, model + ".json")
            if os.path.isfile(path):
                return path
    return None


def tuning_algo(tuning, name):
    """An algorithm's config dict from either tuning JSON format (2.0's
    `algorithms` list of single-key dicts, or the legacy flat layout)."""
    algos = tuning.get("algorithms")
    if isinstance(algos, list):
        for entry in algos:
            if isinstance(entry, dict) and name in entry:
                return entry[name]
        return None
    return tuning.get(name)


def ct_curve_rb(curve, ct):
    """(r, b) the tuning's ct_curve claims at `ct` — flat [ct, r, b, ...]
    triples, linearly interpolated, clamped at the ends."""
    pts = sorted((float(curve[i]), float(curve[i + 1]), float(curve[i + 2]))
                 for i in range(0, len(curve) - 2, 3))
    cts = [p[0] for p in pts]
    r = float(np.interp(ct, cts, [p[1] for p in pts]))
    b = float(np.interp(ct, cts, [p[2] for p in pts]))
    return r, b


def cmd_awb(args):
    """Measure the grey point (r = R/G, b = B/G, linear raw domain) under
    one known light source and maintain calibration/<id>_awb_points.json;
    see the module docstring for the full procedure."""
    from picamera2 import Picamera2

    ct = float(args.ct)
    if not (1500.0 <= ct <= 12000.0):
        print("ERROR: --ct out of plausible range (1500..12000 K)")
        return 1
    picam2 = Picamera2()
    model = str(picam2.camera_properties.get("Model", "")).strip().lower()
    if not model:
        print("ERROR: sensor model unavailable")
        picam2.close()
        return 1
    mode = pick_full_res_mode(picam2)
    w, h = mode["size"]
    print(f"Sensor: {model}  mode: {w}x{h}@{mode.get('bit_depth')}")
    config = picam2.create_still_configuration(
        raw={"size": (w, h), "format": "R16"},
        sensor={"output_size": (w, h),
                "bit_depth": mode.get("bit_depth", 12)},
        buffer_count=1,
    )
    picam2.configure(config)
    picam2.start()
    if args.exposure_us and args.gain:
        picam2.set_controls({"AeEnable": False,
                             "ExposureTime": int(args.exposure_us),
                             "AnalogueGain": float(args.gain)})
    input(f"\nFill the frame CENTRE with the grey card under the "
          f"{args.label or f'{ct:.0f}K'} source (even light, nothing "
          f"clipped), then press Enter... ")
    # Let AE (or the manual controls) land before the measured frame.
    for _ in range(10):
        md = picam2.capture_metadata()
    sbl = md.get("SensorBlackLevels") or (3200,) * 4
    req = picam2.capture_request()
    try:
        buf = req.make_buffer("raw")
        cfg = req.config["raw"]
    finally:
        req.release()
    picam2.stop()
    picam2.close()

    u16 = unpack_raw(buf, cfg)
    shift = infer_shift(u16)
    bits = 16 - shift
    if shift:
        u16 = u16 >> shift
    white = float((1 << bits) - 1)
    black = float(np.mean(sbl)) * white / 65535.0
    span = white - black
    mono = detect_mono(u16, black)
    if mono is None:
        print("ERROR: frame too dark to classify the cartridge")
        return 1
    if mono:
        print("ERROR: AWB calibration applies to COLOUR cartridges only")
        return 1
    # Central patch, offsets kept even so the CFA phase is preserved.
    fh, fw = u16.shape
    y0, x0 = (fh // 2 - fh // 6) & ~1, (fw // 2 - fw // 6) & ~1
    patch = u16[y0:y0 + 2 * (fh // 6), x0:x0 + 2 * (fw // 6)]
    clip_frac = float(np.count_nonzero(patch >= white * 0.98)) / patch.size
    if clip_frac > 0.005:
        print(f"ERROR: {clip_frac * 100:.1f}% of the patch is clipped — "
              f"dim the light, shorten the exposure (--exposure-us/--gain), "
              f"or step back")
        return 1
    planes = bayer_planes(patch, mono=False)
    means = {name: float(np.mean([p.mean() for p in ps])) - black
             for name, ps in planes.items()}
    if means["G"] < 0.05 * span:
        print("ERROR: patch too dark — add light or lengthen the exposure")
        return 1
    if min(means.values()) <= 0.0:
        print("ERROR: a channel reads at/below the black level — bad frame")
        return 1
    r, b = means["R"] / means["G"], means["B"] / means["G"]
    print(f"\nMeasured grey point at {ct:.0f}K: r {r:.4f}  b {b:.4f}  "
          f"(gains R {1.0 / r:.3f}  B {1.0 / b:.3f}; patch G at "
          f"{means['G'] / span * 100:.0f}% of range, clip {clip_frac * 100:.2f}%)")

    # Merge into the per-cartridge points file (same-CT point replaced).
    os.makedirs(CALIB_DIR, exist_ok=True)
    out = os.path.join(CALIB_DIR,
                       f"{calib_id_for(model, False)}_awb_points.json")
    points = []
    try:
        with open(out) as fh_in:
            points = [p for p in json.load(fh_in).get("points", [])
                      if abs(float(p["ct"]) - ct) > 1.0]
    except Exception:
        pass
    points.append({"ct": ct, "r": round(r, 4), "b": round(b, 4),
                   "label": args.label,
                   "created": datetime.now(timezone.utc).isoformat()})
    points.sort(key=lambda p: float(p["ct"]))
    tmp = out + ".tmp"
    with open(tmp, "w") as fh_out:
        json.dump({"sensor": model, "points": points}, fh_out, indent=1)
    os.replace(tmp, out)
    print(f"Saved {out} ({len(points)} point(s))")

    # Compare against — and emit a replacement for — the installed curve.
    tuning_path = find_tuning_path(model)
    curve = None
    if tuning_path:
        try:
            with open(tuning_path) as fh_in:
                awb_cfg = tuning_algo(json.load(fh_in), "rpi.awb") or {}
            curve = awb_cfg.get("ct_curve")
            if curve:
                print(f"\nInstalled tuning: {tuning_path}")
                for p in points:
                    cr, cb = ct_curve_rb(curve, float(p["ct"]))
                    print(f"  {float(p['ct']):5.0f}K  measured r {p['r']:.4f} "
                          f"b {p['b']:.4f}   curve claims r {cr:.4f} b {cb:.4f}"
                          f"   delta r {p['r'] - cr:+.4f} b {p['b'] - cb:+.4f}")
                tp = awb_cfg.get("transverse_pos")
                tn = awb_cfg.get("transverse_neg")
                print(f"  transverse_pos {tp}  transverse_neg {tn}  "
                      f"(0.04-0.05 buys green/magenta headroom for "
                      f"LED/fluorescent sources)")
        except Exception as exc:
            print(f"\n(could not read the installed tuning: {exc})")
    if len(points) >= 2:
        flat = []
        for p in points:
            flat += [f"{float(p['ct']):.1f}", f"{p['r']:.4f}", f"{p['b']:.4f}"]
        print("\nPaste into the tuning's rpi.awb section (backup first, "
              "restart the firmware after):")
        print(f'    "ct_curve": [ {", ".join(flat)} ],')
    else:
        print("\nMeasure at least one more source (2 minimum, 3 spanning "
              "warm->cool recommended) to emit a ct_curve.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_noise = sub.add_parser(
        "noise", help="photon-transfer NoiseProfile calibration")
    p_noise.add_argument("--gains", default="1,2,4,8,16",
                        help="comma-separated analogue gains "
                             "(default 1,2,4,8,16)")
    p_noise.add_argument("--levels", type=int, default=6,
                        help="illumination levels per gain, swept as "
                             "halving exposures (default 6)")
    p_noise.add_argument("--max-exposure-us", type=int, default=33000,
                        help="longest exposure of the sweep (default 33000)")
    p_noise.set_defaults(func=cmd_noise)

    p_bl = sub.add_parser(
        "baseline-exposure",
        help="store a measured per-sensor DNG BaselineExposure")
    p_bl.add_argument("--ev", required=True, type=float,
                      help="measured BaselineExposure in EV "
                           "(grey-card procedure; see --help)")
    p_bl.add_argument("--variant", choices=("auto", "colour", "mono"),
                      default="auto",
                      help="cartridge variant; auto captures one lit frame "
                           "and classifies it (default)")
    p_bl.set_defaults(func=cmd_baseline_exposure)

    p_awb = sub.add_parser(
        "awb", help="grey-card AWB grey-point / ct_curve measurement")
    p_awb.add_argument("--ct", required=True, type=float,
                       help="colour temperature of the light source in "
                            "kelvin (halogen ~2700, warm LED ~3000, cool "
                            "white ~4000, daylight ~5600, overcast ~6500)")
    p_awb.add_argument("--label", default="",
                       help="optional source name stored with the point")
    p_awb.add_argument("--exposure-us", type=int, default=0,
                       help="manual exposure; with --gain, disables AE for "
                            "the measurement (default: auto-expose)")
    p_awb.add_argument("--gain", type=float, default=0.0,
                       help="manual analogue gain (see --exposure-us)")
    p_awb.set_defaults(func=cmd_awb)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
DNG_CALIBRATE_EOF
chown pi:pi /home/pi/dng_calibrate.py 2>/dev/null || true
chmod 755 /home/pi/dng_calibrate.py
log "Installed /home/pi/dng_calibrate.py (per-unit DNG calibration tool)"
info "  Run with the firmware stopped: python3 dng_calibrate.py noise | baseline-exposure | awb"

# --- Install flash_sync_diag.py (optical flash sync bench tool) ---
# Same reasoning as dng_calibrate.py above: the OTA flow only ever delivers
# wlf8.py + this script, and the flash-sync diagnostic has to run ON THE
# CAMERA to answer the question it exists for (can the sensor be driven with
# exposure == frame duration, and what is the residual dead time). It also
# has to live NEXT TO wlf8.py -- its `simulate` sub-command extracts the
# firmware's own detection state machine out of wlf8.py by AST rather than
# reimplementing it, and resolves that path relative to its own location.
# The heredoc is a byte-for-byte copy of flash_sync_diag.py at the source
# repo root -- keep the two in sync when editing either.
cat > /home/pi/flash_sync_diag.py <<'FLASH_SYNC_DIAG_EOF'
#!/usr/bin/env python3
"""Task-zero diagnostic for optical flash sync (WLV-01 / IMX294 + IMX492).

Answers one question, with measurements rather than assumptions:

    Can this camera be driven with exposure duration == frame duration,
    with zero (or negligible) vertical blanking, so that every sensor row
    integrates CONTINUOUSLY across the frame boundary?

That property is what the firmware's flash SELECTION rests on.  With a
rolling shutter, a hand-fired flash either fires after every row has
opened -- one frame is then a complete, uniformly lit exposure and the
firmware saves it byte for byte -- or it lands mid-readout, splitting
complementarily across frames N and N+1; the firmware then row-SPLICES the
two lit halves (verbatim rows from each) or rejects the shot.  The odds of
the complete-frame case are (frame period - readout) / frame period, so a
slower flash fps directly buys keepers (`model` prints the table).  Dead
time -- any gap where a row is blind between frames -- is what puts a
residual dip at a splice's seam, and this tool measures it.

Run ON THE CAMERA with the firmware stopped (it owns the camera):

    systemctl stop camera 2>/dev/null; systemctl --user stop camera 2>/dev/null

    python3 flash_sync_diag.py timing              # the main answer
    python3 flash_sync_diag.py timing --mode 3792x2824
    python3 flash_sync_diag.py model               # theory only, no camera
    python3 flash_sync_diag.py flash               # fire a flash by hand

Sub-commands
------------
`timing`  Sweeps frame durations, pins ExposureTime to the frame duration,
          and reports what the SENSOR actually did -- achieved exposure,
          achieved frame period from SensorTimestamp deltas, the resulting
          dead time in microseconds, as a percentage of the frame period,
          and as an equivalent number of image rows.  Also reports frame
          period jitter and dropped frames, because a dropped frame breaks
          the complementary split just as surely as dead time does.

`model`   Prints the dead time predicted from the sensor's own register
          model, with no camera attached.  Integration time on the IMX29x
          is  [{VMAX*(SVR+1) - SHR} * HMAX + offset] / 72 MHz  and the
          frame period is  VMAX*(SVR+1)*HMAX / 72 MHz , so the maximum
          integration falls short of the frame period by exactly

              dead = (min_SHR * HMAX - integration_offset) / 72 MHz

          which is a per-mode CONSTANT, independent of frame rate.  That is
          the single most useful fact in this file: slowing the frame rate
          does not shrink the dead time in microseconds, it only shrinks it
          as a fraction of the frame period.  `timing` measures the same
          quantity end-to-end through libcamera; they should agree.

`flash`   The empirical proof.  Free-runs the sensor at the chosen frame
          duration into a small ring, waits for you to fire a manual flash
          by hand, then runs the FIRMWARE'S OWN candidate metrics and
          selection gates (extracted from wlf8.py by AST) on the captured
          window and prints the per-candidate numbers plus the exact
          SAVE / SPLICE / REJECT verdict the camera would have produced.

Requires only numpy + picamera2, both already on the camera.  Nothing here
is imported by the firmware; this is a bench tool.
"""

import argparse
import json
import os
import statistics
import sys
import time

# numpy is imported lazily by `flash` only, so `model` runs anywhere — it is
# pure arithmetic over the register table and answers the design question
# without a camera attached.


# ---------------------------------------------------------------------------
# Sensor register model (from the imx294-imx492-v4l2-driver mode tables).
#
# Only the fields that set the exposure/frame-period relationship are
# reproduced.  This table exists so `model` can answer without a camera and
# so `timing` can cross-check its measurement against the silicon -- it is
# NOT used to decide anything at runtime.  Keys are (model, width, height);
# the firmware itself stays sensor-agnostic and reads everything from
# libcamera.
# ---------------------------------------------------------------------------
_TIMING_CLOCK_HZ = 72_000_000        # IMX29x default; per-mode `clk` overrides

# Per-entry fields:
#   hmax, min_vmax   sensor timing registers for the mode
#   min_shr          the shutter-sweep floor, in lines -- this is what the
#                    dead time IS, expressed in rows
#   offset           the IMX29x integration_offset term; 0 where the driver's
#                    formula has none (IMX585: integration = exposure * HMAX)
#   shr_quant        SHR granularity in lines; the IMX585 driver forces SHR
#                    even (`shr = (vmax - exposure) & ~1U`), which costs up to
#                    one extra line of dead time on top of min_shr
#   clk              timing clock; IMX29x runs HMAX/VMAX at 72 MHz, IMX585 at
#                    74.25 MHz
_MODE_MODEL = {
    # IMX294, 12-bit
    ("imx294", 8432, 5648): dict(min_hmax=1202, hmax=1202, min_vmax=5728, min_shr=12, offset=256, qbc=True),
    ("imx294", 7680, 5648): dict(min_hmax=1108, hmax=1108, min_vmax=5728, min_shr=12, offset=256, qbc=True),
    ("imx294", 4144, 2176): dict(min_hmax=1122, hmax=1200, min_vmax=1111, min_shr=5, offset=256, vscale=2),
    ("imx294", 4176, 2176): dict(min_hmax=1192, hmax=1200, min_vmax=1111, min_shr=5, offset=361, vscale=2),
    ("imx294", 3872, 2176): dict(min_hmax=1055, hmax=1200, min_vmax=1111, min_shr=5, offset=256, vscale=2),
    ("imx294", 3792, 2824): dict(min_hmax=1034, hmax=1875, min_vmax=1444, min_shr=5, offset=256, vscale=2),
    # IMX492, 12-bit
    ("imx492", 8432, 5648): dict(min_hmax=1202, hmax=1202, min_vmax=5728, min_shr=12, offset=256),
    ("imx492", 8432, 4348): dict(min_hmax=1202, hmax=1202, min_vmax=4428, min_shr=12, offset=256),
    ("imx492", 7680, 5648): dict(min_hmax=1108, hmax=1108, min_vmax=5728, min_shr=12, offset=256),
    ("imx492", 3792, 2824): dict(min_hmax=2048, hmax=3750, min_vmax=1444, min_shr=5, offset=551, vscale=2),
    # IMX585, 12-bit.  A different driver with a simpler timing model:
    # integration = exposure_lines * HMAX / 74.25 MHz and max exposure =
    # VMAX - SHR_MIN, so there is no integration_offset and the dead time is
    # simply min_SHR lines.  HMAX is NOT a per-mode constant here -- it comes
    # from a link-frequency table (HMAX_table_4lane_4K_12bit) and doubles on a
    # 2-lane link, so the values below are the overlay default (720 MHz,
    # 4-lane).  The dead time in MICROSECONDS therefore moves with the link
    # setup; the dead time in ROWS does not, and rows are what a band is
    # measured in.  Pass --hmax to recompute for another link/lane config.
    ("imx585", 3840, 2160): dict(min_hmax=660, hmax=660, min_vmax=2250, min_shr=8, offset=0,
                                 shr_quant=2, clk=74_250_000),
    ("imx585", 1920, 1080): dict(min_hmax=660, hmax=660, min_vmax=2250, min_shr=8, offset=0,
                                 shr_quant=2, clk=74_250_000, binned=True),
}
# The IMX585's 16-bit Clear HDR mode (3840x2200, SHR_MIN 16, a dual HG+LG read
# per frame) is deliberately absent: the firmware's sensor-mode dropdown
# filters to 12-bit, so it is never selected, and a dual read per frame is not
# something the complementary-split model is known to hold for.  If it is ever
# exposed, verify it with `flash` before trusting a reconstruction from it.


def _model_lookup(sensor_model, width, height):
    """Register model for (sensor, size), or None when the mode is unknown.

    Matched on a model SUBSTRING so 'imx294' covers the mono variant and any
    driver-decorated name, exactly like the firmware's own per-sensor tables.
    """
    key = str(sensor_model or "").lower()
    for (mdl, w, h), spec in _MODE_MODEL.items():
        if mdl in key and int(w) == int(width) and int(h) == int(height):
            return spec
    return None


def _model_clk(spec):
    return spec.get("clk", _TIMING_CLOCK_HZ)


def _model_dead_us(spec):
    """Dead time per frame, in microseconds, from the register model.

    dead = (min_SHR * HMAX - integration_offset) / clk

    plus (shr_quant - 1) lines where the driver quantises SHR.  A per-mode
    constant either way: VMAX does not appear, so it does not move with VMAX
    and therefore does not move with frame rate.
    """
    ticks = spec["min_shr"] * spec["hmax"] - spec.get("offset", 0)
    ticks += (spec.get("shr_quant", 1) - 1) * spec["hmax"]
    return max(0.0, ticks * 1e6 / _model_clk(spec))


def _model_row_us(spec):
    """One OUTPUT row period in microseconds.  On the IMX29x vscale=2 modes
    a register line (HMAX ticks) spans two output rows — the driver's
    pixel_rate is width * clk * vmax_scale / hmax — so the per-row period is
    hmax / (clk * vscale).  Sanity check that pins this: readout must fit in
    the minimum frame (IMX294 3792x2824: 2824 rows x 13.02 us = 36.8 ms
    against the 37.6 ms floor; the un-scaled reading would put readout at
    73.5 ms inside a 37.6 ms frame, which is impossible)."""
    return spec["hmax"] * 1e6 / (_model_clk(spec) * spec.get("vscale", 1))


def _model_min_frame_us(spec):
    """Shortest frame period the mode allows, microseconds.

    Uses min_hmax, not the mode table's default_hmax: libcamera drives HBLANK
    to the sensor's minimum, so the achievable floor is min_VMAX x min_HMAX.
    Field-confirmed — captures from the IMX492 3792x2824 mode tag 41.016 ms
    (~24 fps), matching min_hmax 2048, where default_hmax 3750 would predict
    75.2 ms and wrongly suggest the mode could not reach 24 fps at all."""
    return (spec["min_vmax"] * spec.get("min_hmax", spec["hmax"])
            * 1e6 / _model_clk(spec))


def _verdict(dead_us, frame_us, row_us):
    """Human verdict + the numbers that matter for band artifacts."""
    frac = dead_us / frame_us if frame_us > 0 else 0.0
    rows = dead_us / row_us if row_us > 0 else 0.0
    if frac < 0.01:
        word = "NEGLIGIBLE"
    elif frac < 0.05:
        word = "SMALL"
    else:
        word = "SIGNIFICANT"
    return word, frac, rows


# ---------------------------------------------------------------------------
# Camera helpers
# ---------------------------------------------------------------------------

def _open_camera():
    from picamera2 import Picamera2
    return Picamera2()


def _raw_modes(picam2):
    """12-bit raw modes, newest picamera2 first, falling back to the slow
    property.  Mirrors the firmware's fast enumeration so this tool sees the
    same list the camera UI offers."""
    modes = []
    fast = getattr(picam2, "_raw_modes", None)
    src = fast if fast else getattr(picam2, "sensor_modes", [])
    for m in src or []:
        try:
            size = tuple(m.get("size"))
            fmt = str(m.get("format"))
            bits = m.get("bit_depth")
            if bits is None:
                digits = "".join(c for c in fmt if c.isdigit())
                bits = int(digits) if digits else 0
            modes.append({"size": size, "format": fmt, "bit_depth": int(bits)})
        except Exception:
            continue
    twelve = [m for m in modes if m["bit_depth"] == 12]
    return twelve or modes


def _pick_mode(picam2, want):
    modes = _raw_modes(picam2)
    if not modes:
        raise SystemExit("no raw modes enumerated — is the driver loaded?")
    if want:
        w, h = (int(v) for v in want.lower().split("x"))
        for m in modes:
            if tuple(m["size"]) == (w, h):
                return m
        raise SystemExit(
            "mode %s not advertised; available: %s"
            % (want, ", ".join("%dx%d" % tuple(m["size"]) for m in modes)))
    # Default to the SMALLEST 12-bit mode: it is the one a continuous ring
    # buffer can actually sustain, and dead time is what we are measuring,
    # not resolution.
    return min(modes, key=lambda m: m["size"][0] * m["size"][1])


def _configure(picam2, mode, frame_us, exposure_us, gain):
    w, h = mode["size"]
    cfg = picam2.create_still_configuration(
        main={"size": (640, 480), "format": "RGB888"},
        raw={"size": (w, h), "format": "R16"},
        sensor={"output_size": (w, h), "bit_depth": mode["bit_depth"]},
        buffer_count=4,
        controls={
            # Everything auto is a confound: AE chasing the flash, AWB
            # chasing the flash, and any auto black level all break the
            # frame arithmetic this tool exists to validate.
            "AeEnable": False,
            "AwbEnable": False,
            "ExposureTime": int(exposure_us),
            "AnalogueGain": float(gain),
            "FrameDurationLimits": (int(frame_us), int(frame_us)),
            "NoiseReductionMode": 0,
        },
    )
    picam2.configure(cfg)
    return cfg


def _drain_to(picam2, exposure_us, tries=12):
    """Pull metadata until the sensor reports the requested exposure, so the
    measurement never includes pre-change frames still in flight."""
    tol = max(200, int(exposure_us) // 20)
    last = None
    for _ in range(tries):
        md = picam2.capture_metadata()
        last = md
        if abs(int(md.get("ExposureTime") or 0) - int(exposure_us)) <= tol:
            return md
    return last


def _collect(picam2, n):
    """n frames of (ExposureTime, FrameDuration, SensorTimestamp)."""
    out = []
    for _ in range(n):
        md = picam2.capture_metadata()
        out.append((
            int(md.get("ExposureTime") or 0),
            int(md.get("FrameDuration") or 0),
            int(md.get("SensorTimestamp") or 0),
        ))
    return out


# ---------------------------------------------------------------------------
# `timing`
# ---------------------------------------------------------------------------

def cmd_timing(args):
    picam2 = _open_camera()
    try:
        model = str(picam2.camera_properties.get("Model", "")).lower()
        mode = _pick_mode(picam2, args.mode)
        w, h = mode["size"]
        spec = _model_lookup(model, w, h)

        print("=" * 72)
        print("FLASH SYNC TIMING DIAGNOSTIC")
        print("=" * 72)
        print("sensor      : %s" % (model or "?"))
        print("mode        : %dx%d @ %d-bit (%s)"
              % (w, h, mode["bit_depth"], mode["format"]))
        print("raw frame   : %.1f MB (uint16 container)" % (w * h * 2 / 1e6,))
        if spec:
            print("register    : HMAX=%d  min_SHR=%d  offset=%d  "
                  "row=%.2f us  fastest frame=%.2f ms"
                  % (spec["hmax"], spec["min_shr"], spec["offset"],
                     _model_row_us(spec), _model_min_frame_us(spec) / 1000.0))
            print("predicted   : dead time %.1f us per frame (constant)"
                  % _model_dead_us(spec))
        else:
            print("register    : mode not in the local table — measurement only")
        print()

        # Frame-duration sweep, clamped to what the pipeline advertises.
        durations = [int(1e6 / f) for f in args.fps]
        first = True
        rows_out = []
        for frame_us in durations:
            if first:
                _configure(picam2, mode, frame_us, frame_us, args.gain)
                picam2.start()
                time.sleep(0.4)
                first = False
            else:
                picam2.set_controls({
                    "FrameDurationLimits": (frame_us, frame_us),
                    "ExposureTime": frame_us,
                })
            lim = (picam2.camera_controls or {}).get("FrameDurationLimits")
            if lim and not (int(lim[0]) <= frame_us <= int(lim[1])):
                print("  %6.1f fps  -> out of range %s, skipped"
                      % (1e6 / frame_us, lim))
                continue
            _drain_to(picam2, frame_us)
            samples = _collect(picam2, args.frames)

            exp = [s[0] for s in samples]
            fdur = [s[1] for s in samples]
            ts = [s[2] for s in samples if s[2] > 0]
            deltas = [(b - a) / 1000.0 for a, b in zip(ts, ts[1:])]  # us

            exp_mean = statistics.mean(exp)
            # Prefer the measured timestamp cadence over the reported
            # FrameDuration: the timestamps are what the sensor actually
            # did, and a dropped frame shows up here and nowhere else.
            if deltas:
                per_mean = statistics.median(deltas)
                jitter = (max(deltas) - min(deltas))
                dropped = sum(1 for d in deltas if d > per_mean * 1.5)
            else:
                per_mean = statistics.mean(fdur)
                jitter = 0.0
                dropped = -1

            dead = max(0.0, per_mean - exp_mean)
            row_us = (_model_row_us(spec) if spec
                      else per_mean / float(h))   # fallback: no vblank known
            word, frac, nrows = _verdict(dead, per_mean, row_us)
            rows_out.append({
                "fps_requested": round(1e6 / frame_us, 2),
                "frame_period_us": round(per_mean, 1),
                "exposure_us": round(exp_mean, 1),
                "dead_us": round(dead, 1),
                "dead_pct": round(frac * 100.0, 4),
                "dead_rows": round(nrows, 2),
                "jitter_us": round(jitter, 1),
                "dropped": dropped,
                "verdict": word,
            })
            print("  %6.2f fps req | period %8.1f us | exposure %8.1f us | "
                  "dead %7.1f us (%.3f%%, ~%.1f rows) | jitter %6.1f us | "
                  "drops %d  [%s]"
                  % (1e6 / frame_us, per_mean, exp_mean, dead, frac * 100.0,
                     nrows, jitter, dropped, word))

        picam2.stop()
        print()
        _summarise(rows_out, spec, h)
        if args.json:
            with open(args.json, "w") as fh:
                json.dump({"sensor": model, "mode": [w, h], "rows": rows_out},
                          fh, indent=2)
            print("\nwrote %s" % args.json)
    finally:
        try:
            picam2.close()
        except Exception:
            pass
    return 0


def _summarise(rows, spec, height):
    if not rows:
        print("no usable measurements")
        return
    best = min(rows, key=lambda r: r["dead_pct"])
    worst = max(rows, key=lambda r: r["dead_pct"])
    print("-" * 72)
    print("VERDICT")
    print("-" * 72)
    print("Dead time is %s across the sweep: %.1f us (%.3f%% of the frame "
          "period) at its\nbest, %.1f us (%.3f%%) at its worst."
          % (best["verdict"].lower(), best["dead_us"], best["dead_pct"],
             worst["dead_us"], worst["dead_pct"]))
    if spec:
        print("The measured dead time should be flat in MICROSECONDS across "
              "the sweep (it is a\nregister constant); only its percentage "
              "moves.  Predicted %.1f us." % _model_dead_us(spec))
    print()
    print("Band-artifact floor: a flash shorter than the dead time can be "
          "missed entirely by\nthe rows whose dead window it falls in — at "
          "most ~%.1f rows of %d (%.3f%% of frame\nheight).  A flash LONGER "
          "than the dead time is never fully lost by any row; the\nworst "
          "case becomes a partial dip of (dead / flash duration) at the seam."
          % (best["dead_rows"], height, 100.0 * best["dead_rows"] / height))
    drops = [r for r in rows if r["dropped"] > 0]
    if drops:
        print()
        print("WARNING: dropped frames observed at %s fps.  A dropped frame "
              "destroys the\ncomplementary split outright — the missing half "
              "of the flash is simply gone.\nStay at a frame rate that shows "
              "zero drops."
              % ", ".join(str(r["fps_requested"]) for r in drops))


# ---------------------------------------------------------------------------
# `model`
# ---------------------------------------------------------------------------

def cmd_model(args):
    print("=" * 72)
    print("PREDICTED DEAD TIME FROM THE DRIVER'S REGISTER MODEL")
    print("=" * 72)
    print("Integration = [{VMAX*(SVR+1) - SHR} * HMAX + offset] / clk")
    print("Frame       =  VMAX*(SVR+1) * HMAX / clk")
    print("Dead        = (min_SHR * HMAX - offset) / clk   <- frame-rate "
          "independent")
    print("clk is 72 MHz on the IMX294/492 and 74.25 MHz on the IMX585, whose")
    print("driver has no offset term and quantises SHR to even lines.")
    print()
    hdr = ("%-9s %-12s %8s %8s %8s %9s %10s %10s"
           % ("sensor", "mode", "HMAX", "min_SHR", "offset", "row us",
              "dead us", "dead rows"))
    print(hdr)
    print("-" * len(hdr))
    for (mdl, w, h), spec in sorted(_MODE_MODEL.items()):
        if args.hmax:
            spec = dict(spec, hmax=int(args.hmax))
        dead = _model_dead_us(spec)
        row = _model_row_us(spec)
        print("%-9s %-12s %8d %8d %8d %9.2f %10.1f %10.2f"
              % (mdl, "%dx%d" % (w, h), spec["hmax"], spec["min_shr"],
                 spec.get("offset", 0), row, dead, dead / row))
    print()
    print("At a %.0f ms frame period (%d fps) those dead times are:"
          % (1000.0 / args.fps, args.fps))
    frame_us = 1e6 / args.fps
    for (mdl, w, h), spec in sorted(_MODE_MODEL.items()):
        if args.hmax:
            spec = dict(spec, hmax=int(args.hmax))
        dead = _model_dead_us(spec)
        word, frac, rows = _verdict(dead, frame_us, _model_row_us(spec))
        print("   %-9s %-12s %7.1f us = %.4f%% of frame  (~%.1f rows of %d)  "
              "[%s]" % (mdl, "%dx%d" % (w, h), dead, frac * 100.0, rows, h,
                        word))
    print()
    print("COMPLETE-FRAME KEEPER ODDS for selection: a frame is fully "
          "flash-lit only when\nthe flash fires after the last row opens, "
          "so P = (T - readout) / T, readout being\nthe mode's minimum "
          "frame period.  A requested rate below the mode floor clamps.")
    hdr2 = ("   %-9s %-12s %9s |" % ("sensor", "mode", "readout")
            + "".join("  %4d fps" % f for f in (10, 15, 20, 25, 30)))
    print(hdr2)
    print("   " + "-" * (len(hdr2) - 3))
    for (mdl, w, h), spec in sorted(_MODE_MODEL.items()):
        if args.hmax:
            spec = dict(spec, hmax=int(args.hmax))
        minfr = _model_min_frame_us(spec)
        cells = []
        for f in (10, 15, 20, 25, 30):
            T = max(1e6 / f, minfr)
            cells.append("  %6.0f%%" % (100.0 * max(0.0, 1.0 - minfr / T)))
        print("   %-9s %-12s %7.1fms |%s"
              % (mdl, "%dx%d" % (w, h), minfr / 1000.0, "".join(cells)))
    print()
    print("The remainder split across two frames: spliced when both halves "
          "survive in the\nring (verbatim rows, dead-time residual at the "
          "seam), rejected otherwise.")
    return 0


# ---------------------------------------------------------------------------
# `flash` — the empirical complementary-split proof
# ---------------------------------------------------------------------------

def _raw_view(np, buf, cfg):
    """uint16 view of an R16 raw buffer, honouring stride.  Only the
    unpacked 16-bit container is handled — that is what the firmware
    requests, and a packed format would not be summable anyway."""
    w, h = cfg["size"]
    stride = int(cfg.get("stride") or w * 2)
    data = np.asarray(buf, dtype=np.uint8).reshape(-1)
    if data.size < h * stride:
        pad = np.zeros(h * stride, dtype=np.uint8)
        pad[:data.size] = data
        data = pad
    return data[:h * stride].reshape(h, stride)[:, :w * 2].view(np.uint16)


def cmd_flash(args):
    import numpy as np
    picam2 = _open_camera()
    try:
        model = str(picam2.camera_properties.get("Model", "")).lower()
        mode = _pick_mode(picam2, args.mode)
        w, h = mode["size"]
        spec = _model_lookup(model, w, h)
        frame_us = int(1e6 / args.fps)

        _configure(picam2, mode, frame_us, frame_us, args.gain)
        picam2.start()
        time.sleep(0.5)
        _drain_to(picam2, frame_us)
        raw_cfg = dict(picam2.camera_configuration()["raw"])

        print("Free-running %dx%d at %.1f fps, exposure pinned to the frame "
              "period." % (w, h, args.fps))
        print("Point at a DIM scene and fire the flash by hand now "
              "(%d frames captured)..." % args.frames)

        ring = []
        for _ in range(args.frames):
            req = picam2.capture_request()
            try:
                buf = req.make_buffer("raw")
                arr = _raw_view(np, buf, raw_cfg).copy()
                md = req.get_metadata()
            finally:
                req.release()
            ring.append((arr, int(md.get("SensorTimestamp") or 0)))
        picam2.stop()

        means = np.array([float(a[::16, ::16].mean()) for a, _ in ring])
        base = float(np.median(means))
        peak = int(np.argmax(means))
        if means[peak] < base * (1.0 + args.threshold):
            print("\nNo flash detected (peak %.1f vs baseline %.1f). "
                  "Re-run and fire during the capture window."
                  % (means[peak], base))
            return 1

        print("\nframe means (baseline %.1f):" % base)
        for i, m in enumerate(means):
            mark = " <== peak" if i == peak else ""
            print("  %3d  %9.2f  %+7.1f%%%s"
                  % (i, m, 100.0 * (m - base) / base, mark))

        # Run the FIRMWARE'S OWN selection on the captured window: the same
        # candidate metrics, the same gates, the same verdict the camera
        # would produce for this exact pop.  Candidates are the peak and its
        # immediate neighbours; the ambient reference is two frames back
        # (the frame one back may hold the first half of the split).
        ns = _extract_firmware(args.source, _SELECT_FUNCS, _SELECT_CONSTS)
        amb_i = peak - 2
        lo, hi = max(0, peak - 1), min(len(ring) - 1, peak + 1)
        if amb_i < 0:
            print("\nflash landed too early in the capture window for an "
                  "ambient reference —\nre-run and fire a beat later.")
            return 1
        bits = 16
        stride = int(raw_cfg.get("stride") or w * 2)

        def prof(i):
            return ns["_flash_row_profile"](
                ring[i][0].view(np.uint8).reshape(-1), w, h, stride)

        cands = [(str(i), prof(i)) for i in range(lo, hi + 1)]
        d = ns["_flash_select_frame"](cands, prof(amb_i), bits)
        print("\ncandidate metrics (the firmware's own share-based gates):")
        for sc in d["scored"]:
            m = sc["m"]
            if m is None:
                print("  frame %s: no usable profile" % sc["label"])
                continue
            print("  frame %s: meas %3.0f%%  lit %3.0f%%  worst-share "
                  "%3.0f%%  rise %+7.0f%s"
                  % (sc["label"], 100 * m["meas_frac"],
                     100 * m["share_lit_frac"], 100 * m["share_p05"],
                     m["rise_med"],
                     "" if sc["ok"] else "  -> " + sc["why"]))
        print()
        if d["mode"] == "frame":
            print("VERDICT: SAVE — frame %s is a complete, uniformly "
                  "flash-lit exposure.\nThe camera would save it byte for "
                  "byte." % d["scored"][d["pick"]]["label"])
        elif d["mode"] == "splice":
            print("VERDICT: SPLICE — frames %s (top) + %s (bottom) at row "
                  "%d, band %s,\ndead-time residual %.0f%%.  The camera "
                  "would save verbatim rows from each half."
                  % (d["scored"][d["top"]]["label"],
                     d["scored"][d["bottom"]]["label"], d["seam"],
                     d["band"], 100 * d["residual_dip"]))
            if spec is not None:
                print("(model: dead time %.0f us -> residual = dead / flash "
                      "duration; raise flash power to shrink it)"
                      % _model_dead_us(spec))
        else:
            print("VERDICT: REJECT — %s.  The camera would show 'Flash "
                  "missed — fire again'." % d["reason"])
        pa = cands[0][1]
        pb = cands[-1][1]
        ps = (pa + pb) if pa is not None and pb is not None else None
        if args.save:
            np.savez(args.save, profile_a=pa, profile_b=pb, profile_sum=ps,
                     means=means)
            print("\nwrote %s" % args.save)
    finally:
        try:
            picam2.close()
        except Exception:
            pass
    return 0




# ---------------------------------------------------------------------------
# `simulate` — drive the firmware's OWN detection state machine, no camera
#
# Extracts _flash_ring_push and the flash core straight out of wlf8.py (it is
# not a reimplementation — a copy would drift and prove nothing) and runs a
# simulated free-running sensor past it with hand-fired rolling-shutter
# flashes.  Covers the parts the in-file WLV_FLASH_SELFTEST cannot: the
# firmware's flash state globals are defined thousands of lines below that
# gate, so the sequencing (baseline, refractory, pending window, drop
# accounting) is only reachable from outside.
# ---------------------------------------------------------------------------

# The selection core, shared by `simulate`, `flash` and `analyze` so the
# tool always runs the FIRMWARE'S decision code, never a reimplementation.
_SELECT_FUNCS = (
    "_flash_row_profile", "_flash_profile_smooth", "_flash_metrics_from_rise",
    "_flash_share_metrics", "_flash_score_candidate", "_flash_pair_seam",
    "_flash_select_frame", "_flash_container_alignment", "_flash_splice_pair",
)
_SELECT_CONSTS = (
    "_FLASH_PROFILE_COL_SUB", "_FLASH_PROFILE_SMOOTH_ROWS",
    "_FLASH_SEL_MIN_RISE_FRAC", "_FLASH_SEL_MEAS_FLOOR_FRAC",
    "_FLASH_SEL_MIN_MEAS_FRAC", "_FLASH_SEL_MIN_MEAS_ROWS",
    "_FLASH_SEL_SHARE_LIT", "_FLASH_SEL_MIN_LIT_FRAC",
    "_FLASH_SEL_MIN_SHARE", "_FLASH_SEL_EDGE_ROWS",
    "_FLASH_SPLICE_SHARE_HI", "_FLASH_SPLICE_MAX_BAND_FRAC",
    "_FLASH_SPLICE_MIN_SIDE_FRAC", "_FLASH_SPLICE_DIP_EXEMPT_ROWS",
)

_EXTRACT_FUNCS = (
    "_flash_coarse_plane", "_flash_detect_mean", "_flash_baseline_step",
    "_flash_triggered", "_flash_min_rise", "_flash_row_means",
    "_flash_row_trigger", "_flash_window_indices",
    "_flash_strict_run", "_flash_ring_push", "_flash_armed_fd_us",
    "_flash_measured_period_us", "_raw_black_native", "_raw_format_info",
    "_dng_infer_shift",
) + tuple(_SELECT_FUNCS)
_EXTRACT_CONSTS = (
    "_FLASH_DETECT_STRIDE", "_FLASH_MIN_RISE_FRAC", "_FLASH_WINDOW_BEFORE",
    "_FLASH_WINDOW_AFTER", "_FLASH_REFRACTORY_S", "_FLASH_BASELINE_ALPHA",
    "_FLASH_SUSTAIN_FRAC", "_FLASH_AMBIENT_LOOKBACK",
    "_FLASH_TRIGGER_MIN_ROW_FRAC", "_FLASH_TRIGGER_MAX_DARK_FRAC",
    "_FLASH_TOAST_MIN_RISE",
) + tuple(_SELECT_CONSTS)


def _extract_firmware(path, funcs=None, consts=None):
    """Exec the named functions/constants out of wlf8.py into a fresh
    namespace, without importing it (importing brings up the whole HAL)."""
    funcs = _EXTRACT_FUNCS if funcs is None else funcs
    consts = _EXTRACT_CONSTS if consts is None else consts
    import ast
    import numpy as np
    src = open(path).read()
    lines = src.splitlines(True)
    tree = ast.parse(src)
    chunks = []
    seen = set()
    for node in tree.body:
        if isinstance(node, ast.Assign) and getattr(
                node.targets[0], "id", "") in consts:
            chunks.append("".join(lines[node.lineno - 1:node.end_lineno]))
            seen.add(node.targets[0].id)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in funcs:
            chunks.append("".join(lines[node.lineno - 1:node.end_lineno]))
            seen.add(node.name)
    missing = (set(funcs) | set(consts)) - seen
    if missing:
        raise SystemExit("wlf8.py no longer defines %s at module scope — the "
                         "extraction list in this tool needs updating"
                         % ", ".join(sorted(missing)))

    class _Clock:
        """Virtual monotonic clock, advanced one frame period per pushed
        frame — a tight test loop would otherwise never leave the refractory
        window and the sequencing would go untested."""

        def __init__(self):
            self.t = 1000.0

        def monotonic(self):
            return self.t

    ns = {"np": np, "time": _Clock(), "print": print}
    exec("\n".join(chunks), ns)
    return ns


def cmd_simulate(args):
    import numpy as np
    ns = _extract_firmware(args.source)
    clock = ns["time"]
    W, H = 320, 240
    # The real pipeline's raw stream is a 16-bit container carrying 12-bit
    # values MSB-aligned (x16) — model that, not a bare 12-bit plane, or the
    # scale-relative trigger floor is not being tested at all.
    BITS, BLACK, FD_US = 16, 3200.0, int(1e6 / args.fps)
    AMB, FLASH = 140.0 * 16, args.flash * 16.0
    SEAM, FIRST, SECOND = 96, 9, 9 + args.gap
    # A third pop fired hard on the heels of the second (its split lands in
    # the second's confirm frame): the window-extension path must MERGE it
    # into one exposure instead of misreading it as an ambient step — the
    # field failure was back-to-back pops rejecting the first shot and
    # snapping the baseline to a flash-lit level.
    THIRD = SECOND + 2
    # A lamp switched on partway through the run: +40% ambient, arriving
    # rolling-shutter split like everything else, and PERSISTING.  Must be
    # rejected as not-a-flash (transience test) with the baseline adopted —
    # the field failure was repeated ambient-looking saves, each with a
    # transition line at a different height.
    STEP_AT = SECOND + 9
    STEP = AMB * 0.40

    saves = []
    rejects = []
    pending_box = [0]                  # mirrors _flash_jobs_pending

    def _build_job(seq, after=1, forced_partial=False, strength=0.0):
        # Mirrors the firmware's _flash_build_job policy, then runs the
        # REAL selection functions on the ring's buffers.
        ring = ns["_flash_ring"]
        if pending_box[0] >= 2:        # _FLASH_JOB_QUEUE_MAX
            rejects.append({"seq": seq, "reason": "selection queue full"})
            print("  [sim] queue full — flash dropped (seq %d)" % seq)
            return
        i = next(k for k, e in enumerate(ring) if e["seq"] == seq)
        stamps = [e.get("ts") or 0 for e in ring]
        run = ns["_flash_strict_run"](stamps, i, FD_US)
        if not run:
            rejects.append({"seq": seq, "reason": "no timestamp"})
            return
        lo = max(run[0], i - 1)
        hi = min(run[-1], i + after)
        win = list(range(lo, hi + 1))
        if lo > i - 1 or hi < i + 1:
            rejects.append({"seq": seq, "strength": float(strength),
                            "reason": "dropped frame beside the flash"})
            return
        amb_i = i - ns["_FLASH_AMBIENT_LOOKBACK"]
        if amb_i < 0 or amb_i < run[0]:
            rejects.append({"seq": seq, "reason": "no ambient reference",
                            "strength": float(strength),
                            "window": [ring[k]["seq"] for k in win]})
            return
        prof = lambda e: ns["_flash_row_profile"](e["buf"], W, H, W * 2)
        amb_prof = prof(ring[amb_i])
        cands = [(str(ring[k]["seq"]), prof(ring[k])) for k in win]
        d = ns["_flash_select_frame"](cands, amb_prof, BITS)
        if d["mode"] == "reject":
            rejects.append({"seq": seq, "reason": d["reason"],
                            "strength": float(strength),
                            "window": [ring[k]["seq"] for k in win]})
            return
        if d["mode"] == "frame":
            src = ring[win[d["pick"]]]
            out = np.asarray(src["buf"], np.uint8).copy()
            rec = {"mode": "frame", "pick_seq": src["seq"]}
        else:
            top, bot = ring[win[d["top"]]], ring[win[d["bottom"]]]
            out = ns["_flash_splice_pair"](
                top["buf"], bot["buf"], W, H, W * 2, d["seam"],
                band=d["band"], amb_buf=ring[amb_i]["buf"],
                container_bits=BITS, shift=4)
            rec = {"mode": "splice", "seam": d["seam"], "band": d["band"],
                   "top_seq": top["seq"], "bot_seq": bot["seq"]}
        rec.update({"window": [ring[k]["seq"] for k in win],
                    "out": out.view(np.uint16).reshape(H, W),
                    "amb_seq": ring[amb_i]["seq"]})
        saves.append(rec)

    ns.update(dict(
        _flash_ring=[], _flash_ring_cfg=None, _flash_baseline=None,
        _flash_pending=None, _flash_last_trigger=0.0, _flash_seq=0,
        _flash_black=BLACK, _flash_bits=BITS, _flash_dropped=0,
        _flash_baseline_prof=None,
        _flash_ring_depth=args.depth, _flash_trigger_ratio=args.threshold,
        _flash_frame_duration_us=lambda: FD_US,
        _flash_effective_fd_us=None,
        _flash_build_job=_build_job,
    ))

    class _Req:
        def __init__(self, plane):
            self.plane = plane
            self.config = {"raw": {"size": (W, H), "format": "SRGGB16",
                                   "stride": W * 2}}

        def make_buffer(self, _name):
            return self.plane.view(np.uint8).reshape(-1)

    rng = np.random.default_rng(7)
    # The flash light per ROW follows scene geometry (subject strongly lit,
    # background nearly dark) — the field case that absolute per-row gates
    # fail on.  The scene factor multiplies every pop identically, exactly
    # as real optics do.
    rowsv = np.arange(H, dtype=np.float32)[:, None]
    scene_f = 0.05 + np.exp(-(((rowsv - H * 0.6) / (H * 0.25)) ** 2))
    planes = []
    for i in range(args.frames):
        p = (BLACK + AMB + rng.normal(0, 3, (H, W)) * 16).astype(np.float32)
        if i == FIRST:
            p[SEAM:] += (FLASH * scene_f)[SEAM:]   # rows past the seam
        elif i == FIRST + 1:
            p[:SEAM] += (FLASH * scene_f)[:SEAM]   # the rest, next frame
        elif i == SECOND:
            p[40:] += (FLASH * scene_f)[40:]
        elif i == SECOND + 1:
            p[:40] += (FLASH * scene_f)[:40]
            p += FLASH * scene_f * 0.10  # long tail — must not re-trigger
        elif i == THIRD:
            p[150:] += (FLASH * scene_f)[150:]     # rapid third pop
        elif i == THIRD + 1:
            p[:150] += (FLASH * scene_f)[:150]
        if i == STEP_AT:
            p[130:] += STEP            # lamp turns on mid-readout
        elif i > STEP_AT:
            p += STEP                  # and stays on
        planes.append(p.clip(0, 65535).astype(np.uint16))

    fails = [0]

    def check(label, ok, detail=""):
        print(("  PASS  " if ok else "  FAIL  ") + label
              + ("" if ok else "  " + detail))
        if not ok:
            fails[0] += 1

    # Count every trigger the detector fires, so a baseline that fails to
    # snap after an ambient step shows up as repeat triggers rather than
    # hiding behind the step rejection.
    trig_frames = []
    trig_strength = []
    _row_trig = ns["_flash_row_trigger"]

    def _counting_row_trigger(*a, **kw):
        out = _row_trig(*a, **kw)
        if out[0]:
            trig_frames.append(ns["_flash_seq"])
            trig_strength.append(float(out[4]))
        return out

    ns["_flash_row_trigger"] = _counting_row_trigger

    t0 = clock.monotonic()
    for i, plane in enumerate(planes):
        clock.t = t0 + i * FD_US / 1e6
        if i in args.drop:
            continue               # a frame the preview loop failed to consume
        ns["_flash_ring_push"](_Req(plane), {
            "SensorTimestamp": int(clock.t * 1e9),
            "SensorBlackLevels": [BLACK] * 4})

    print("simulating %d frames at %g fps: flash at %d, back-to-back pops at "
          "%d and %d, ambient +40%% step at %d%s"
          % (len(planes), args.fps, FIRST, SECOND, THIRD, STEP_AT,
             (", dropping %s" % sorted(args.drop)) if args.drop else ""))
    for r in saves:
        print("  [sim] SAVED %s: window %s%s"
              % (r["mode"], r["window"],
                 (" seam %d band %d-%d"
                  % (r["seam"], r["band"][0], r["band"][1]))
                 if r["mode"] == "splice" else
                 " frame seq %d" % r["pick_seq"]))
    for r in rejects:
        print("  [sim] REJECTED seq %s: %s" % (r.get("seq"), r["reason"]))

    # Which ring pushes carry flash light.  A --drop inside a split removes
    # its complementary half; selection must then reject THAT shot (never
    # save a banded frame) while everything intact still resolves.
    pop1 = set(range(FIRST, FIRST + 2))
    pop23 = set(range(SECOND, THIRD + 2))
    b1 = bool(pop1 & set(args.drop))
    b23 = bool(pop23 & set(args.drop))

    check("every detection resolved to a loud verdict (save or reject)",
          len(saves) + len(rejects) >= (0 if (b1 and b23) else 1),
          "saves %d rejects %d" % (len(saves), len(rejects)))
    if not args.drop:
        check("both flashes saved by SELECTION (no summing path exists)",
              len(saves) == 2, str([r["mode"] for r in saves]))
        check("the 50/50 split was spliced at its true seam",
              saves and saves[0]["mode"] == "splice"
              and abs(saves[0]["seam"] - SEAM) <= 24,
              str(saves[0] if saves else None))
        check("the rapid pop pair resolved from the extended candidates",
              len(saves) == 2 and saves[1]["mode"] == "splice"
              and len(saves[1]["window"]) >= 4,
              str(saves[1] if len(saves) > 1 else None))
        # No band survives selection — judged SCENE-INDEPENDENTLY, like
        # the firmware itself: the saved frame's rise over ambient, divided
        # row-by-row by the known per-row flash light, must be ~1.0
        # everywhere the scene received meaningful light.  A band would be
        # a run of rows near 0.
        for n, r in enumerate(saves):
            rows = (r["out"].astype(np.float32)
                    - planes[r["amb_seq"] - 1].astype(np.float32)
                    ).mean(axis=1)
            expect = (FLASH * scene_f[:, 0])
            m_rows = expect > 0.1 * float(expect.max())
            m_rows[:16] = m_rows[-16:] = False
            ratio = rows[m_rows] / expect[m_rows]
            # Save 2's pop carries a modelled 10% afterglow tail that lands
            # in one half of the split — REAL light, honestly kept by a
            # verbatim splice — so its allowance is wider than pop 1's.
            allow = 0.10 if n == 0 else 0.18
            check("save %d: full flash on every lit row (no band, no seam)"
                  % (n + 1),
                  float(ratio.min()) > 1.0 - allow
                  and float(ratio.max()) < 1.0 + allow + 0.12,
                  "ratio %.2f..%.2f" % (ratio.min(), ratio.max()))
    if b1 and not b23:
        check("the broken split was rejected, never saved banded",
              bool(rejects), str(rejects))
        check("a rejection from a REAL pop is loud enough to toast",
              all(r.get("strength", 0.0) >= ns["_FLASH_TOAST_MIN_RISE"]
                  for r in rejects),
              str([(r["reason"], round(r.get("strength", 0), 2))
                   for r in rejects]))
        check("the intact flash still saved after the rejection "
              "(armed state survives a reject)",
              any(r["window"][0] >= SECOND - 1 for r in saves),
              str([r["window"] for r in saves]))
    if args.drop and not (b1 or b23):
        print("  note  dropped frame(s) %s fall outside every flash "
              "window — only the drop counter is exercised"
              % sorted(args.drop))
    check("the sustained ambient step was rejected, not saved",
          all(STEP_AT + 1 not in r["window"] and STEP_AT + 2 not in
              r["window"] for r in saves),
          str([r["window"] for r in saves]))
    # FIRST + SECOND/THIRD are real pops; the ambient step legitimately
    # fires once (the confirm frame is what rejects it).  Anything beyond
    # that is the baseline failing to snap and re-triggering on the new
    # lighting — the repeated-capture field bug.
    check("no repeat triggers after the ambient step (both baselines snap)",
          len(trig_frames) <= 3,
          "triggers at frames %s" % trig_frames)
    # The toast policy, validated against the simulation rather than a
    # model: a REAL pop must read flash-scale, so a genuinely missed flash
    # still tells the photographer; the ambient step — the not-a-flash
    # event — must read below the bar so anything derived from it stays
    # silent.  This is the field complaint ("Flash missed" with no flash
    # in the room) expressed as an assertion.
    bar = ns["_FLASH_TOAST_MIN_RISE"]
    pops = sorted(trig_strength, reverse=True)[:2]
    check("a real pop reads flash-scale (a genuine miss still toasts)",
          len(pops) == 2 and min(pops) >= bar,
          "strengths %s vs bar %.2f" % ([round(v, 2) for v in pops], bar))
    if len(trig_strength) > 2:
        check("a not-a-flash trigger reads below the toast bar (silent)",
              min(trig_strength) < bar,
              "weakest %.2f vs bar %.2f" % (min(trig_strength), bar))
    check("baseline adopted the new ambient level (no repeat triggers)",
          ns["_flash_baseline"] is not None
          and abs(ns["_flash_baseline"] - (BLACK + AMB + STEP))
          < (AMB + STEP) * 0.10,
          "baseline %.0f vs new ambient %.0f"
          % (ns["_flash_baseline"] or 0, BLACK + AMB + STEP))
    check("no frame drops on a clean cadence" if not args.drop
          else "the dropped frame was counted",
          (ns["_flash_dropped"] == 0) if not args.drop
          else (ns["_flash_dropped"] > 0), str(ns["_flash_dropped"]))
    check("ring never exceeds the configured depth",
          len(ns["_flash_ring"]) <= args.depth, str(len(ns["_flash_ring"])))

    # Queue admission: with the selection queue full, a detection is
    # dropped loudly instead of queueing unbounded work.
    before = len(rejects)
    pending_box[0] = 2
    _build_job(ns["_flash_ring"][-2]["seq"])
    pending_box[0] = 0
    check("a full selection queue drops the flash loudly, never blocks",
          len(rejects) == before + 1
          and rejects[-1]["reason"] == "selection queue full",
          str(rejects[-1:]))

    print("\nsimulate: %s" % ("OK" if not fails[0] else "%d FAILED"
                              % fails[0]))
    return 1 if fails[0] else 0


# ---------------------------------------------------------------------------
# `analyze` — classify a saved flash DNG from its pixels, no camera
#
# The three failure modes this mode exists to tell apart all look like "a
# line" in a thumbnail but have completely different causes:
#
#   narrow dip   the sensor's dead-time seam (a few rows).  Depth is
#                dead_time / flash_duration -> raise flash power.
#   large step   one half of the complementary split is missing: the frame
#                above the step got the flash, the frame below did not (or
#                vice versa).  A dropped ring frame or a window that did not
#                span both halves.
#   floor-pinned over-subtraction: the ambient reference carried flash light,
#                so (n-1) copies of it removed real signal.
#
# The seam scan is EXTRACTED FROM wlf8.py by AST (same discipline as
# `simulate`) so it can never drift from what the firmware measures.
# ---------------------------------------------------------------------------

_ANALYZE_FUNCS = ("_flash_row_profile", "_flash_profile_smooth",
                  "_flash_metrics_from_rise")


def _dng_read_raw(path):
    """(uint16 plane, black, white, description) from a DNG.

    Prefers rawpy/LibRaw (handles the LJ92-compressed files the firmware
    writes by default); falls back to a direct IFD walk for uncompressed
    single-strip DNGs, which is the layout `WLV_DNG_COMPRESS=0` produces.
    """
    import numpy as np
    try:
        import rawpy
        with rawpy.imread(path) as raw:
            plane = np.asarray(raw.raw_image_visible, dtype=np.uint16).copy()
            black = float(np.mean(raw.black_level_per_channel))
            white = float(raw.white_level)
            return plane, black, white, _dng_read_description(path)
    except ImportError:
        pass
    except Exception as exc:
        print("  (rawpy could not read this file: %s — trying the raw IFD)"
              % exc)
    return _dng_read_uncompressed(path)


def _dng_read_description(path):
    """ImageDescription (tag 270) as text — carries our `FlashSync …` fields."""
    try:
        import struct
        data = open(path, "rb").read()
        endian = "<" if data[:2] == b"II" else ">"
        off = struct.unpack(endian + "I", data[4:8])[0]
        n = struct.unpack(endian + "H", data[off:off + 2])[0]
        for i in range(n):
            e = off + 2 + i * 12
            tag, typ, cnt = struct.unpack(endian + "HHI", data[e:e + 8])
            if tag != 270:
                continue
            if cnt <= 4:
                return data[e + 8:e + 8 + cnt].decode("ascii", "replace")
            vo = struct.unpack(endian + "I", data[e + 8:e + 12])[0]
            return data[vo:vo + cnt].decode("ascii", "replace").rstrip("\x00")
    except Exception:
        pass
    return ""


def _dng_read_uncompressed(path):
    """Minimal reader for an uncompressed single-strip DNG (the layout the
    firmware writes with WLV_DNG_COMPRESS=0).  Walks IFD0 and its SubIFDs
    for the full-size raw plane."""
    import struct
    import numpy as np
    data = open(path, "rb").read()
    endian = "<" if data[:2] == b"II" else ">"

    def _ifd(off):
        out = {}
        n = struct.unpack(endian + "H", data[off:off + 2])[0]
        for i in range(n):
            e = off + 2 + i * 12
            tag, typ, cnt = struct.unpack(endian + "HHI", data[e:e + 8])
            size = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 12: 8}.get(typ, 1) * cnt
            if size <= 4:
                raw = data[e + 8:e + 8 + size]
            else:
                vo = struct.unpack(endian + "I", data[e + 8:e + 12])[0]
                raw = data[vo:vo + size]
            if typ == 3:
                out[tag] = list(struct.unpack(endian + "%dH" % cnt, raw[:2 * cnt]))
            elif typ == 4:
                out[tag] = list(struct.unpack(endian + "%dI" % cnt, raw[:4 * cnt]))
            elif typ == 5 and cnt >= 1:
                a, b = struct.unpack(endian + "II", raw[:8])
                out[tag] = [a / float(b or 1)]
            else:
                out[tag] = raw
        return out

    ifds = [_ifd(struct.unpack(endian + "I", data[4:8])[0])]
    for sub in list(ifds[0].get(330, []) or []):
        try:
            ifds.append(_ifd(int(sub)))
        except Exception:
            pass
    best = None
    for d in ifds:
        w = (d.get(256) or [0])[0]
        h = (d.get(257) or [0])[0]
        if w and h and (best is None or w * h > best[1] * best[2]):
            best = (d, w, h)
    if best is None:
        raise SystemExit("no image IFD found — is this a DNG?")
    d, w, h = best
    if (d.get(259) or [1])[0] != 1:
        raise SystemExit(
            "this DNG is compressed; install rawpy to analyse it "
            "(pip install rawpy), or re-shoot with WLV_DNG_COMPRESS=0")
    off = int((d.get(273) or [0])[0])
    cnt = int((d.get(279) or [0])[0]) or w * h * 2
    plane = np.frombuffer(data[off:off + cnt], dtype=np.uint16)[:w * h]
    black = float((d.get(50714) or [0])[0])
    white = float((d.get(50717) or [65535])[0])
    return plane.reshape(h, w).copy(), black, white, _dng_read_description(path)


def cmd_analyze(args):
    import numpy as np
    ns = _extract_firmware(args.source, _ANALYZE_FUNCS, _SELECT_CONSTS)
    for path in args.files:
        print("=" * 72)
        print(path)
        print("=" * 72)
        plane, black, white, desc = _dng_read_raw(path)
        h, w = plane.shape[:2]
        print("size        : %dx%d   black %.0f   white %.0f" % (w, h, black, white))
        if desc:
            print("description : %s" % desc.strip())

        sig = plane.astype(np.float32) - black
        clipped = float(np.count_nonzero(plane >= white * 0.999)) / plane.size
        floored = float(np.count_nonzero(sig <= 0.5)) / plane.size
        print("levels      : mean %.0f   p1 %.0f   p99 %.0f   clipped %.2f%%"
              "   at-floor %.2f%%"
              % (sig.mean(), np.percentile(sig, 1), np.percentile(sig, 99),
                 100 * clipped, 100 * floored))

        # Row profile on a CFA-phase-stable column subsample (stride 4).
        prof = sig[:, ::4].mean(axis=1)
        edge = max(8, h // 100)
        core = prof[edge:h - edge]
        print("row profile : min %.0f  max %.0f  spread %.1f%% of mean"
              % (core.min(), core.max(),
                 100.0 * (core.max() - core.min()) / max(1.0, core.mean())))

        verdicts = []
        # The firmware's own profile metrics, run on the saved plane (there
        # is no ambient reference inside a file, so the rise is judged
        # absolute — lit_frac/uniformity read against the frame's own lit
        # level, which is exactly what matters for "is there a band").
        raw8 = np.ascontiguousarray(
            plane.astype(np.uint16)).view(np.uint8).reshape(-1)
        rise = ns["_flash_profile_smooth"](
            ns["_flash_row_profile"](raw8, w, h, w * 2)
            .astype(np.float32) - black)
        m = ns["_flash_metrics_from_rise"](rise, 16)
        if m is not None:
            print("selection metrics: lit %.0f%%  p05 %.0f  med %.0f  "
                  "unif %.2f  step %.0f%%  dip %.0f%% @ row %d"
                  % (100 * m["lit_frac"], m["rise_p05"], m["rise_med"],
                     m["uniformity"], 100 * m["max_step"],
                     100 * m["max_dip"], m["dip_row"]))
            if m["max_step"] >= 0.15 or m["lit_frac"] < 0.9:
                verdicts.append(
                    "STEP/HALF-FRAME signature (lit %.0f%%, step %.0f%%): "
                    "one half of the rolling-shutter split.  Selection "
                    "firmware REJECTS this shape — a file carrying it "
                    "predates the selection change, or the gates need "
                    "review against this sample."
                    % (100 * m["lit_frac"], 100 * m["max_step"]))
            elif m["max_dip"] >= 0.10:
                verdicts.append(
                    "narrow DIP of %.0f%% at row %d: a splice's dead-time "
                    "residual (depth = dead time / flash duration — raise "
                    "flash power to shrink it) or, on an older file, the "
                    "reconstruction-era seam."
                    % (100 * m["max_dip"], m["dip_row"]))

        # --- Floor-pinned: the reconstruction-era over-subtraction
        #     signature.  Selection never subtracts, so on current firmware
        #     this can only be genuine shadow.
        if floored > 0.02:
            verdicts.append(
                "%.1f%% of pixels sit AT the black floor. On "
                "reconstruction-era files this is over-subtraction of a "
                "contaminated ambient reference; current selection firmware "
                "never subtracts, so on a new file it is genuine deep "
                "shadow." % (100 * floored))
        if clipped > 0.01:
            verdicts.append(
                "%.1f%% clipped — the flash was too strong for this "
                "ISO/aperture." % (100 * clipped))

        print()
        if verdicts:
            for v in verdicts:
                print("  ! " + v)
        else:
            print("  OK — flat row profile, no band, no seam, no clipping: "
                  "a healthy capture.")
        print()

# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    pt = sub.add_parser("timing", help="measure exposure vs frame duration")
    pt.add_argument("--mode", help="raw mode as WxH (default: smallest 12-bit)")
    pt.add_argument("--fps", type=float, nargs="+",
                    default=[30, 25, 20, 15, 10],
                    help="frame rates to sweep")
    pt.add_argument("--frames", type=int, default=40,
                    help="frames measured per rate")
    pt.add_argument("--gain", type=float, default=1.0)
    pt.add_argument("--json", help="write the measurements to this file")
    pt.set_defaults(func=cmd_timing)

    pm = sub.add_parser("model", help="predicted dead time, no camera needed")
    pm.add_argument("--fps", type=float, default=20.0)
    pm.add_argument("--hmax", type=int,
                    help="recompute every mode at this HMAX (the IMX585's "
                         "comes from a link-frequency table and doubles on a "
                         "2-lane link, so its default here is only the "
                         "720 MHz / 4-lane case)")
    pm.set_defaults(func=cmd_model)

    pf = sub.add_parser(
        "flash", help="fire a flash; report the firmware's selection verdict")
    pf.add_argument("--mode", help="raw mode as WxH (default: smallest 12-bit)")
    pf.add_argument("--fps", type=float, default=20.0)
    pf.add_argument("--frames", type=int, default=40)
    pf.add_argument("--gain", type=float, default=1.0)
    pf.add_argument("--threshold", type=float, default=0.15,
                    help="fractional rise over baseline that counts as a flash")
    pf.add_argument("--save", help="write the row profiles to this .npz")
    pf.add_argument("--source", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "wlf8.py"))
    pf.set_defaults(func=cmd_flash)

    ps = sub.add_parser(
        "simulate",
        help="drive the firmware's detection state machine, no camera needed")
    ps.add_argument("--source", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "wlf8.py"))
    ps.add_argument("--fps", type=float, default=20.0)
    ps.add_argument("--frames", type=int, default=34)
    ps.add_argument("--flash", type=float, default=1500.0,
                    help="flash amplitude in native DN")
    ps.add_argument("--gap", type=int, default=8,
                    help="frames between the two simulated flashes")
    ps.add_argument("--depth", type=int, default=8)
    ps.add_argument("--threshold", type=float, default=0.25)
    ps.add_argument("--drop", type=int, nargs="*", default=[],
                    help="frame indices the preview loop fails to consume")
    ps.set_defaults(func=cmd_simulate)

    pa = sub.add_parser(
        "analyze", help="classify a saved flash DNG from its pixels")
    pa.add_argument("files", nargs="+", help="one or more .dng files")
    pa.add_argument("--source", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "wlf8.py"))
    pa.set_defaults(func=cmd_analyze)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
FLASH_SYNC_DIAG_EOF
chown pi:pi /home/pi/flash_sync_diag.py 2>/dev/null || true
chmod 755 /home/pi/flash_sync_diag.py
log "Installed /home/pi/flash_sync_diag.py (optical flash sync bench tool)"
info "  Run with the firmware stopped: python3 flash_sync_diag.py timing | flash"
info "  No camera needed: python3 flash_sync_diag.py model | simulate"

# --- Download the face-detection models (-> /home/pi/models) ---
# The YuNet .onnx files are fetched at update time instead of riding in the
# release ZIP (or embedded here), which keeps both the ZIP and this script
# small.  Every file is pinned by SHA-256 below: a download is verified, never
# trusted, and a bad or partial one is deleted so the detector can only ever
# see a model that matches the bytes we measured.  Two revisions are fetched
# because neither runs on every OpenCV (see models/README.md).
#
# Every URL is pinned to an upstream OpenCV Zoo COMMIT, never a branch: the
# .onnx files are Git LFS objects (so the media host, not raw), and upstream
# main has already dropped 2022mar -- the only revision Bookworm's OpenCV 4.6
# can run.  This project's own repo is deliberately NOT a source: it is not
# publicly readable, so raw.githubusercontent.com answers 404 and a camera
# that relied on it got 2023mar alone and "Face AF unavailable" (field case).
# WLV_MODEL_BASE_URL (a directory URL) is tried before everything else, for a
# local mirror or an offline bench.
#
# Failure is a SKIP, never an error: a camera with no network keeps whatever is
# already in /home/pi/models (a verified file is not re-downloaded), and Face
# Detect reports "Face AF needs a model" until the next update that has a link.
_WLV_ZOO_MEDIA="https://media.githubusercontent.com/media/opencv/opencv_zoo"
_WLV_ZOO_RAW="https://raw.githubusercontent.com/opencv/opencv_zoo"
_WLV_ZOO_YUNET="models/face_detection_yunet"

# name  sha256  url  (url = pinned upstream location; one line per file)
_wlv_model_manifest() {
    cat <<WLV_MODEL_MANIFEST_EOF
face_detection_yunet_2023mar.onnx 8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4 $_WLV_ZOO_MEDIA/47534e27c9851bb1128ccc0102f1145e27f23f98/$_WLV_ZOO_YUNET/face_detection_yunet_2023mar.onnx
face_detection_yunet_2022mar.onnx 50ef07f702a31741ca46a4c0d947773b64143b9362780237bf0d427d6c79bab7 $_WLV_ZOO_MEDIA/7e062e54cf5410c09b795ff71b4a255e58498c79/$_WLV_ZOO_YUNET/face_detection_yunet_2022mar.onnx
LICENSE c83b8120c50ccbd4c4f96edf53141bdd566ebb8f8e9227e415326aa1b1aba958 $_WLV_ZOO_RAW/47534e27c9851bb1128ccc0102f1145e27f23f98/$_WLV_ZOO_YUNET/LICENSE
WLV_MODEL_MANIFEST_EOF
}

# Candidate URLs for $1 (name), $2 (pinned upstream url), in order.
_wlv_model_urls() {
    [ -n "${WLV_MODEL_BASE_URL:-}" ] && echo "${WLV_MODEL_BASE_URL%/}/$1"
    echo "$2"
}

_wlv_sha256_of() { sha256sum < "$1" 2>/dev/null | cut -d" " -f1; }

# Fetch $1 (name) with checksum $2 from $3 (pinned url) into /home/pi/models.  Returns 0 when a
# verified copy is in place (already there or just downloaded).
_wlv_model_fetch() {
    local _name="$1" _sha="$2" _src="$3" _dest="/home/pi/models/$1" _tmp _url
    if [ -f "$_dest" ] && [ "$(_wlv_sha256_of "$_dest")" = "$_sha" ]; then
        info "  $_name already present (verified)"
        return 0
    fi
    _tmp="$(mktemp /home/pi/models/.dl.XXXXXX 2>/dev/null)" || return 1
    while read -r _url; do
        [ -n "$_url" ] || continue
        if curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 -o "$_tmp" "$_url" 2>/dev/null \
           && [ "$(_wlv_sha256_of "$_tmp")" = "$_sha" ]; then
            chmod 0644 "$_tmp"
            mv -f "$_tmp" "$_dest" || { rm -f "$_tmp"; return 1; }
            info "  $_name downloaded ($(du -h "$_dest" | cut -f1))"
            return 0
        fi
    done <<< "$(_wlv_model_urls "$_name" "$_src")"
    rm -f "$_tmp"
    return 1
}

if ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
    warn "curl/sha256sum missing -- cannot download the face-detection models"
else
    mkdir -p /home/pi/models
    _model_count=0
    _model_fail=0
    while read -r _name _sha _src; do
        [ -n "$_name" ] || continue
        if _wlv_model_fetch "$_name" "$_sha" "$_src"; then
            case "$_name" in *.onnx) _model_count=$((_model_count + 1)) ;; esac
        else
            warn "Could not download $_name (no mirror reachable, or checksum mismatch)"
            _model_fail=$((_model_fail + 1))
        fi
    done <<< "$(_wlv_model_manifest)"
    chown -R pi:pi /home/pi/models 2>/dev/null || true
    if [ "$_model_count" -gt 0 ]; then
        log "Face-detection models ready in /home/pi/models ($_model_count)"
        info "  Face Detect focus mode reads face_detection_yunet*.onnx from here"
    else
        warn "No face-detection model available -- Face Detect will report"
        info "  \"Face AF needs a model\" until an update runs with network access"
    fi
    unset _model_count _model_fail _name _sha _src
fi

# --- Install the calibrated IMX294 AWB tuning ---
# The stock imx294.json shipped by the custom libcamera fork carries a
# synthetic AWB ct_curve inherited from another sensor: measured on a
# production raw, the true grey point sat ~0.19 off that curve in (r,b)
# space while transverse headroom allowed 0.01, so auto WB settled green
# under every real light source (verified under both LED and tungsten
# studio light).  This copy rescales the curve onto the measured grey
# point (r x0.769, b x0.798 -- exact for the measured source,
# proportional elsewhere; kelvin labels become nominal until a
# multi-source `dng_calibrate.py awb` calibration re-anchors them) and
# opens transverse_pos/neg to 0.04 for off-locus green/magenta sources.
# The heredoc is a byte-for-byte copy of tunings/imx294.json at the
# source repo root -- keep the two in sync when editing either.  The repo
# copy is the SOURCE OF TRUTH: hand-edits made on the camera are
# overwritten by the next OTA, so fold calibration improvements back into
# the repo.  Only cameras already carrying the fork's imx294.json are
# touched (a camera without IMX294 support has nothing to override); the
# pre-override original is kept once as imx294.json.orig.
WLV_IMX294_TUNING_TMP="$(mktemp)"
cat > "$WLV_IMX294_TUNING_TMP" <<'WLV_IMX294_TUNING_EOF'
{
    "version": 2.0,
    "target": "pisp",
    "algorithms": [
        {
            "rpi.black_level": {
                "black_level": 3200
            }
        },
        {
            "rpi.awb": {
                "priors": [
                    {
                        "lux": 0,
                        "prior": [
                            2000,
                            1.0,
                            3000,
                            0.0,
                            13000,
                            0.0
                        ]
                    },
                    {
                        "lux": 800,
                        "prior": [
                            2000,
                            0.0,
                            6000,
                            2.0,
                            13000,
                            2.0
                        ]
                    },
                    {
                        "lux": 1500,
                        "prior": [
                            2000,
                            0.0,
                            4000,
                            1.0,
                            6000,
                            6.0,
                            6500,
                            7.0,
                            7000,
                            1.0,
                            13000,
                            1.0
                        ]
                    }
                ],
                "modes": {
                    "auto": {
                        "lo": 2500,
                        "hi": 7700
                    },
                    "incandescent": {
                        "lo": 2500,
                        "hi": 3000
                    },
                    "tungsten": {
                        "lo": 3000,
                        "hi": 3500
                    },
                    "fluorescent": {
                        "lo": 4000,
                        "hi": 4700
                    },
                    "indoor": {
                        "lo": 3000,
                        "hi": 5000
                    },
                    "daylight": {
                        "lo": 5500,
                        "hi": 6500
                    },
                    "cloudy": {
                        "lo": 7000,
                        "hi": 8000
                    }
                },
                "bayes": 1,
                "ct_curve": [
                    2200.0,
                    1.0478,
                    0.206,
                    3000.0,
                    0.9469,
                    0.2555,
                    4000.0,
                    0.8209,
                    0.3174,
                    5000.0,
                    0.6948,
                    0.3792,
                    5500.0,
                    0.6318,
                    0.4102,
                    6000.0,
                    0.6052,
                    0.4237,
                    6500.0,
                    0.5787,
                    0.4371,
                    7000.0,
                    0.5521,
                    0.4506,
                    7500.0,
                    0.5255,
                    0.4641,
                    8000.0,
                    0.499,
                    0.4775,
                    9000.0,
                    0.4458,
                    0.5045,
                    10000.0,
                    0.3927,
                    0.5314
                ],
                "sensitivity_r": 1.0,
                "sensitivity_b": 1.0,
                "transverse_pos": 0.04,
                "transverse_neg": 0.04
            }
        },
        {
            "rpi.agc": {
                "startup_frames": 0,
                "metering_modes": {
                    "centre-weighted": {
                        "weights": [
                            0,
                            0,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            0,
                            0,
                            0,
                            1,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            1,
                            0,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            2,
                            2,
                            3,
                            3,
                            3,
                            2,
                            2,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            2,
                            3,
                            3,
                            3,
                            3,
                            3,
                            2,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            3,
                            3,
                            3,
                            4,
                            3,
                            3,
                            3,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            3,
                            3,
                            4,
                            4,
                            4,
                            3,
                            3,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            3,
                            3,
                            3,
                            4,
                            3,
                            3,
                            3,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            2,
                            3,
                            3,
                            3,
                            3,
                            3,
                            2,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            2,
                            2,
                            3,
                            3,
                            3,
                            2,
                            2,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            0,
                            1,
                            1,
                            1,
                            1,
                            1,
                            2,
                            2,
                            2,
                            1,
                            1,
                            1,
                            1,
                            1,
                            0,
                            0,
                            0,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            1,
                            0,
                            0
                        ]
                    }
                },
                "exposure_modes": {
                    "normal": {
                        "shutter": [
                            100,
                            15000,
                            30000,
                            60000,
                            120000,
                            120000,
                            120000,
                            120000
                        ],
                        "gain": [
                            1.0,
                            2.0,
                            3.0,
                            4.0,
                            6.0,
                            8.0,
                            12.0,
                            16.0
                        ]
                    }
                },
                "constraint_modes": {
                    "normal": [
                        {
                            "bound": "LOWER",
                            "q_lo": 0.98,
                            "q_hi": 1.0,
                            "y_target": [
                                0,
                                0.4,
                                1000,
                                0.4
                            ]
                        }
                    ],
                    "highlight": [
                        {
                            "bound": "LOWER",
                            "q_lo": 0.98,
                            "q_hi": 1.0,
                            "y_target": [
                                0,
                                0.4,
                                1000,
                                0.4
                            ]
                        },
                        {
                            "bound": "UPPER",
                            "q_lo": 0.99,
                            "q_hi": 1.0,
                            "y_target": [
                                0,
                                0.4,
                                1000,
                                0.4
                            ]
                        }
                    ]
                },
                "y_target": [
                    0,
                    0.16,
                    1000,
                    0.165,
                    10000,
                    0.17
                ]
            }
        },
        {
            "rpi.ccm": {
                "ccms": [
                    {
                        "ct": 2200,
                        "ccm": [
                            1.83906,
                            -0.48807,
                            -0.35099,
                            -0.69511,
                            2.00405,
                            -0.30894,
                            0.32739,
                            -1.57065,
                            2.24325
                        ]
                    },
                    {
                        "ct": 5230,
                        "ccm": [
                            1.74794,
                            -0.61535,
                            -0.13259,
                            -0.33945,
                            1.71105,
                            -0.37159,
                            0.06123,
                            -0.65968,
                            1.59845
                        ]
                    },
                    {
                        "ct": 7550,
                        "ccm": [
                            1.79298,
                            -0.65088,
                            -0.14211,
                            -0.25109,
                            1.65446,
                            -0.40336,
                            -0.00276,
                            -0.45674,
                            1.45951
                        ]
                    },
                    {
                        "ct": 8800,
                        "ccm": [
                            1.82754,
                            -0.68286,
                            -0.14469,
                            -0.23569,
                            1.64738,
                            -0.41168,
                            -0.01803,
                            -0.41033,
                            1.42837
                        ]
                    },
                    {
                        "ct": 10000,
                        "ccm": [
                            1.84445,
                            -0.68089,
                            -0.16356,
                            -0.20829,
                            1.64542,
                            -0.43712,
                            -0.01028,
                            -0.43733,
                            1.44761
                        ]
                    }
                ]
            }
        },
        {
            "rpi.contrast": {
                "ce_enable": 0,
                "gamma_curve": [
                    0,
                    0,
                    1024,
                    5040,
                    2048,
                    9338,
                    3072,
                    12356,
                    4096,
                    15312,
                    5120,
                    18051,
                    6144,
                    20790,
                    7168,
                    23193,
                    8192,
                    25744,
                    9216,
                    27942,
                    10240,
                    30035,
                    11264,
                    32005,
                    12288,
                    33975,
                    13312,
                    35815,
                    14336,
                    37600,
                    15360,
                    39168,
                    16384,
                    40642,
                    18432,
                    43379,
                    20480,
                    45749,
                    22528,
                    47753,
                    24576,
                    49621,
                    26624,
                    51253,
                    28672,
                    52698,
                    30720,
                    53796,
                    32768,
                    54876,
                    36864,
                    57012,
                    40960,
                    58656,
                    45056,
                    59954,
                    49152,
                    61183,
                    53248,
                    62355,
                    57344,
                    63419,
                    61440,
                    64476,
                    65535,
                    65535
                ]
            }
        },
        {
            "rpi.lux": {
                "reference_shutter_speed": 5288,
                "reference_gain": 1.0,
                "reference_aperture": 1.0,
                "reference_lux": 923,
                "reference_Y": 7930
            }
        },
        {
            "rpi.noise": {
                "reference_constant": 0,
                "reference_slope": 2.286
            }
        },
        {
            "rpi.geq": {
                "offset": 187,
                "slope": 0.00518
            }
        },
        {
            "rpi.dpc": {
                "strength": 1
            }
        }
    ]
}
WLV_IMX294_TUNING_EOF
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$WLV_IMX294_TUNING_TMP" 2>/dev/null; then
  WLV_IMX294_TUNING_FOUND=0
  for dest in /usr/local/share/libcamera/ipa/rpi/pisp/imx294.json \
              /usr/local/share/libcamera/ipa/rpi/vc4/imx294.json; do
    [ -f "$dest" ] || continue
    WLV_IMX294_TUNING_FOUND=1
    if cmp -s "$WLV_IMX294_TUNING_TMP" "$dest"; then
      info "  Calibrated IMX294 AWB tuning already current: $dest"
      continue
    fi
    [ -f "$dest.orig" ] || cp -p "$dest" "$dest.orig" 2>/dev/null || true
    if cp "$WLV_IMX294_TUNING_TMP" "$dest" 2>/dev/null; then
      log "Installed calibrated IMX294 AWB tuning: $dest"
      info "  Pre-override original kept at $dest.orig"
    else
      warn "Could not write $dest -- IMX294 AWB tuning left as-is"
    fi
  done
  [ "$WLV_IMX294_TUNING_FOUND" = "1" ] ||
    info "  No fork-installed imx294.json found -- IMX294 tuning not applicable here"
else
  warn "Embedded IMX294 tuning failed JSON validation -- not installed"
fi
rm -f "$WLV_IMX294_TUNING_TMP"

# --- Reduce libcamera startup logging overhead ---
# libcamera's default logging does filesystem and string formatting work
# during camera enumeration. Setting log level to ERROR suppresses
# info/warning output that the camera app doesn't need.

LIBCAMERA_ENV="/etc/environment"
if ! grep -q "LIBCAMERA_LOG_LEVELS" "$LIBCAMERA_ENV" 2>/dev/null; then
    echo "" >> "$LIBCAMERA_ENV"
    echo "# Reduce libcamera logging overhead during camera init" >> "$LIBCAMERA_ENV"
    echo 'LIBCAMERA_LOG_LEVELS="*:ERROR"' >> "$LIBCAMERA_ENV"
    log "Set LIBCAMERA_LOG_LEVELS=*:ERROR in /etc/environment"
    info "  Reduces logging I/O during Picamera2() constructor"
else
    warn "LIBCAMERA_LOG_LEVELS already set"
fi

# --- Reduce kernel log verbosity ---
# dmesg shows repeated "Fixed dependency cycle" messages for the sensor
# and CSI interface. These are harmless but add logging overhead.
# We can't suppress them directly, but reducing kernel log verbosity helps.
if ! grep -q "loglevel=" /boot/firmware/cmdline.txt 2>/dev/null; then
    cp /boot/firmware/cmdline.txt "$BACKUP_DIR/cmdline.txt.bak"
    # Append loglevel=3 (errors only) to reduce early boot logging I/O
    sed -i 's/$/ loglevel=3/' /boot/firmware/cmdline.txt
    log "Set kernel loglevel=3 in cmdline.txt (reduces boot log I/O)"
else
    warn "Kernel loglevel already set"
fi

echo ""
echo "============================================"
echo " PHASE 10: Lock Down Automatic Updates"
echo "============================================"
echo ""

# Rationale: This is a dedicated camera appliance. Silent package updates
# can break libcamera, picamera2, OpenCV, or kernel/DTB compatibility with
# the camera sensors and DSI panel. We disable every auto-update mechanism
# and pin the camera-critical packages so `apt upgrade` won't touch them
# even if run manually.
#
# This goes beyond Phase 2 (which only disabled the timers). Here we also
# MASK the underlying services (so D-Bus/manual triggers can't start them),
# disable unattended-upgrades, kill PackageKit's update checker, and hold
# the packages the camera app depends on.

# --- Mask apt auto-update services (not just timers) ---
# Phase 2 disabled the .timer units. But apt-daily.service and
# apt-daily-upgrade.service can still be activated manually or by other
# triggers. Masking prevents any activation path.

APT_UPDATE_SERVICES=(
    "apt-daily.service"
    "apt-daily.timer"
    "apt-daily-upgrade.service"
    "apt-daily-upgrade.timer"
)

for svc in "${APT_UPDATE_SERVICES[@]}"; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
    log "Masked $svc"
done

# --- Disable unattended-upgrades if installed ---
if dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
    systemctl stop unattended-upgrades.service 2>/dev/null || true
    systemctl disable unattended-upgrades.service 2>/dev/null || true
    systemctl mask unattended-upgrades.service 2>/dev/null || true
    log "Disabled and masked unattended-upgrades.service"
else
    info "unattended-upgrades not installed"
fi

# --- APT periodic config: turn everything off ---
# This is the config file unattended-upgrades and apt-daily read to decide
# whether to run. Setting every knob to "0" makes them no-ops even if the
# services get unmasked later.

APT_NO_AUTO="/etc/apt/apt.conf.d/99-camera-no-auto-update"
if [ ! -f "$APT_NO_AUTO" ]; then
    cat > "$APT_NO_AUTO" <<'EOF'
// Camera appliance: disable all automatic apt operations.
// Prevents silent updates from breaking libcamera / picamera2 / sensor drivers.
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Verbose "0";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    log "Created $APT_NO_AUTO"
else
    warn "$APT_NO_AUTO already exists"
fi

# Also neutralize the shipped 20auto-upgrades if it's present (back it up first)
if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
    cp /etc/apt/apt.conf.d/20auto-upgrades "$BACKUP_DIR/20auto-upgrades.bak"
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
    log "Neutralized /etc/apt/apt.conf.d/20auto-upgrades (backed up)"
fi

# --- Hold camera-critical packages ---
# `apt-mark hold` prevents `apt upgrade` / `apt full-upgrade` from changing
# these packages even when run manually. This is the strongest guarantee
# that the libcamera + picamera2 + OpenCV stack the camera app depends on
# won't silently shift underneath you.

CRITICAL_PACKAGES=(
    libcamera0
    libcamera0.5
    libcamera-apps
    libcamera-tools
    libcamera-ipa
    rpicam-apps
    python3-picamera2
    python3-libcamera
    python3-opencv
    python3-numpy
    python3-pil
    python3-av
    python3-gpiozero
    python3-smbus2
    python3-kms++
    raspberrypi-kernel
    raspberrypi-bootloader
    raspberrypi-sys-mods
    linux-image-rpi-v8
    linux-image-rpi-2712
    firmware-brcm80211
)

# Save currently held packages so undo can restore exactly
apt-mark showhold > "$BACKUP_DIR/apt-holds-before.txt" 2>/dev/null || true

HELD_COUNT=0
for pkg in "${CRITICAL_PACKAGES[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        apt-mark hold "$pkg" >/dev/null 2>&1 && HELD_COUNT=$((HELD_COUNT + 1))
    fi
done
log "Held $HELD_COUNT camera-critical packages (see: apt-mark showhold)"

# --- Disable rpi-eeprom-update auto-check ---
# Phase 1 already disables the service, but re-assert here: the EEPROM
# update service can reflash the bootloader and undo the config we just
# staged in Phase 5b (BOOT_UART=0, PSU_MAX_CURRENT=5000, ...).
systemctl mask rpi-eeprom-update.service 2>/dev/null || true
log "Masked rpi-eeprom-update.service (protects the EEPROM config)"

# --- Kill PackageKit update checker (desktop update notifications) ---
# Already masked in Phase 4, but re-assert. This is what drives the
# "updates available" prompt in the Pi desktop panel.
systemctl mask packagekit.service 2>/dev/null || true
systemctl mask packagekit-offline-update.service 2>/dev/null || true

# --- Disable the pi-greeter / update-notifier prompts if present ---
for unit in update-notifier-download.timer update-notifier-motd.timer; do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
    systemctl mask "$unit" 2>/dev/null || true
done

# --- Neutralize rpi-update (manual firmware bleeding-edge tool) ---
# rpi-update pulls unstable firmware and can brick a working camera build.
# We replace it with a stub that refuses to run.
if [ -x /usr/bin/rpi-update ] && [ ! -f "$BACKUP_DIR/rpi-update.bak" ]; then
    cp /usr/bin/rpi-update "$BACKUP_DIR/rpi-update.bak"
    cat > /usr/bin/rpi-update <<'EOF'
#!/bin/sh
echo "rpi-update disabled by camera optimization script."
echo "Bleeding-edge firmware can break libcamera/sensor drivers. Refusing to run."
echo "To re-enable: sudo cp ~/pi-optimize-backup-*/rpi-update.bak /usr/bin/rpi-update"
exit 1
EOF
    chmod +x /usr/bin/rpi-update
    log "Stubbed /usr/bin/rpi-update (backed up)"
fi

info "Auto-update lockdown complete:"
info "  - apt-daily + unattended-upgrades: masked"
info "  - APT periodic config: all disabled"
info "  - Camera packages: held (apt-mark)"
info "  - rpi-eeprom-update + rpi-update: blocked"
info "  - To manually update later: sudo apt-mark unhold <pkg> && sudo apt update"

echo ""
echo "============================================"
echo " SUMMARY"
echo "============================================"
echo ""
echo "Estimated boot time savings: ~5-8 seconds end-to-end"
echo "  - EEPROM (BOOT_UART=0):     ~3s (firmware phase)"
echo "  - auto_initramfs=0:          ~0.5-1s (firmware phase)"
echo "  - Disabled services:         ~2s (systemd phase, incl. wayvnc timeout window)"
echo "  - Bytecode + page cache:     ~0.5-1s (app startup phase)"
echo "  - Reduced log I/O:           ~0.3-0.5s (kernel + libcamera)"
echo "Estimated RAM savings:         ~250-300 MB"
echo "Estimated power savings:       ~80-120 mA baseline (Bluetooth + audio off),"
echo "                               ~90 mA more whenever Wi-Fi is on (powersave"
echo "                               restored), plus the CPU cap actually applying"
echo "                               (no more 2.4 GHz bursts) and no idle VNC/NM/PHY"
echo "EEPROM config staged:          PSU_MAX_CURRENT=5000, BOOT_ORDER=0xf41,"
echo "                               POWER_OFF_ON_HALT=1, BOOT_UART=0, BOOT_DELAY=0,"
echo "                               NET_INSTALL_ENABLED=0 (~1s: skips the"
echo "                               bootloader's USB enumerate for a keyboard)"
echo ""
echo "Backup saved to: $BACKUP_DIR"
echo ""
echo "To UNDO all changes, run:"
echo "  sudo cp $BACKUP_DIR/config.txt.bak /boot/firmware/config.txt"
echo "  sudo cp $BACKUP_DIR/cmdline.txt.bak /boot/firmware/cmdline.txt  # if present"
echo "  sudo rpi-eeprom-config --apply $BACKUP_DIR/eeprom-config.bak"
echo "  sudo systemctl disable prewarm-camera.service"
echo "  sudo sed -i '/LIBCAMERA_LOG_LEVELS/d' /etc/environment"
echo "  sudo rm /etc/apt/apt.conf.d/99-camera-no-auto-update"
echo "  sudo cp $BACKUP_DIR/20auto-upgrades.bak /etc/apt/apt.conf.d/20auto-upgrades  # if present"
echo "  sudo cp $BACKUP_DIR/rpi-update.bak /usr/bin/rpi-update  # if present"
echo "  sudo systemctl unmask apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer"
echo "  sudo systemctl unmask unattended-upgrades.service packagekit.service rpi-eeprom-update.service"
echo "  sudo systemctl unmask udisks2.service serial-getty@ttyAMA10.service"
echo "  sudo systemctl enable --now NetworkManager.service wpa_supplicant.service"
echo "  sudo systemctl enable ssh.service && sudo systemctl disable ssh.socket"
echo "  sudo systemctl enable wayvnc.service cron.service triggerhappy.service triggerhappy.socket"
echo "  sudo rm /etc/udev/rules.d/60-triggerhappy.rules /etc/NetworkManager/conf.d/wifi-powersave.conf"
echo "  rm /home/pi/.config/labwc/autostart  # or restore $BACKUP_DIR/labwc-autostart.bak"
echo "  # Headless boot (Phase 7c) — back to the desktop path:"
echo "  sudo systemctl set-default graphical.target && sudo systemctl enable lightdm"
echo "  sudo systemctl disable camera.service && sudo rm /etc/systemd/system/camera.service"
echo "  sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user enable camera.service"
echo "  # Release held packages:"
echo "  for p in \$(apt-mark showhold); do sudo apt-mark unhold \$p; done"
echo "  # Restore any patched autostart files from $BACKUP_DIR/"
echo "  # Then re-enable services listed in $BACKUP_DIR/enabled-services.txt"
echo ""

# --- Reboot ------------------------------------------------------------------
# All changes (EEPROM flash, config.txt, cmdline.txt) apply on the next boot.
# Interactive run (SSH terminal): reboot automatically after a short notice.
# Non-interactive run (the camera firmware's OTA update.sh runner, stdin is
# /dev/null): exit cleanly instead — the runner must finish its own cleanup
# (delete this script, sync) before the system goes down, otherwise the
# script would re-run on every boot.
if [ -t 0 ] && [ "${WLV_NO_REBOOT:-0}" != 1 ]; then
    echo -e "${YELLOW}Rebooting in 5 seconds to apply all changes (Ctrl-C to cancel)...${NC}"
    sleep 5
    reboot
else
    echo -e "${YELLOW}IMPORTANT:${NC} reboot required to apply all changes (power-cycle the camera)."
fi
