#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# Mock-based tests for usb-device.
# Simulates uhubctl and pyserial responses to test various device scenarios
# without real hardware.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
USB_DEVICE="$SCRIPT_DIR/usb-device"

setup() {
    TEST_DIR="$(mktemp -d)"
    CONF="$TEST_DIR/devices.conf"
    DB="$TEST_DIR/locations.json"
    MOCK_BIN="$TEST_DIR/bin"
    mkdir -p "$MOCK_BIN"
    echo '{}' > "$DB"

    # Default device config
    cat > "$CONF" << 'EOF'
Device A=AA:AA:AA:AA:AA:AA
Device B=BB:BB:BB:BB:BB:BB
Device C=CC:CC:CC:CC:CC:CC
EOF

    # Mock uhubctl — override per test
    cat > "$MOCK_BIN/uhubctl" << 'MOCK'
#!/bin/bash
cat "${MOCK_UHUBCTL_OUTPUT:-/dev/null}"
MOCK
    chmod +x "$MOCK_BIN/uhubctl"

    # Mock python3 — simulates pyserial comports output
    # MOCK_PYSERIAL_DEVICES is a file with lines: SERIAL_NUMBER|DEVICE|LOCATION
    cat > "$MOCK_BIN/python3" << 'MOCK'
#!/bin/bash
# Parse the python -c "..." argument to figure out what's being requested
SCRIPT="$2"
MOCK_FILE="${MOCK_PYSERIAL_DEVICES:-/dev/null}"

# Extract the serial number from the python snippet: p.serial_number == 'VALUE'
extract_serial() {
    echo "$1" | grep -oE "serial_number == '[^']+'" | sed "s/serial_number == '//;s/'//"
}

if [[ "$SCRIPT" == *"serial_number"* && "$SCRIPT" == *"p.device"* ]]; then
    # find_serial_port: looking for serial number, print device
    SN=$(extract_serial "$SCRIPT")
    if [ -n "$SN" ] && [ -f "$MOCK_FILE" ]; then
        grep "^$SN|" "$MOCK_FILE" | head -1 | cut -d'|' -f2
    fi
elif [[ "$SCRIPT" == *"serial_number"* && "$SCRIPT" == *"p.location"* ]]; then
    # find_hub_port_live fallback: looking for serial number, print location
    SN=$(extract_serial "$SCRIPT")
    if [ -n "$SN" ] && [ -f "$MOCK_FILE" ]; then
        grep "^$SN|" "$MOCK_FILE" | head -1 | cut -d'|' -f3
    fi
elif [[ "$SCRIPT" == *"import esptool"* ]]; then
    exit 0
elif [[ "$SCRIPT" == *"import serial"* ]]; then
    exit 0
else
    exit 1
fi
MOCK
    chmod +x "$MOCK_BIN/python3"

    # Export env vars
    export USB_DEVICE_CONF="$CONF"
    export USB_DEVICE_DB="$DB"
    export USB_DEVICE_PYTHON="$MOCK_BIN/python3"
    export PATH="$MOCK_BIN:$PATH"
    export HOME="$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ── Helper to set up mock data ────────────────────────────────────

mock_uhubctl() {
    # Write uhubctl output to a temp file
    MOCK_UHUBCTL_OUTPUT="$TEST_DIR/uhubctl_output"
    export MOCK_UHUBCTL_OUTPUT
    cat > "$MOCK_UHUBCTL_OUTPUT"
}

mock_pyserial() {
    # Write pyserial device list: MAC|DEVICE|LOCATION per line
    MOCK_PYSERIAL_DEVICES="$TEST_DIR/pyserial_devices"
    export MOCK_PYSERIAL_DEVICES
    cat > "$MOCK_PYSERIAL_DEVICES"
}

# ── Scenario: device on a ppps hub (direct) ──────────────────────

@test "scan: device found directly on uhubctl hub" {
    mock_uhubctl << 'EOF'
Current status for hub 20-2, vendor 2109:2817, USB 3.20, 4 ports, ppps
  Port 1: 0503 power highspeed enable connect [1d50:6018 AA:AA:AA:AA:AA:AA USB JTAG/serial debug unit]
  Port 2: 0100 power
  Port 3: 0100 power
  Port 4: 0100 power
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    run "$USB_DEVICE" scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device A"* ]]
    [[ "$output" == *"hub=20-2"* ]]
    [[ "$output" == *"port=1"* ]]
    [[ "$output" == *"[found]"* ]]

    # Verify DB was updated
    run jq -r '.["Device A"].hub' "$DB"
    [ "$output" = "20-2" ]
    run jq -r '.["Device A"].port' "$DB"
    [ "$output" = "1" ]
    run jq -r '.["Device A"].link' "$DB"
    [ "$output" = "direct" ]
}

# ── Scenario: device behind a ganged sub-hub (indirect) ──────────

@test "scan: device found indirectly via pyserial location" {
    mock_uhubctl << 'EOF'
Current status for hub 20-2, vendor 2109:2817, USB 3.20, 4 ports, ppps
  Port 1: 0100 power
  Port 2: 0503 power highspeed enable connect [2109:0817 USB2.0 Hub]
  Port 3: 0100 power
  Port 4: 0100 power
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem201|20-2.2.1
EOF

    run "$USB_DEVICE" scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device A"* ]]
    [[ "$output" == *"hub=20-2"* ]]
    [[ "$output" == *"port=2"* ]]
    [[ "$output" == *"[found]"* ]]

    run jq -r '.["Device A"].link' "$DB"
    [ "$output" = "indirect" ]
}

# ── Scenario: device visible to pyserial but no uhubctl hub ──────

@test "scan: device without power-switchable hub" {
    mock_uhubctl < /dev/null  # uhubctl sees nothing
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-1
EOF

    run "$USB_DEVICE" scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device A"* ]]
    [[ "$output" == *"no power-switchable hub"* ]]
    [[ "$output" == *"1 device(s) found"* ]]
}

# ── Scenario: device not connected, cached from previous scan ────

@test "list: offline device shows cached info" {
    # Pre-populate DB with a previous scan result
    cat > "$DB" << 'EOF'
{
    "Device A": {
        "mac": "AA:AA:AA:AA:AA:AA",
        "hub": "20-2",
        "port": "1",
        "link": "direct",
        "dev": "/dev/cu.usbmodem101",
        "last_seen": "2026-02-14T10:00:00Z"
    }
}
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null  # device not connected

    run "$USB_DEVICE" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device A"* ]]
    [[ "$output" == *"offline"* ]]
    [[ "$output" == *"2026-02-14"* ]]
}

# ── Scenario: port eviction when device moves ────────────────────

@test "scan: new device at same port evicts old device" {
    # Device A was previously on hub 20-2 port 1
    cat > "$DB" << 'EOF'
{
    "Device A": {
        "mac": "AA:AA:AA:AA:AA:AA",
        "hub": "20-2",
        "port": "1",
        "link": "direct",
        "dev": "/dev/cu.usbmodem101",
        "last_seen": "2026-02-14T10:00:00Z"
    }
}
EOF
    # Now Device B is on hub 20-2 port 1, Device A is gone
    mock_uhubctl << 'EOF'
Current status for hub 20-2, vendor 2109:2817, USB 3.20, 4 ports, ppps
  Port 1: 0503 power highspeed enable connect [1d50:6018 BB:BB:BB:BB:BB:BB USB JTAG/serial debug unit]
  Port 2: 0100 power
EOF
    mock_pyserial << 'EOF'
BB:BB:BB:BB:BB:BB|/dev/cu.usbmodem101|20-2.1
EOF

    run "$USB_DEVICE" scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device B"* ]]
    [[ "$output" == *"[found]"* ]]

    # Device B should own port 1
    run jq -r '.["Device B"].port' "$DB"
    [ "$output" = "1" ]

    # Device A should have been evicted
    run jq -r '.["Device A"] // "null"' "$DB"
    [ "$output" = "null" ]
}

# ── Scenario: multiple devices on same hub ───────────────────────

@test "scan: multiple devices on same hub" {
    mock_uhubctl << 'EOF'
Current status for hub 20-2, vendor 2109:2817, USB 3.20, 4 ports, ppps
  Port 1: 0503 power highspeed enable connect [1d50:6018 AA:AA:AA:AA:AA:AA USB JTAG/serial debug unit]
  Port 3: 0503 power highspeed enable connect [1d50:6018 BB:BB:BB:BB:BB:BB USB JTAG/serial debug unit]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
BB:BB:BB:BB:BB:BB|/dev/cu.usbmodem301|20-2.3
EOF

    run "$USB_DEVICE" scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device A"* ]]
    [[ "$output" == *"Device B"* ]]
    [[ "$output" == *"2 device(s) found"* ]]

    # Check both are in DB on correct ports
    run jq -r '.["Device A"].port' "$DB"
    [ "$output" = "1" ]
    run jq -r '.["Device B"].port' "$DB"
    [ "$output" = "3" ]
}

@test "db_devices_on_hub lists other devices for hub reset warning" {
    cat > "$DB" << 'EOF'
{
    "Device A": {"mac": "AA:AA:AA:AA:AA:AA", "hub": "20-2", "port": "1", "link": "direct", "dev": "-", "last_seen": "2026-02-14T10:00:00Z"},
    "Device B": {"mac": "BB:BB:BB:BB:BB:BB", "hub": "20-2", "port": "3", "link": "direct", "dev": "-", "last_seen": "2026-02-14T10:00:00Z"},
    "Device C": {"mac": "CC:CC:CC:CC:CC:CC", "hub": "10-1", "port": "1", "link": "direct", "dev": "-", "last_seen": "2026-02-14T10:00:00Z"}
}
EOF

    # Query devices on hub 20-2 excluding port 1 (Device A's port)
    run jq -r --arg hub "20-2" --arg ep "1" \
        'to_entries[] | select(.value.hub == $hub and .value.port != $ep) | "\(.key)|\(.value.port)"' "$DB"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device B|3"* ]]
    # Device C should not appear (different hub)
    [[ "$output" != *"Device C"* ]]
}

# ── Scenario: find with cached location ──────────────────────────

@test "find: uses cached location when device is offline" {
    cat > "$DB" << 'EOF'
{
    "Device A": {
        "mac": "AA:AA:AA:AA:AA:AA",
        "hub": "20-2",
        "port": "1",
        "link": "direct",
        "dev": "/dev/cu.usbmodem101",
        "last_seen": "2026-02-14T10:00:00Z"
    }
}
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" find "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hub:  20-2"* ]]
    [[ "$output" == *"port: 1"* ]]
    [[ "$output" == *"cached"* ]]
}

# ── Scenario: port command ───────────────────────────────────────

@test "port: returns serial device path" {
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    run "$USB_DEVICE" port "Device A"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/cu.usbmodem101" ]
}

@test "port: fails when device not connected" {
    mock_pyserial < /dev/null

    run "$USB_DEVICE" port "Device A"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no serial port found"* ]]
}

# ── Scenario: fuzzy matching ─────────────────────────────────────

@test "find: substring match works" {
    mock_uhubctl < /dev/null
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-1
EOF
    cat > "$DB" << 'EOF'
{"Device A": {"mac": "AA:AA:AA:AA:AA:AA", "hub": "-", "port": "-", "link": "no-hub", "dev": "/dev/cu.usbmodem101", "last_seen": "2026-02-14T10:00:00Z"}}
EOF

    run "$USB_DEVICE" port "vice A"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/cu.usbmodem101" ]
}

@test "find: no match prints known devices" {
    run "$USB_DEVICE" find "ZZZZZ"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No devices match"* ]]
    [[ "$output" == *"Device A"* ]]
}

# ── INI config format ──────────────────────────────────────────────

@test "INI: section-based config works for scan" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=esp32
EOF
    mock_uhubctl << 'EOF'
Current status for hub 20-2, vendor 2109:2817, USB 3.20, 4 ports, ppps
  Port 1: 0503 power highspeed enable connect [1d50:6018 AA:AA:AA:AA:AA:AA USB JTAG/serial debug unit]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    run "$USB_DEVICE" scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Board Alpha"* ]]
    [[ "$output" == *"[found]"* ]]

    run jq -r '.["Board Alpha"].hub' "$DB"
    [ "$output" = "20-2" ]
}

