# usb-device shell integration for PlatformIO
# Source this from your shell profile:
#   source ~/e/usb-device/shell-integration.sh

# Print usage and return 0 (caller should stop) if no args or --help/-h.
_pio_fn_usage() {
    local usage="usage: $1 <device-name>"
    shift
    if [ $# -eq 0 ]; then echo "$usage" >&2; return 0; fi
    for arg in "$@"; do
        case "$arg" in --help|-h) echo "$usage" >&2; return 0 ;; esac
    done
    return 1
}

# Set up PIO env vars for a device (no locking).
# Usage: piodev "1.10"
piodev() {
    _pio_fn_usage piodev "$@" && return
    local output
    output=$(usb-device env "$1") || return $?
    eval "$output"
    echo "Using: $DEVICE_NAME ($DEVICE_PORT)" >&2
}

# Lock a device and set up the shell for PlatformIO.
# Usage: piodevlock "1.10"          — lock a specific device
#        piodevlock --any "MPCB"    — first available match
piodevlock() {
    _pio_fn_usage piodevlock "$@" && return
    local had_default="${DEVICE_NAME:-}"
    local output
    output=$(usb-device checkout --export "$@")
    local rc=$?
    if [ $rc -eq 0 ]; then
        # Always eval to get USB_DEVICE_LOCK_PID etc., but preserve existing default
        local locked_name
        locked_name=$(echo "$output" | grep "DEVICE_NAME=" | head -1 | sed "s/.*DEVICE_NAME='//;s/'.*//")
        eval "$output"
        if [ -n "$had_default" ]; then
            # Restore the previous default
            DEVICE_NAME="$had_default"
        fi
        echo "Locked: $locked_name" >&2
        if [ -z "$had_default" ]; then
            echo "  Default device: $DEVICE_NAME" >&2
        fi
    else
        return $rc
    fi
}

# Unlock devices and unset env vars.
# Usage: piodevunlock              — unlock all devices held by this shell
#        piodevunlock "1.10"       — unlock a specific device
piodevunlock() {
    if [ $# -eq 0 ]; then
        usb-device checkin --mine
    else
        usb-device checkin "$@"
    fi
    unset PIO_LABGRID_DEVICE PLATFORMIO_UPLOAD_PORT DEVICE_NAME DEVICE_PORT USB_DEVICE_LOCK_PID
}

# PIO helpers (pioupload, piotest, piomonitor) are standalone bash scripts
# in this directory, available on PATH.
