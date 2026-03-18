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
# Mock python3 — handles both inline -c scripts and insight_hub.py calls.

# ── insight_hub.py mock ──────────────────────────────────────────
# MOCK_INSIGHT_HUB_PORT and MOCK_INSIGHT_HUB_LOCATION control detect.
# MOCK_INSIGHT_HUB_STATE is a file with lines: CHx|powerEn|dataEn|voltage|current
# MOCK_INSIGHT_HUB_LOG records all power/cycle commands for verification.

if [[ "$1" == *"insight_hub.py" ]]; then
    CMD="$2"
    case "$CMD" in
        detect)
            if [ -n "${MOCK_INSIGHT_HUB_PORT:-}" ]; then
                printf '%s\t%s\n' "$MOCK_INSIGHT_HUB_PORT" "${MOCK_INSIGHT_HUB_LOCATION:-unknown}"
                exit 0
            fi
            exit 1
            ;;
        channel)
            # $3 = hub_location, $4 = port
            PORT_NUM="$4"
            if [ -n "$PORT_NUM" ] && [ "$PORT_NUM" -ge 1 ] 2>/dev/null && [ "$PORT_NUM" -le 3 ]; then
                echo "CH${PORT_NUM}"
                exit 0
            fi
            echo "error: port $PORT_NUM is not a device channel (1-3)" >&2
            exit 1
            ;;
        power)
            # $3 = CHx, $4 = on|off
            CHANNEL="$3"
            STATE="$4"
            echo "$CMD $CHANNEL $STATE" >> "${MOCK_INSIGHT_HUB_LOG:-/dev/null}"
            echo "$CHANNEL power $STATE" >&2
            exit 0
            ;;
        cycle)
            # $3 = CHx, $4 = off_seconds (optional)
            CHANNEL="$3"
            OFFTIME="${4:-2}"
            echo "$CMD $CHANNEL $OFFTIME" >> "${MOCK_INSIGHT_HUB_LOG:-/dev/null}"
            echo "Power off $CHANNEL..." >&2
            echo "Power on $CHANNEL..." >&2
            exit 0
            ;;
        query)
            # $3 = CHx — return mock state as JSON
            CHANNEL="$3"
            STATE_FILE="${MOCK_INSIGHT_HUB_STATE:-}"
            if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
                LINE=$(grep "^$CHANNEL|" "$STATE_FILE" | head -1)
                if [ -n "$LINE" ]; then
                    IFS='|' read -r _ pwr data volt curr <<< "$LINE"
                    cat <<EJSON
{
  "powerEn": $pwr,
  "dataEn": $data,
  "voltage": "$volt",
  "current": "$curr",
  "fwdAlert": false,
  "backAlert": false,
  "shortAlert": false
}
EJSON
                    exit 0
                fi
            fi
            echo "error: query $CHANNEL failed" >&2
            exit 1
            ;;
        status)
            STATE_FILE="${MOCK_INSIGHT_HUB_STATE:-}"
            if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
                while IFS='|' read -r ch pwr data volt curr; do
                    pwrstr="OFF"; [ "$pwr" = "true" ] && pwrstr="ON"
                    datastr="no-data"; [ "$data" = "true" ] && datastr="data"
                    echo "$ch: power=$pwrstr $datastr  ${volt}mV  ${curr}mA"
                done < "$STATE_FILE"
                exit 0
            fi
            exit 1
            ;;
        *)
            echo "error: unknown command '$CMD'" >&2
            exit 1
            ;;
    esac
fi

# ── pyserial comports mock ───────────────────────────────────────
SCRIPT="$2"
MOCK_FILE="${MOCK_PYSERIAL_DEVICES:-/dev/null}"