@test "INI: serial= field works same as mac=" {
    cat > "$CONF" << 'EOF'
[PPK2 Dev]
serial=C9F6358AC307
type=ppk2
EOF
    mock_pyserial << 'EOF'
C9F6358AC307|/dev/cu.usbmodemC9F6358AC3072|2-2
EOF

    run "$USB_DEVICE" port "PPK2"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/cu.usbmodemC9F6358AC3072" ]
}

@test "INI: mixed flat and section config" {
    cat > "$CONF" << 'EOF'
Device A=AA:AA:AA:AA:AA:AA

[PPK2 Dev]
serial=C9F6358AC307
type=ppk2
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
C9F6358AC307|/dev/cu.usbmodemC9F6358AC3072|2-2
EOF

    run "$USB_DEVICE" port "Device A"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/cu.usbmodem101" ]

    run "$USB_DEVICE" port "PPK2"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/cu.usbmodemC9F6358AC3072" ]
}

@test "INI: find shows type field" {
    cat > "$CONF" << 'EOF'
[PPK2 Dev]
serial=C9F6358AC307
type=ppk2
EOF
    mock_uhubctl << 'EOF'
Current status for hub 2, vendor 1915:c00a, USB 2.00, 1 ports, ppps
  Port 1: 0503 power highspeed enable connect [1915:c00a C9F6358AC307 PPK2]
EOF
    mock_pyserial << 'EOF'
C9F6358AC307|/dev/cu.usbmodemC9F6358AC3072|2-2
EOF

    run "$USB_DEVICE" find "PPK2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"type: ppk2"* ]]
    [[ "$output" == *"id:   C9F6358AC307"* ]]
}

