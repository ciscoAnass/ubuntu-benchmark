#!/usr/bin/env bash

# Simple Laptop Health Check for Ubuntu 24.04
# Output: benchmark.log

LOG_FILE="benchmark.log"
TMP_DIR="/tmp/laptop_health_check"
mkdir -p "$TMP_DIR"

# ----------------------------
# Helpers
# ----------------------------
declare -A SUMMARY

set_status() {
    local part="$1"
    local status="$2"
    SUMMARY["$part"]="$status"
}

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

section() {
    log "\n============================================================"
    log "$1"
    log "============================================================"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

install_pkg() {
    local pkg="$1"
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        log "[INFO] Installing missing package: $pkg"
        sudo apt-get update -y >>"$LOG_FILE" 2>&1
        sudo apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
    fi
}

install_required_packages() {
    section "Checking required packages"

    local packages=(
        "pciutils"        # lspci
        "usbutils"        # lsusb
        "mesa-utils"      # glxinfo
        "sysbench"        # simple CPU benchmark
        "smartmontools"   # smartctl
        "lm-sensors"      # sensors
        "alsa-utils"      # aplay / arecord / speaker-test
        "v4l-utils"       # v4l2-ctl
        "iproute2"        # ip
        "net-tools"       # optional network info
        "ethtool"         # network link info
        "bc"              # simple numeric comparisons
        "curl"            # internet test
    )

    for pkg in "${packages[@]}"; do
        install_pkg "$pkg"
    done

    log "[OK] Package check finished."
}

# Start fresh log
: > "$LOG_FILE"
log "Simple Laptop Health Check - $(date)"
log "Host: $(hostname)"
log "User: $(whoami)"

# Check sudo early
section "Sudo check"
if sudo -n true 2>/dev/null; then
    log "[OK] Sudo is available without password prompt."
else
    log "[INFO] Sudo may ask for your password during package install."
fi

install_required_packages

# ----------------------------
# CPU
# ----------------------------
section "CPU"
if need_cmd lscpu; then
    lscpu | tee -a "$LOG_FILE"
    if need_cmd sysbench; then
        log "\n[INFO] Running quick CPU benchmark..."
        sysbench cpu --cpu-max-prime=20000 run | tee -a "$LOG_FILE"
        set_status "CPU" "OK"
    else
        log "[WARNING] sysbench not available."
        set_status "CPU" "WARNING"
    fi
else
    log "[FAIL] lscpu not found."
    set_status "CPU" "FAIL"
fi

# ----------------------------
# GPU
# ----------------------------
section "GPU"
GPU_OK=0
if need_cmd lspci; then
    lspci | grep -Ei 'vga|3d|display' | tee -a "$LOG_FILE"
    if lspci | grep -Ei 'vga|3d|display' >/dev/null 2>&1; then
        GPU_OK=1
    fi
fi

if need_cmd glxinfo; then
    log "\n[INFO] OpenGL renderer:"
    glxinfo -B 2>/dev/null | tee -a "$LOG_FILE"
fi

if [ "$GPU_OK" -eq 1 ]; then
    set_status "GPU" "OK"
else
    log "[FAIL] No GPU/display controller detected."
    set_status "GPU" "FAIL"
fi

# ----------------------------
# RAM
# ----------------------------
section "RAM"
if need_cmd free; then
    free -h | tee -a "$LOG_FILE"

    TOTAL_RAM_GB=$(free -g | awk '/^Mem:/ {print $2}')
    AVAIL_RAM_GB=$(free -g | awk '/^Mem:/ {print $7}')

    if [ -n "$TOTAL_RAM_GB" ] && [ "$TOTAL_RAM_GB" -gt 0 ]; then
        if [ -n "$AVAIL_RAM_GB" ] && [ "$AVAIL_RAM_GB" -ge 1 ]; then
            set_status "RAM" "OK"
        else
            set_status "RAM" "WARNING"
        fi
    else
        set_status "RAM" "FAIL"
    fi
else
    log "[FAIL] free command not found."
    set_status "RAM" "FAIL"
fi

# ----------------------------
# Disk
# ----------------------------
section "Disk"
DISK_STATUS="OK"

lsblk | tee -a "$LOG_FILE"
log ""
df -h / | tee -a "$LOG_FILE"

ROOT_USAGE=$(df / --output=pcent | tail -1 | tr -dc '0-9')
if [ -n "$ROOT_USAGE" ] && [ "$ROOT_USAGE" -ge 90 ]; then
    DISK_STATUS="WARNING"
    log "[WARNING] Root filesystem usage is high: ${ROOT_USAGE}%"
fi

ROOT_DEVICE=$(findmnt -n -o SOURCE /)
BASE_DEVICE=$(basename "$ROOT_DEVICE" | sed 's/[0-9]*$//')

if [ -e "/dev/$BASE_DEVICE" ] && need_cmd smartctl; then
    log "\n[INFO] SMART info for /dev/$BASE_DEVICE"
    sudo smartctl -H "/dev/$BASE_DEVICE" 2>/dev/null | tee -a "$LOG_FILE"
    if sudo smartctl -H "/dev/$BASE_DEVICE" 2>/dev/null | grep -qi "PASSED"; then
        :
    else
        DISK_STATUS="WARNING"
    fi
else
    log "[INFO] SMART check skipped (device not found or unsupported)."
fi

# small write test
TEST_FILE="$TMP_DIR/disk_test.bin"
log "\n[INFO] Running small disk write test..."
if dd if=/dev/zero of="$TEST_FILE" bs=1M count=256 conv=fdatasync status=progress >>"$LOG_FILE" 2>&1; then
    rm -f "$TEST_FILE"
    log "[OK] Disk write test completed."
else
    log "[WARNING] Disk write test failed."
    DISK_STATUS="WARNING"
fi

set_status "Disk" "$DISK_STATUS"

# ----------------------------
# Network
# ----------------------------
section "Network"
NET_STATUS="WARNING"

ip addr | tee -a "$LOG_FILE"
log ""
ip route | tee -a "$LOG_FILE"

if ip route | grep -q default; then
    log "\n[INFO] Testing internet connectivity..."
    if ping -c 2 8.8.8.8 >>"$LOG_FILE" 2>&1 || curl -I https://www.google.com --max-time 10 >>"$LOG_FILE" 2>&1; then
        log "[OK] Network looks fine."
        NET_STATUS="OK"
    else
        log "[WARNING] Network interface exists but internet test failed."
    fi
else
    log "[WARNING] No default route found."
fi

set_status "Network" "$NET_STATUS"

# ----------------------------
# Camera
# ----------------------------
section "Camera"
CAM_STATUS="FAIL"

if need_cmd v4l2-ctl; then
    v4l2-ctl --list-devices 2>/dev/null | tee -a "$LOG_FILE"
    if v4l2-ctl --list-devices 2>/dev/null | grep -qi "video"; then
        CAM_STATUS="OK"
    fi
else
    log "[WARNING] v4l2-ctl not found."
fi

if [ "$CAM_STATUS" = "FAIL" ] && ls /dev/video* >/dev/null 2>&1; then
    ls -l /dev/video* | tee -a "$LOG_FILE"
    CAM_STATUS="OK"
fi

set_status "Camera" "$CAM_STATUS"

# ----------------------------
# USB
# ----------------------------
section "USB detection"
if need_cmd lsusb; then
    lsusb | tee -a "$LOG_FILE"
    USB_COUNT=$(lsusb | wc -l)
    if [ "$USB_COUNT" -ge 1 ]; then
        set_status "USB" "OK"
    else
        set_status "USB" "WARNING"
    fi
else
    log "[FAIL] lsusb not found."
    set_status "USB" "FAIL"
fi

# ----------------------------
# Audio / Jack / Speakers / Mic
# ----------------------------
section "Audio / Jack / Speakers / Microphone"
AUDIO_STATUS="WARNING"
JACK_STATUS="WARNING"
SPEAKER_STATUS="WARNING"
MIC_STATUS="WARNING"

if need_cmd aplay; then
    log "[INFO] Playback devices:"
    aplay -l 2>/dev/null | tee -a "$LOG_FILE"
fi

if need_cmd arecord; then
    log "\n[INFO] Recording devices:"
    arecord -l 2>/dev/null | tee -a "$LOG_FILE"
fi

if need_cmd pactl; then
    log "\n[INFO] Audio cards / ports:"
    pactl list short cards 2>/dev/null | tee -a "$LOG_FILE"
    log ""
    pactl list short sinks 2>/dev/null | tee -a "$LOG_FILE"
    log ""
    pactl list short sources 2>/dev/null | tee -a "$LOG_FILE"

    if pactl list cards 2>/dev/null | grep -Eqi 'analog-output-headphones|headphone|headset'; then
        JACK_STATUS="OK"
    fi
fi

if aplay -l 2>/dev/null | grep -q "card"; then
    AUDIO_STATUS="OK"
fi

# Speaker test: short beep
log "\n[INFO] Running short speaker test..."
if speaker-test -t sine -f 1000 -l 1 >/dev/null 2>&1; then
    log "[OK] Speaker test command ran."
    SPEAKER_STATUS="OK"
else
    log "[WARNING] Speaker test could not run."
fi

# Microphone test: record 3 seconds
MIC_FILE="$TMP_DIR/mic_test.wav"
log "\n[INFO] Running short microphone test (3 seconds)..."
if arecord -d 3 -f cd "$MIC_FILE" >>"$LOG_FILE" 2>&1; then
    if [ -s "$MIC_FILE" ]; then
        log "[OK] Microphone recording file created."
        MIC_STATUS="OK"
    else
        log "[WARNING] Mic test file is empty."
    fi
else
    log "[WARNING] Could not record from microphone."
fi
rm -f "$MIC_FILE"

set_status "Audio" "$AUDIO_STATUS"
set_status "Jack port" "$JACK_STATUS"
set_status "Speakers" "$SPEAKER_STATUS"
set_status "Microphone" "$MIC_STATUS"

# ----------------------------
# Thermal
# ----------------------------
section "Thermal / Temperature"
THERM_STATUS="WARNING"

if need_cmd sensors; then
    sensors 2>/dev/null | tee -a "$LOG_FILE"
    TEMP_FOUND=$(sensors 2>/dev/null | grep -E '(\+?[0-9]+\.[0-9]+°C|\+?[0-9]+°C)' | head -n 1)
    if [ -n "$TEMP_FOUND" ]; then
        THERM_STATUS="OK"
    fi
else
    log "[FAIL] sensors command not found."
    THERM_STATUS="FAIL"
fi

set_status "Thermal" "$THERM_STATUS"

# ----------------------------
# Battery
# ----------------------------
section "Battery"
BAT_STATUS="WARNING"

BAT_PATH=$(find /sys/class/power_supply/ -maxdepth 1 -type d -name 'BAT*' | head -n 1)

if [ -n "$BAT_PATH" ]; then
    log "Battery path: $BAT_PATH"

    [ -f "$BAT_PATH/status" ] && log "Status: $(cat "$BAT_PATH/status")"
    [ -f "$BAT_PATH/capacity" ] && log "Capacity: $(cat "$BAT_PATH/capacity")%"

    # Health estimation
    if [ -f "$BAT_PATH/energy_full" ] && [ -f "$BAT_PATH/energy_full_design" ]; then
        FULL=$(cat "$BAT_PATH/energy_full")
        DESIGN=$(cat "$BAT_PATH/energy_full_design")
    elif [ -f "$BAT_PATH/charge_full" ] && [ -f "$BAT_PATH/charge_full_design" ]; then
        FULL=$(cat "$BAT_PATH/charge_full")
        DESIGN=$(cat "$BAT_PATH/charge_full_design")
    else
        FULL=""
        DESIGN=""
    fi

    if [ -n "$FULL" ] && [ -n "$DESIGN" ] && [ "$DESIGN" -gt 0 ]; then
        HEALTH=$(echo "scale=2; ($FULL / $DESIGN) * 100" | bc)
        log "Estimated battery health: ${HEALTH}%"

        HEALTH_INT=$(printf "%.0f" "$HEALTH")
        if [ "$HEALTH_INT" -ge 80 ]; then
            BAT_STATUS="OK"
        elif [ "$HEALTH_INT" -ge 60 ]; then
            BAT_STATUS="WARNING"
        else
            BAT_STATUS="FAIL"
        fi
    else
        BAT_STATUS="OK"
        log "[INFO] Battery detected, but exact health data is not available."
    fi
else
    log "[WARNING] No battery detected."
    BAT_STATUS="WARNING"
fi

set_status "Battery" "$BAT_STATUS"

# ----------------------------
# Final Summary
# ----------------------------
section "FINAL SUMMARY"

for item in \
    "CPU" \
    "GPU" \
    "RAM" \
    "Disk" \
    "Network" \
    "Camera" \
    "USB" \
    "Jack port" \
    "Audio" \
    "Speakers" \
    "Microphone" \
    "Thermal" \
    "Battery"
do
    log "$(printf '%-15s : %s' "$item" "${SUMMARY[$item]:-UNKNOWN}")"
done

log "\nDone. Full results saved to: $LOG_FILE"