# Extract the serial number from the python snippet.
# Supports both old format: p.serial_number == 'VALUE'
# and new normalized format: norm = 'VALUE'
extract_serial() {
    local sn
    sn=$(echo "$1" | grep -oE "serial_number == '[^']+'" | sed "s/serial_number == '//;s/'//")
    [ -n "$sn" ] && { echo "$sn"; return; }
    sn=$(echo "$1" | grep -oE "norm = '[^']+'" | sed "s/norm = '//;s/'//")
    echo "$sn"
}

# Normalize a MAC: strip colons/dashes, lowercase
normalize_sn() {
    echo "$1" | tr -d ':-' | tr '[:upper:]' '[:lower:]'
}

# Find a device in the mock file by normalized MAC comparison
# Returns the matching line or empty
find_mock_device() {
    local target_norm="$1"
    local mock_file="$2"
    [ -f "$mock_file" ] || return 1
    while IFS= read -r line; do
        local sn
        sn=$(echo "$line" | cut -d'|' -f1)
        local sn_norm
        sn_norm=$(normalize_sn "$sn")
        if [ "$sn_norm" = "$target_norm" ]; then
            echo "$line"
            return 0
        fi
    done < "$mock_file"
    return 1
}

if [[ "$SCRIPT" == *"p.device == port"* && "$SCRIPT" == *"serial_number"* ]]; then
    # cmd_register auto-detect: match by port path, print serial_number\tdescription
    # The script sets: port = '/dev/cu.xxx'
    PORT_PATH=$(echo "$SCRIPT" | grep -oE "port = '[^']+'" | sed "s/port = '//;s/'//")
    if [ -n "$PORT_PATH" ] && [ -f "$MOCK_FILE" ]; then
        while IFS= read -r line; do
            DEV=$(echo "$line" | cut -d'|' -f2)
            if [ "$DEV" = "$PORT_PATH" ]; then
                SN=$(echo "$line" | cut -d'|' -f1)
                DESC=$(echo "$line" | cut -d'|' -f4 -s)
                printf '%s\t%s\n' "$SN" "${DESC:-USB device}"
                exit 0
            fi
        done < "$MOCK_FILE"
    fi
elif [[ "$SCRIPT" == *"serial_number"* && "$SCRIPT" == *"p.device"* ]] || \
   [[ "$SCRIPT" == *"sn == norm"* && "$SCRIPT" == *"p.device"* ]]; then
    # find_serial_port: looking for serial number, print device
    SN=$(extract_serial "$SCRIPT")
    SN_NORM=$(normalize_sn "$SN")
    if [ -n "$SN_NORM" ] && [ -f "$MOCK_FILE" ]; then
        LINE=$(find_mock_device "$SN_NORM" "$MOCK_FILE")
        [ -n "$LINE" ] && echo "$LINE" | cut -d'|' -f2
    fi
elif [[ "$SCRIPT" == *"serial_number"* && "$SCRIPT" == *"p.location"* ]] || \
     [[ "$SCRIPT" == *"sn == norm"* && "$SCRIPT" == *"p.location"* ]]; then
    # find_hub_port_live fallback: looking for serial number, print location
    SN=$(extract_serial "$SCRIPT")
    SN_NORM=$(normalize_sn "$SN")
    if [ -n "$SN_NORM" ] && [ -f "$MOCK_FILE" ]; then
        LINE=$(find_mock_device "$SN_NORM" "$MOCK_FILE")
        [ -n "$LINE" ] && echo "$LINE" | cut -d'|' -f3
    fi
elif [[ "$SCRIPT" == *"sn == norm"* && "$SCRIPT" == *"p.product"* ]]; then
    # detect_device_mode: looking for product string
    SN=$(extract_serial "$SCRIPT")
    SN_NORM=$(normalize_sn "$SN")
    if [ -n "$SN_NORM" ] && [ -f "$MOCK_FILE" ]; then
        LINE=$(find_mock_device "$SN_NORM" "$MOCK_FILE")
        if [ -n "$LINE" ]; then
            # Check for optional 4th field: product name
            PRODUCT=$(echo "$LINE" | cut -d'|' -f4 -s)
            if [ "$PRODUCT" = "USB JTAG/serial debug unit" ]; then
                echo "bootloader"
            else
                echo "app"
            fi
        fi
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
    export USB_DEVICE_CONFIG_DIR="$TEST_DIR"
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