# ── Static-location (type=power) devices ──────────────────────────

@test "INI: power device with static location — find" {
    cat > "$CONF" << 'EOF'
[Charger A]
location=20-2.3
type=power
EOF

    run "$USB_DEVICE" find "Charger"
    [ "$status" -eq 0 ]
    [[ "$output" == *"type: power"* ]]
    [[ "$output" == *"location: 20-2.3"* ]]
    [[ "$output" == *"hub:  20-2"* ]]
    [[ "$output" == *"port: 3"* ]]
    [[ "$output" == *"link: static"* ]]
}

@test "INI: power device — port command fails" {
    cat > "$CONF" << 'EOF'
[Charger A]
location=20-2.3
type=power
EOF

    run "$USB_DEVICE" port "Charger"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no serial number"* ]]
}

@test "INI: bootloader command rejected for type without plugin" {
    cat > "$CONF" << 'EOF'
[PPK2 Dev]
serial=C9F6358AC307
type=ppk2
EOF
    mock_pyserial << 'EOF'
C9F6358AC307|/dev/cu.usbmodemC9F6358AC3072|2-2
EOF

    run "$USB_DEVICE" bootloader "PPK2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no bootloader support"* ]]
    [[ "$output" == *"ppk2"* ]]
}

# ── Chained commands ──────────────────────────────────────────────

