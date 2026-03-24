# usb-device shell integration for PlatformIO
# Source this from your shell profile:
#   source ~/e/usb-device/shell-integration.sh

# Set up PIO env vars for a device (no locking).
# Usage: piodev "1.10"
piodev() {
    eval $(usb-device env "$1")
    echo "Using: $DEVICE_NAME ($DEVICE_PORT)" >&2
}

# Lock a device and set up the shell for PlatformIO.
# Usage: devlock "1.10"          — lock a specific device
#        devlock --any "MPCB"    — first available match
devlock() {
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
# Usage: devunlock              — unlock all devices held by this shell
#        devunlock "1.10"       — unlock a specific device
devunlock() {
    if [ $# -eq 0 ]; then
        usb-device checkin --mine
    else
        usb-device checkin "$@"
    fi
    unset PIO_LABGRID_DEVICE PLATFORMIO_UPLOAD_PORT DEVICE_NAME DEVICE_PORT
}