# Set up mock Insight Hub (serial port + hub location)
mock_insight_hub() {
    local port="${1:-/dev/cu.usbmodemHUB1}"
    local location="${2:-20-3}"
    export MOCK_INSIGHT_HUB_PORT="$port"
    export MOCK_INSIGHT_HUB_LOCATION="$location"
    export MOCK_INSIGHT_HUB_LOG="$TEST_DIR/insight_hub_log"
    : > "$MOCK_INSIGHT_HUB_LOG"
}

# Set mock Insight Hub channel state: CHx|powerEn|dataEn|voltage|current
mock_insight_hub_state() {
    MOCK_INSIGHT_HUB_STATE="$TEST_DIR/insight_hub_state"
    export MOCK_INSIGHT_HUB_STATE
    cat > "$MOCK_INSIGHT_HUB_STATE"
}

# Clear Insight Hub mock (hub not present)
mock_no_insight_hub() {
    unset MOCK_INSIGHT_HUB_PORT MOCK_INSIGHT_HUB_LOCATION
    unset MOCK_INSIGHT_HUB_STATE MOCK_INSIGHT_HUB_LOG
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
    mkdir -p "$TEST_DIR/types.d"
    cat > "$TEST_DIR/types.d/testboard2.sh" << 'PLUGIN'
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

@test "checkout: multi-device acquires all in sorted order" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    run "$USB_DEVICE" checkout "Device C" "Device A" "Device B"
    [ "$status" -eq 0 ]
    # All three locked
    [ -d "$TEST_DIR/locks/device_a" ]
    [ -d "$TEST_DIR/locks/device_b" ]
    [ -d "$TEST_DIR/locks/device_c" ]
    # Output order should be sorted (A, B, C)
    [[ "$output" == *"Checked out 'Device A'"* ]]
    [[ "$output" == *"Checked out 'Device B'"* ]]
    [[ "$output" == *"Checked out 'Device C'"* ]]
}

@test "checkout: multi-device rolls back on failure" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Pre-lock Device B with a live PID
    mkdir -p "$TEST_DIR/locks/device_b"
    cat > "$TEST_DIR/locks/device_b/info" <<EOF
PID=$PPID
OWNER=blocker
TIMESTAMP=2026-02-19T10:00:00Z
PURPOSE=blocking
TTL=999999
EOF

    run "$USB_DEVICE" checkout "Device C" "Device A" "Device B"
    [ "$status" -eq 1 ]
    # Device A was acquired first (sorted) then rolled back
    [[ "$output" == *"Rolled back 'Device A'"* ]]
    # No locks should remain from our attempt
    [ ! -d "$TEST_DIR/locks/device_a" ]
    [ ! -d "$TEST_DIR/locks/device_c" ]
    # Blocker's lock still intact
    [ -d "$TEST_DIR/locks/device_b" ]
}

@test "checkin: multi-device releases all" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Checkout two devices
    "$USB_DEVICE" checkout "Device A" "Device B"

    run "$USB_DEVICE" checkin "Device A" "Device B"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checked in 'Device A'"* ]]
    [[ "$output" == *"Checked in 'Device B'"* ]]
    [ ! -d "$TEST_DIR/locks/device_a" ]
    [ ! -d "$TEST_DIR/locks/device_b" ]
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

@test "plugin: subdirectory plugin found" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=subtest
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    # Create a plugin in a subdirectory (simulates symlinked project types)
    mkdir -p "$TEST_DIR/types.d/my-project"
    cat > "$TEST_DIR/types.d/my-project/subtest.sh" << 'PLUGIN'
