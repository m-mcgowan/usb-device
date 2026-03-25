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
# Usage: piodevlock "1.10"          — lock a specific device
#        piodevlock --any "MPCB"    — first available match
piodevlock() {
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
    unset PIO_LABGRID_DEVICE PLATFORMIO_UPLOAD_PORT DEVICE_NAME DEVICE_PORT
}

# PlatformIO build/test/monitor helpers.
# Last argument is the device name for usb-device port resolution.
# Usage: pioupload -e esp32s3-idf 1.10
#        piotest -e esp32s3-idf -v 1.10
#        piomonitor 1.10
pioupload() {
    if [ $# -lt 1 ]; then
        echo "Usage: pioupload [pio-args...] <device-name>" >&2; return 1
    fi
    local dev="${!#}"
    local bl_port; bl_port=$(usb-device port --bootloader "$dev") || return 1
    local args=("${@:1:$#-1}")
    pio run -t upload --upload-port "$bl_port" "${args[@]}"
}

piotest() {
    if [ $# -lt 1 ]; then
        echo "Usage: piotest [pio-args...] <device-name>" >&2; return 1
    fi
    local dev="${!#}"
    local bl_port; bl_port=$(usb-device port --bootloader "$dev") || return 1
    local port; port=$(usb-device port "$dev") || return 1
    local args=("${@:1:$#-1}")
    pio test --upload-port "$bl_port" --test-port "$port" "${args[@]}"
}

piomonitor() {
    if [ $# -lt 1 ]; then
        echo "Usage: piomonitor [args...] <device-name>" >&2; return 1
    fi
    local dev="${!#}"
    local port; port=$(usb-device port "$dev") || return 1
    local args=("${@:1:$#-1}")
    serial-monitor "$port" "${args[@]}"
}