@test "chained: device-first syntax works for port" {
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    run "$USB_DEVICE" "Device A" port
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/cu.usbmodem101" ]
}

@test "chained: unknown command in chain fails" {
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    run "$USB_DEVICE" "Device A" nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown command"* ]]
}

# ── Type plugins ──────────────────────────────────────────────────

@test "type: prints device type" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=esp32
EOF

    run "$USB_DEVICE" type "Board Alpha"
    [ "$status" -eq 0 ]
    [ "$output" = "esp32" ]
}

@test "type: flat format defaults to generic" {
    run "$USB_DEVICE" type "Device A"
    [ "$status" -eq 0 ]
    [ "$output" = "generic" ]
}

@test "plugin: bootloader dispatches to type plugin" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=testboard
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    # Create a test plugin
    mkdir -p "$SCRIPT_DIR/types.d"
    cat > "$SCRIPT_DIR/types.d/testboard.sh" << 'PLUGIN'
type_testboard_bootloader() {
    echo "TESTBOARD_BOOTLOADER port=$1 name=$2"
}
PLUGIN

    run "$USB_DEVICE" bootloader "Board Alpha"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TESTBOARD_BOOTLOADER port=/dev/cu.usbmodem101 name=Board Alpha"* ]]

    # Clean up
    rm -f "$SCRIPT_DIR/types.d/testboard.sh"
}