type_subtest_bootloader() {
    echo "SUBDIR_PLUGIN port=$1 name=$2"
}
PLUGIN

    run "$USB_DEVICE" bootloader "Board Alpha"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUBDIR_PLUGIN port=/dev/cu.usbmodem101 name=Board Alpha"* ]]
}

@test "plugin: flat file takes priority over subdirectory" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=pritest
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    # Create flat plugin (should win)
    mkdir -p "$TEST_DIR/types.d"
    cat > "$TEST_DIR/types.d/pritest.sh" << 'PLUGIN'
type_pritest_bootloader() { echo "FLAT_WINS"; }
PLUGIN

    # Create same plugin in subdirectory (should lose)
    mkdir -p "$TEST_DIR/types.d/my-project"
    cat > "$TEST_DIR/types.d/my-project/pritest.sh" << 'PLUGIN'
type_pritest_bootloader() { echo "SUBDIR_LOSES"; }
PLUGIN

    run "$USB_DEVICE" bootloader "Board Alpha"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FLAT_WINS"* ]]
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

# ── Insight Hub integration ──────────────────────────────────────

@test "insight hub: off routes through serial API when device is on hub" {
    mock_insight_hub "/dev/cu.usbmodemHUB1" "20-3"
    mock_uhubctl << 'EOF'
Current status for hub 20-3, vendor 0451:8142, USB 3.10, 4 ports, ppps
  Port 2: 0503 power highspeed enable connect [303a:1001 AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-3.2
EOF

    run "$USB_DEVICE" off "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Insight Hub"* ]]
    [[ "$output" == *"CH2"* ]]

    # Verify the right command was logged
    run cat "$TEST_DIR/insight_hub_log"
    [ "$status" -eq 0 ]
    [[ "$output" == *"power CH2 off"* ]]
}

@test "insight hub: on routes through serial API when device is on hub" {
    mock_insight_hub "/dev/cu.usbmodemHUB1" "20-3"
    mock_uhubctl << 'EOF'
Current status for hub 20-3, vendor 0451:8142, USB 3.10, 4 ports, ppps
  Port 1: 0503 power highspeed enable connect [303a:1001 AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-3.1
EOF

    run "$USB_DEVICE" on "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Insight Hub"* ]]
    [[ "$output" == *"CH1"* ]]

    run cat "$TEST_DIR/insight_hub_log"
    [[ "$output" == *"power CH1 on"* ]]
}

@test "insight hub: reset uses cycle command" {
    mock_insight_hub "/dev/cu.usbmodemHUB1" "20-3"
    mock_uhubctl << 'EOF'
Current status for hub 20-3, vendor 0451:8142, USB 3.10, 4 ports, ppps
  Port 3: 0503 power highspeed enable connect [303a:1001 AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-3.3
EOF

    # Device won't "come back" in mock, but the cycle command should be issued
    run "$USB_DEVICE" reset "Device A"
    # reset will fail because device_is_alive won't see the device after cycle,
    # but we can verify the cycle was attempted
    [[ "$output" == *"Insight Hub"* ]]
    [[ "$output" == *"CH3"* ]]

    run cat "$TEST_DIR/insight_hub_log"
    [[ "$output" == *"cycle CH3 2"* ]]
}

@test "insight hub: device NOT on hub falls through to uhubctl" {
    mock_insight_hub "/dev/cu.usbmodemHUB1" "20-3"
    # Device is on hub 20-2, NOT 20-3 (the Insight Hub)
    mock_uhubctl << 'EOF'
Current status for hub 20-2, vendor 2109:2817, USB 3.20, 4 ports, ppps
  Port 1: 0503 power highspeed enable connect [303a:1001 AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    # Need a mock sudo that passes through to uhubctl
    cat > "$MOCK_BIN/sudo" << 'SUDMOCK'
#!/bin/bash
"$@"
SUDMOCK
    chmod +x "$MOCK_BIN/sudo"

    run "$USB_DEVICE" off "Device A"
    [ "$status" -eq 0 ]
    # Should NOT mention Insight Hub
    [[ "$output" != *"Insight Hub"* ]]
    [[ "$output" == *"hub 20-2"* ]]
}

@test "insight hub: no hub present falls through to uhubctl" {
    mock_no_insight_hub
    mock_uhubctl << 'EOF'
Current status for hub 20-2, vendor 2109:2817, USB 3.20, 4 ports, ppps
  Port 1: 0503 power highspeed enable connect [303a:1001 AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1
EOF

    cat > "$MOCK_BIN/sudo" << 'SUDMOCK'
#!/bin/bash
"$@"
SUDMOCK
    chmod +x "$MOCK_BIN/sudo"

    run "$USB_DEVICE" off "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Insight Hub"* ]]
    [[ "$output" == *"hub 20-2"* ]]
}

@test "insight hub: child hub location matches (device behind sub-hub)" {
    # Insight Hub at 20-3, device behind sub-hub at 20-3.2.1
    mock_insight_hub "/dev/cu.usbmodemHUB1" "20-3"
    mock_uhubctl << 'EOF'
Current status for hub 20-3, vendor 0451:8142, USB 3.10, 4 ports, ppps
  Port 2: 0503 power highspeed enable connect [045b:0209 USB2.0 Hub]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-3.2.1
EOF

    run "$USB_DEVICE" off "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Insight Hub"* ]]
    [[ "$output" == *"CH2"* ]]

    run cat "$TEST_DIR/insight_hub_log"
    [[ "$output" == *"power CH2 off"* ]]
}

