#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# Tests for usb-device and serial-monitor scripts.
# Run: bats scripts/usb-devices/test/

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
USB_DEVICE="$SCRIPT_DIR/usb-device"
SERIAL_MONITOR="$SCRIPT_DIR/serial-monitor"

# ── usb-device basics ────────────────────────────────────────────

@test "usb-device prints usage when called with no args" {
    run "$USB_DEVICE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: usb-device"* ]]
}

@test "usb-device usage lists all commands" {
    run "$USB_DEVICE"
    [[ "$output" == *"list"* ]]
    [[ "$output" == *"scan"* ]]
    [[ "$output" == *"check"* ]]
    [[ "$output" == *"find"* ]]
    [[ "$output" == *"reset"* ]]
    [[ "$output" == *"off"* ]]
    [[ "$output" == *"on"* ]]
    [[ "$output" == *"port"* ]]
    [[ "$output" == *"bootloader"* ]]
    [[ "$output" == *"boot"* ]]
}

@test "usb-device check passes on this machine" {
    run "$USB_DEVICE" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"All"* ]]
    [[ "$output" == *"passed"* ]]
}

@test "usb-device subcommands print usage when missing device arg" {
    for cmd in find reset off on port bootloader boot; do
        run "$USB_DEVICE" "$cmd"
        [ "$status" -eq 1 ]
        [[ "$output" == *"usage:"* ]] || [[ "$output" == *"error:"* ]]
    done
}

# ── Python / pyserial availability ───────────────────────────────

@test "PlatformIO venv python exists and has pyserial" {
    # Only tests the PIO venv path — skipped in CI where pip install is used instead
    PIO_PYTHON="$HOME/.platformio/penv/bin/python3"
    [ -x "$PIO_PYTHON" ] || skip "PlatformIO venv not present"
    run "$PIO_PYTHON" -c "from serial.tools.list_ports import comports; comports()"
    [ "$status" -eq 0 ]
}

@test "usb-device resolves PYTHON to a working interpreter with pyserial" {
    # Source just the PYTHON resolution from the script
    if [ -x "$HOME/.platformio/penv/bin/python3" ]; then
        PYTHON="$HOME/.platformio/penv/bin/python3"
    else
        PYTHON="python3"
    fi
    run "$PYTHON" -c "from serial.tools.list_ports import comports; print('ok')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
}

# ── Dependencies ─────────────────────────────────────────────────

@test "jq is available" {
    run command -v jq
    [ "$status" -eq 0 ]
}

@test "uhubctl is available" {
    run command -v uhubctl
    [ "$status" -eq 0 ]
}

# ── usb-device list/scan with real config ────────────────────────

@test "usb-device list runs without error" {
    run "$USB_DEVICE" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Registered devices:"* ]]
}

@test "usb-device scan runs without error" {
    run "$USB_DEVICE" scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Scan complete:"* ]]
}

# ── usb-device list/scan with empty config ───────────────────────

@test "usb-device list works with empty config" {
    tmpconf="$(mktemp)"
    echo "# empty" > "$tmpconf"
    run env USB_DEVICE_CONF="$tmpconf" "$USB_DEVICE" list
    rm -f "$tmpconf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Registered devices:"* ]]
}

@test "usb-device scan works with empty config" {
    tmpconf="$(mktemp)"
    tmpdb="$(mktemp)"
    echo "# empty" > "$tmpconf"
    echo '{}' > "$tmpdb"
    run env USB_DEVICE_CONF="$tmpconf" USB_DEVICE_DB="$tmpdb" "$USB_DEVICE" scan
    rm -f "$tmpconf" "$tmpdb"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Scan complete: 0 device(s)"* ]]
}

# ── usb-device with dummy device ─────────────────────────────────

@test "usb-device find reports not found for nonexistent device" {
    run "$USB_DEVICE" find "NONEXISTENT_DEVICE_12345"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No devices match"* ]]
}

@test "usb-device port reports not found for nonexistent device" {
    run "$USB_DEVICE" port "NONEXISTENT_DEVICE_12345"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No devices match"* ]]
}

# ── DB operations ────────────────────────────────────────────────

@test "locations.json is valid JSON after scan" {
    tmpconf="$(mktemp)"
    tmpdb="$(mktemp)"
    echo "TestDevice=AA:BB:CC:DD:EE:FF" > "$tmpconf"
    echo '{}' > "$tmpdb"
    run env USB_DEVICE_CONF="$tmpconf" USB_DEVICE_DB="$tmpdb" "$USB_DEVICE" scan
    [ "$status" -eq 0 ]
    run jq '.' "$tmpdb"
    [ "$status" -eq 0 ]
    rm -f "$tmpconf" "$tmpdb"
}

# ── serial-monitor basics ───────────────────────────────────────

@test "serial-monitor prints help" {
    run "$SERIAL_MONITOR" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Serial monitor"* ]]
    [[ "$output" == *"--timeout"* ]]
    [[ "$output" == *"--send"* ]]
    [[ "$output" == *"--boot"* ]]
}

@test "serial-monitor lists ports when called with no device" {
    run "$SERIAL_MONITOR"
    [ "$status" -eq 0 ]
    # Should list ports or say none found (both are valid)
    [[ "$output" == *"serial port"* ]] || [[ "$output" == *"No serial"* ]]
}

@test "serial-monitor fails gracefully for nonexistent device" {
    run "$SERIAL_MONITOR" "NONEXISTENT_DEVICE_12345" --timeout 1
    [ "$status" -ne 0 ]
}

# ── Version ──────────────────────────────────────────────────────

@test "usb-device version prints a version string" {
    run "$USB_DEVICE" version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^usb-device\ [0-9]+\.[0-9]+\.[0-9] ]]
}