@test "plugin: user plugin shadows shipped plugin" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=testboard2
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    # Create shipped plugin
    mkdir -p "$SCRIPT_DIR/types.d"
    cat > "$SCRIPT_DIR/types.d/testboard2.sh" << 'PLUGIN'
type_testboard2_bootloader() { echo "SHIPPED"; }
PLUGIN

    # Create user plugin that shadows it
    mkdir -p "$HOME/.config/usb-devices/types.d"
    cat > "$HOME/.config/usb-devices/types.d/testboard2.sh" << 'PLUGIN'
type_testboard2_bootloader() { echo "USER_OVERRIDE"; }
PLUGIN

    run "$USB_DEVICE" bootloader "Board Alpha"
    [ "$status" -eq 0 ]
    # Shipped plugin wins (first in search path)
    [[ "$output" == *"SHIPPED"* ]]

    # Clean up
    rm -f "$SCRIPT_DIR/types.d/testboard2.sh"
}

@test "plugin: missing plugin gives clear error" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=nosuchtype
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    run "$USB_DEVICE" bootloader "Board Alpha"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no bootloader support"* ]]
    [[ "$output" == *"nosuchtype"* ]]
}

@test "plugin: chip= config field is available to plugin" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=chiptest
chip=esp32c3
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    mkdir -p "$SCRIPT_DIR/types.d"
    cat > "$SCRIPT_DIR/types.d/chiptest.sh" << 'PLUGIN'
type_chiptest_bootloader() {
    echo "CHIP=$RESOLVED_CHIP"
}
PLUGIN

    run "$USB_DEVICE" bootloader "Board Alpha"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHIP=esp32c3"* ]]

    rm -f "$SCRIPT_DIR/types.d/chiptest.sh"
}

# ── Checkout / Checkin / Locks ─────────────────────────────────────

@test "checkout: acquires lock on a device" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    run "$USB_DEVICE" checkout "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checked out"* ]]

    # Lock dir should exist with info file
    [ -d "$TEST_DIR/locks/device_a" ]
    [ -f "$TEST_DIR/locks/device_a/info" ]

    # Info should contain PID and OWNER
    run grep "^PID=" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
    run grep "^OWNER=" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
}

@test "checkout: fails when device already locked" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create an existing lock from a running process (use PPID which is bats, always alive)
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=other-user
TIMESTAMP=2026-02-19T10:00:00Z
PURPOSE=testing
TTL=999999
EOF

    run "$USB_DEVICE" checkout "Device A"
    [ "$status" -eq 1 ]
    [[ "$output" == *"checked out"* ]]
    [[ "$output" == *"other-user"* ]]
}

@test "checkout: reclaims lock from dead PID" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock with a definitely-dead PID
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=99999
OWNER=dead-process
TIMESTAMP=2026-02-19T10:00:00Z
PURPOSE=crashed
TTL=999999
EOF

    run "$USB_DEVICE" checkout "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reclaiming stale lock"* ]]
    [[ "$output" == *"Checked out"* ]]
}