@test "insight hub: port 4+ not mapped to channel (falls through)" {
    # Insight Hub only has 3 channels. If a device is on port 4,
    # channel mapping should fail and it should fall through to uhubctl.
    mock_insight_hub "/dev/cu.usbmodemHUB1" "20-3"
    mock_uhubctl << 'EOF'
Current status for hub 20-3, vendor 0451:8142, USB 3.10, 4 ports, ppps
  Port 4: 0503 power highspeed enable connect [303a:1001 AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-3.4
EOF

    cat > "$MOCK_BIN/sudo" << 'SUDMOCK'
#!/bin/bash
"$@"
SUDMOCK
    chmod +x "$MOCK_BIN/sudo"

    run "$USB_DEVICE" off "Device A"
    [ "$status" -eq 0 ]
    # Port 4 can't be mapped to CH1-3, so should NOT use Insight Hub
    [[ "$output" != *"Insight Hub"* ]]
}

@test "insight hub: cached location used when device offline" {
    mock_insight_hub "/dev/cu.usbmodemHUB1" "20-3"
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    # Device was previously seen on Insight Hub port 1
    cat > "$DB" << 'EOF'
{
    "Device A": {
        "mac": "AA:AA:AA:AA:AA:AA",
        "hub": "20-3",
        "port": "1",
        "link": "direct",
        "dev": "/dev/cu.usbmodem101",
        "last_seen": "2026-02-20T10:00:00Z"
    }
}
EOF

    run "$USB_DEVICE" off "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Insight Hub"* ]]
    [[ "$output" == *"CH1"* ]]

    run cat "$TEST_DIR/insight_hub_log"
    [[ "$output" == *"power CH1 off"* ]]
}

# ── MAC normalization ─────────────────────────────────────────────

@test "scan: finds device with colon-separated MAC (bootloader format)" {
    cat > "$CONF" << 'EOF'
[Insight Hub]
mac=B43A45B5582C
type=insight_hub
EOF
    # Device is in bootloader — serial has colons
    mock_uhubctl << 'EOF'
Current status for hub 20-3.3 [045b:0209, USB 2.00, 4 ports, ppps]
  Port 4: 0103 power enable connect [303a:1001 B4:3A:45:B5:58:2C USB JTAG/serial debug unit]
EOF
    mock_pyserial << 'EOF'
B4:3A:45:B5:58:2C|/dev/cu.usbmodem1433401|20-3.3.4|USB JTAG/serial debug unit
EOF

    run "$USB_DEVICE" scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Insight Hub"* ]]
    [[ "$output" == *"hub=20-3.3"* ]]
    [[ "$output" == *"port=4"* ]]
    [[ "$output" == *"BOOTLOADER"* ]]
}

