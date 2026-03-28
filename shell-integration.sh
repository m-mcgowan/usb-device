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
    local output
    output=$(usb-device checkout --export "$@")
    local rc=$?
    if [ $rc -eq 0 ]; then
        eval "$output"
        echo "Locked: $DEVICE_NAME" >&2
        echo "  PIO_LABGRID_DEVICE=$PIO_LABGRID_DEVICE" >&2
        echo "  PLATFORMIO_UPLOAD_PORT=$PLATFORMIO_UPLOAD_PORT" >&2
        echo "  DEVICE_PORT=$DEVICE_PORT" >&2
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