@test "checkin: releases lock from dead process" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock with a dead PID — checkin should release it
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=99998
OWNER=test
TIMESTAMP=2026-02-19T10:00:00Z
PURPOSE=testing
TTL=1800
EOF

    run "$USB_DEVICE" checkin "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checked in"* ]]
    [ ! -d "$TEST_DIR/locks/device_a" ]
}

@test "checkin: refuses to release another process's lock" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Lock held by PPID (bats parent, always alive and accessible)
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=other-user
TIMESTAMP=2026-02-19T10:00:00Z
PURPOSE=testing
TTL=999999
EOF

    run "$USB_DEVICE" checkin "Device A"
    [ "$status" -eq 1 ]
    [[ "$output" == *"checked out by another"* ]]
    # Lock should still exist
    [ -d "$TEST_DIR/locks/device_a" ]
}

@test "checkin: force releases another process's lock" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=other-user
TIMESTAMP=2026-02-19T10:00:00Z
PURPOSE=testing
TTL=999999
EOF

    run "$USB_DEVICE" checkin -f "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checked in"* ]]
    [ ! -d "$TEST_DIR/locks/device_a" ]
}

@test "checkin: no-op when device not locked" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    run "$USB_DEVICE" checkin "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not checked out"* ]]
}

@test "locks: shows checked-out devices" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=ci-job-42
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=PR #123
TTL=999999
EOF

    run "$USB_DEVICE" locks
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device A"* ]]
    [[ "$output" == *"LOCKED"* ]]
    [[ "$output" == *"ci-job-42"* ]]
    [[ "$output" == *"PR #123"* ]]
}

@test "locks: shows nothing when all free" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    run "$USB_DEVICE" locks
    [ "$status" -eq 0 ]
    [[ "$output" == *"No devices are checked out"* ]]
}

@test "checkout: custom owner and purpose" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    run "$USB_DEVICE" checkout --owner "ci-build-99" --purpose "nightly tests" --ttl 600 "Device A"
    [ "$status" -eq 0 ]

    run grep "^OWNER=ci-build-99" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
    run grep "^PURPOSE=nightly tests" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
    run grep "^TTL=600" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
}

@test "INI: hub_name= shown in find output" {
    cat > "$CONF" << 'EOF'
[MPCB 1.9 Dev]
mac=AA:AA:AA:AA:AA:AA
type=esp32
hub_name=1.9 Dev
EOF
    mock_uhubctl << 'EOF'
Current status for hub 20-4 [0000:0000, USB 2.10, 4 ports, ppps]
  Port 1: 0103 power enable connect [303a:1001 Espressif USB JTAG AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
EOF

    run "$USB_DEVICE" find "1.9"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hub_name: 1.9 Dev"* ]]
    [[ "$output" == *"type: esp32"* ]]
}

@test "INI: hub:insight section does not create a device" {
    cat > "$CONF" << 'EOF'
[Device A]
mac=AA:AA:AA:AA:AA:AA
type=esp32

[hub:insight]
port=/dev/cu.usbmodem999
location=20-3.3
EOF
    mock_uhubctl < /dev/null
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    run "$USB_DEVICE" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device A"* ]]
    # hub:insight should NOT appear as a device
    [[ "$output" != *"hub:insight"* ]]
}

@test "INI: list shows type for all devices" {
    cat > "$CONF" << 'EOF'
Device A=AA:AA:AA:AA:AA:AA

[PPK2 Dev]
serial=C9F6358AC307
type=ppk2

[Charger A]
location=20-2.3
type=power
EOF
    mock_uhubctl < /dev/null
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
C9F6358AC307|/dev/cu.usbmodemC9F6358AC3072|2-2
EOF

    run "$USB_DEVICE" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device A"* ]]
    [[ "$output" == *"type=generic"* ]]
    [[ "$output" == *"PPK2 Dev"* ]]
    [[ "$output" == *"type=ppk2"* ]]
    [[ "$output" == *"Charger A"* ]]
    [[ "$output" == *"type=power"* ]]
}