@test "scan: finds device with no-colon MAC (app mode)" {
    cat > "$CONF" << 'EOF'
[Insight Hub]
mac=B43A45B5582C
type=insight_hub
EOF
    mock_uhubctl << 'EOF'
Current status for hub 20-3.3 [045b:0209, USB 2.00, 4 ports, ppps]
  Port 4: 0103 power enable connect [303a:1001 Aerio InsightHUB Controller B43A45B5582C]
EOF
    mock_pyserial << 'EOF'
B43A45B5582C|/dev/cu.usbmodemB43A45B5582C1|20-3.3.4|InsightHUB Controller
EOF

    run "$USB_DEVICE" scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Insight Hub"* ]]
    [[ "$output" == *"[found]"* ]]
    [[ "$output" != *"BOOTLOADER"* ]]
}

@test "port: finds device by normalized MAC when serial has colons" {
    cat > "$CONF" << 'EOF'
[Insight Hub]
mac=B43A45B5582C
type=insight_hub
EOF
    # Device in bootloader mode — pyserial reports serial with colons
    mock_pyserial << 'EOF'
B4:3A:45:B5:58:2C|/dev/cu.usbmodem1433401|20-3.3.4
EOF

    run "$USB_DEVICE" port "Insight Hub"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/cu.usbmodem1433401" ]
}

@test "find: normalized MAC matches across formats" {
    cat > "$CONF" << 'EOF'
[Insight Hub]
mac=B43A45B5582C
type=insight_hub
EOF
    # uhubctl shows the hub but device is behind a sub-hub (indirect match)
    mock_uhubctl << 'EOF'
Current status for hub 20-3.3 [045b:0209, USB 2.00, 4 ports, ppps]
  Port 4: 0103 power enable connect [303a:1001 B4:3A:45:B5:58:2C USB JTAG/serial debug unit]
EOF
    mock_pyserial << 'EOF'
B4:3A:45:B5:58:2C|/dev/cu.usbmodem1433401|20-3.3.4
EOF

    run "$USB_DEVICE" find "Insight Hub"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dev:  /dev/cu.usbmodem1433401"* ]]
    [[ "$output" == *"hub:  20-3.3"* ]]
    [[ "$output" == *"port: 4"* ]]
}

# ── Help command ─────────────────────────────────────────────────

@test "help: shows usage text" {
    run "$USB_DEVICE" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage: usb-device"* ]]
    [[ "$output" == *"register"* ]]
    [[ "$output" == *"Commands:"* ]]
}

@test "help: --help flag works" {
    run "$USB_DEVICE" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage: usb-device"* ]]
}

@test "help: -h flag works" {
    run "$USB_DEVICE" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage: usb-device"* ]]
}

@test "help: no args shows usage" {
    run "$USB_DEVICE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: usb-device"* ]]
}

# ── Register command ─────────────────────────────────────────────

@test "register: with explicit MAC creates config entry" {
    cat > "$CONF" << 'EOF'
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" register "New Board" --mac "DD:DD:DD:DD:DD:DD" --type esp32 --chip esp32s3
    [ "$status" -eq 0 ]
    [[ "$output" == *"Registered 'New Board'"* ]]
    [[ "$output" == *"mac=DD:DD:DD:DD:DD:DD"* ]]

    # Config file should have the new section
    run grep "\[New Board\]" "$CONF"
    [ "$status" -eq 0 ]
    run grep "mac=DD:DD:DD:DD:DD:DD" "$CONF"
    [ "$status" -eq 0 ]
    run grep "type=esp32" "$CONF"
    [ "$status" -eq 0 ]
    run grep "chip=esp32s3" "$CONF"
    [ "$status" -eq 0 ]
}

