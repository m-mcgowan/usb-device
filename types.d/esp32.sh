# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# ESP32 type plugin for usb-device
#
# Provides bootloader entry/exit via esptool.
# Config fields:
#   type=esp32
#   chip=esp32s3    (optional, defaults to esp32s3)

# List commands this type adds beyond the generic set.
type_esp32_commands() {
    echo "bootloader boot"
}

# Validate ESP32-specific dependencies.
# Prints [ok]/[FAIL] lines. Returns number of failures.
type_esp32_check() {
    local fail=0
    local esptool
    if esptool=$(_esp32_find_esptool 2>/dev/null); then
        local ver
        ver=$($esptool version 2>&1 | head -1)
        echo "[ok] esptool ($ver)"
    else
        echo "[FAIL] esptool not found — install PlatformIO or pip install esptool"
        fail=$((fail + 1))
    fi
    return $fail
}

# Enter ROM bootloader via esptool.
# Args: $1=serial_port $2=device_name
# Globals: RESOLVED_CHIP (optional, defaults to esp32s3)
type_esp32_bootloader() {
    local serial_port="$1" name="$2"
    local chip="${RESOLVED_CHIP:-esp32s3}"
    local esptool
    esptool=$(_esp32_find_esptool) || die "esptool not found (install PlatformIO or esptool)"
    echo "Entering ROM bootloader on '$name' ($serial_port)..."
    $esptool --chip "$chip" --port "$serial_port" --before usb-reset --after no-reset read-mac
}

# Exit bootloader, boot app via watchdog reset.
# Args: $1=serial_port $2=device_name
type_esp32_boot() {
    local serial_port="$1" name="$2"
    local chip="${RESOLVED_CHIP:-esp32s3}"
    local esptool
    esptool=$(_esp32_find_esptool) || die "esptool not found (install PlatformIO or esptool)"
    echo "Exiting bootloader on '$name' ($serial_port)..."
    $esptool --chip "$chip" --port "$serial_port" --after hard-reset read-mac
}

# ── Internal helpers ──────────────────────────────────────────────

_esp32_find_esptool() {
    local pio_python="${HOME}/.platformio/penv/bin/python3"
    if [ -x "$pio_python" ] && "$pio_python" -c "import esptool" &>/dev/null; then
        echo "$pio_python -m esptool"
        return 0
    fi
    if command -v esptool.py &>/dev/null; then
        echo "esptool.py"
        return 0
    fi
    return 1
}