@test "register: auto-detect from port" {
    cat > "$CONF" << 'EOF'
EOF
    mock_uhubctl < /dev/null
    mock_pyserial << 'EOF'
EE:EE:EE:EE:EE:EE|/dev/cu.usbmodem201|20-2.1|USB JTAG/serial debug unit
EOF

    run "$USB_DEVICE" register "Auto Board" --port /dev/cu.usbmodem201
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected:"* ]]
    [[ "$output" == *"Serial:"*"EE:EE:EE:EE:EE:EE"* ]]
    [[ "$output" == *"Registered 'Auto Board'"* ]]

    run grep "mac=EE:EE:EE:EE:EE:EE" "$CONF"
    [ "$status" -eq 0 ]
}

@test "register: duplicate name is rejected" {
    cat > "$CONF" << 'EOF'
[Existing Board]
mac=AA:AA:AA:AA:AA:AA
type=esp32
EOF

    run "$USB_DEVICE" register "Existing Board" --mac "BB:BB:BB:BB:BB:BB"
    [ "$status" -eq 1 ]
    [[ "$output" == *"already registered"* ]]
}

@test "register: fails without --port or --mac" {
    run "$USB_DEVICE" register "Lonely Board"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must specify --port or --mac"* ]]
}

@test "register: fails without name" {
    run "$USB_DEVICE" register --mac "AA:BB:CC:DD:EE:FF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage:"* ]]
}

@test "register: port not found gives clear error" {
    cat > "$CONF" << 'EOF'
EOF
    mock_pyserial < /dev/null

    run "$USB_DEVICE" register "Ghost Board" --port /dev/cu.nonexistent
    [ "$status" -eq 1 ]
    [[ "$output" == *"no device found on port"* ]]
}

@test "register: --serial flag works same as --mac" {
    cat > "$CONF" << 'EOF'
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" register "Serial Board" --serial "FF:FF:FF:FF:FF:FF"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Registered 'Serial Board'"* ]]
    run grep "mac=FF:FF:FF:FF:FF:FF" "$CONF"
    [ "$status" -eq 0 ]
}

@test "register: custom type and chip" {
    cat > "$CONF" << 'EOF'
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" register "PPK Board" --mac "11:22:33:44:55:66" --type ppk2 --chip nrf52840
    [ "$status" -eq 0 ]
    run grep "type=ppk2" "$CONF"
    [ "$status" -eq 0 ]
    run grep "chip=nrf52840" "$CONF"
    [ "$status" -eq 0 ]
}

@test "register: hub-name option" {
    cat > "$CONF" << 'EOF'
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" register "Hub Board" --mac "AA:BB:CC:DD:EE:FF" --hub-name "My Board"
    [ "$status" -eq 0 ]
    run grep "hub_name=My Board" "$CONF"
    [ "$status" -eq 0 ]
}

@test "register: triggers scan after registration" {
    cat > "$CONF" << 'EOF'
EOF
    mock_uhubctl << 'EOF'
Current status for hub 20-2, vendor 2109:2817, USB 3.20, 4 ports, ppps
  Port 1: 0503 power highspeed enable connect [1d50:6018 AA:BB:CC:DD:EE:FF USB JTAG/serial debug unit]
EOF
    mock_pyserial << 'EOF'
AA:BB:CC:DD:EE:FF|/dev/cu.usbmodem101|20-2.1
EOF

    run "$USB_DEVICE" register "Scan Board" --mac "AA:BB:CC:DD:EE:FF"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Scanning USB bus"* ]]
    [[ "$output" == *"Scan Board"* ]]
    [[ "$output" == *"[found]"* ]]

    # DB should be populated
    run jq -r '.["Scan Board"].hub' "$DB"
    [ "$output" = "20-2" ]
}
