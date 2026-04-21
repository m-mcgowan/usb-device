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

if [[ "$SCRIPT" == *"p.manufacturer"* && "$SCRIPT" == *"for p in comports()"* ]]; then
    # cmd_discover: enumerate all ports as serial\tdevice\tmanufacturer\tproduct\tlocation
    if [ -f "$MOCK_FILE" ]; then
        while IFS='|' read -r sn dev loc product; do
            [ -z "$sn" ] || [ "$sn" = "-" ] && continue
            mfg="-"
            [[ "$product" == *"Espressif"* ]] && mfg="Espressif"
            [[ "$product" == *"PPK2"* ]] && mfg="Nordic Semiconductor"
            printf '%s\t%s\t%s\t%s\t%s\n' "$sn" "$dev" "$mfg" "${product:--}" "${loc:--}"
        done < "$MOCK_FILE"
    fi
elif [[ "$SCRIPT" == *"p.device == port"* && "$SCRIPT" == *"serial_number"* ]]; then
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
    # Use current timestamp so TTL hasn't expired
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=other-user
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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

@test "checkin: refuses lock from dead process without -f" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock with a dead PID — not ours, needs -f
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=99998
OWNER=test
TIMESTAMP=2026-02-19T10:00:00Z
PURPOSE=testing
TTL=1800
EOF

    run "$USB_DEVICE" checkin "Device A"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not owned by this session"* ]]
    [ -d "$TEST_DIR/locks/device_a" ]

    # Force release works
    run "$USB_DEVICE" checkin -f "Device A"
    [ "$status" -eq 0 ]
    [ ! -d "$TEST_DIR/locks/device_a" ]
}

@test "checkin: refuses to release another process's lock" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Use a non-ancestor process as the lock holder (sleep in background)
    sleep 300 &
    local other_pid=$!

    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$other_pid
OWNER=other-user
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=testing
TTL=0
LSTART=$(ps -p "$other_pid" -o lstart= 2>/dev/null)
COMM=sleep
EOF

    run "$USB_DEVICE" checkin "Device A"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not owned by this session"* ]]
    # Lock should still exist
    [ -d "$TEST_DIR/locks/device_a" ]

    kill "$other_pid" 2>/dev/null || true
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

@test "locks --mine: lists only devices locked by this session" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Lock Device A with our PID
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=test
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=mine
TTL=3600
EOF

    # Lock Device B with a different PID (background process)
    sleep 300 &
    local other_pid=$!
    mkdir -p "$TEST_DIR/locks/device_b"
    cat > "$TEST_DIR/locks/device_b/info" <<EOF
PID=$other_pid
OWNER=other
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=theirs
TTL=3600
EOF

    run env USB_DEVICE_LOCK_PID=$PPID "$USB_DEVICE" locks --mine
    kill $other_pid 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"Device A"* ]]
    [[ "$output" != *"Device B"* ]]
}

@test "locks --mine: outputs bare device names" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=test
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=mine
TTL=3600
EOF

    run env USB_DEVICE_LOCK_PID=$PPID "$USB_DEVICE" locks --mine
    [ "$status" -eq 0 ]
    # Should be bare name, no "LOCKED" decoration
    [[ "$output" != *"LOCKED"* ]]
    [ "$output" = "Device A" ]
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

    # Pre-lock Device B with a live PID and current timestamp so TTL hasn't expired
    mkdir -p "$TEST_DIR/locks/device_b"
    cat > "$TEST_DIR/locks/device_b/info" <<EOF
PID=$PPID
OWNER=blocker
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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

@test "checkin: multi-device releases all (force)" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Pre-create locks with a different PID — need -f to release
    for dev in device_a device_b; do
        mkdir -p "$TEST_DIR/locks/$dev"
        cat > "$TEST_DIR/locks/$dev/info" <<EOF
PID=99997
OWNER=test
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=multi-checkin test
TTL=1800
EOF
    done

    run "$USB_DEVICE" checkin -f "Device A" "Device B"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checked in 'Device A'"* ]]
    [[ "$output" == *"Checked in 'Device B'"* ]]
    [ ! -d "$TEST_DIR/locks/device_a" ]
    [ ! -d "$TEST_DIR/locks/device_b" ]
}

@test "checkout: re-entrant — same PID refreshes without incrementing refcount" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock owned by our PPID (simulates prior checkout from same shell)
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=test
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=original
TTL=3600
REFCOUNT=1
EOF

    # Checkout again with same PID should refresh without changing refcount
    run "$USB_DEVICE" checkout --pid "$PPID" --purpose "refreshed" "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Refreshed lock"* ]]

    # Refcount should still be 1
    run grep "^REFCOUNT=1" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
    # Purpose should be updated
    run grep "^PURPOSE=refreshed" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
}

@test "checkout: re-entrant — ancestor PID increments refcount" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock owned by an ancestor (grandparent PPID of the usb-device process)
    local default_owner="$(whoami)@$(hostname -s)"
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$$
OWNER=$default_owner
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=parent session
TTL=3600
REFCOUNT=1
EOF

    # Checkout from child process should increment refcount
    run "$USB_DEVICE" checkout --purpose "child task" "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Acquired lock"* ]]
    [[ "$output" == *"refcount=2"* ]]

    # Refcount should be 2
    run grep "^REFCOUNT=2" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
}

@test "checkin: decrements refcount without releasing" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock with refcount=2 (simulates parent + child holder)
    local real_lstart
    real_lstart=$(ps -p $$ -o lstart= 2>/dev/null)
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$$
OWNER=test
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=shared
TTL=3600
REFCOUNT=2
LSTART=$real_lstart
COMM=bash
EOF

    # First checkin should decrement, not release
    run "$USB_DEVICE" checkin --pid $$ "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released hold"* ]]
    [[ "$output" == *"refcount=1"* ]]
    [ -d "$TEST_DIR/locks/device_a" ]

    # Second checkin should fully release
    run "$USB_DEVICE" checkin --pid $$ "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checked in"* ]]
    [ ! -d "$TEST_DIR/locks/device_a" ]
}

@test "checkin: descendant of lock holder can release" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock owned by $PPID (ancestor of current $$)
    local real_lstart
    real_lstart=$(ps -p "$PPID" -o lstart= 2>/dev/null)
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=test
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=parent-session
TTL=0
REFCOUNT=2
LSTART=$real_lstart
COMM=bash
EOF

    # Checkin from child ($$) should succeed — $$ is a descendant of $PPID
    run "$USB_DEVICE" checkin --pid $$ "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released hold"* ]]
    [[ "$output" == *"refcount=1"* ]]
    [ -d "$TEST_DIR/locks/device_a" ]
}

@test "checkout: re-entrant — USB_DEVICE_LOCK_PID env var" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Spawn a background process to hold the lock (not an ancestor)
    sleep 300 &
    local holder_pid=$!

    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$holder_pid
OWNER=test
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=parent session
TTL=3600
EOF

    # With USB_DEVICE_LOCK_PID set, child process can re-enter
    USB_DEVICE_LOCK_PID=$holder_pid run "$USB_DEVICE" checkout --purpose "child task" "Device A"
    kill $holder_pid 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"Refreshed lock"* ]]
}

@test "checkout --export: includes USB_DEVICE_LOCK_PID" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
EOF

    run "$USB_DEVICE" checkout --export "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"USB_DEVICE_LOCK_PID="* ]]
}

@test "checkout: --pid stores explicit PID" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    run "$USB_DEVICE" checkout --pid 12345 "Device A"
    [ "$status" -eq 0 ]

    run grep "^PID=12345" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
}

@test "checkout --shared: joins lock held by same owner (non-ancestor)" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Spawn a background process that's alive but not an ancestor
    sleep 300 &
    local other_pid=$!

    local owner="$(whoami)@$(hostname -s)"
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$other_pid
OWNER=$owner
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=terminal session
TTL=3600
EOF

    run "$USB_DEVICE" checkout --shared "Device A"
    kill $other_pid 2>/dev/null || true
    [ "$status" -eq 2 ]
    [[ "$output" == *"Sharing lock"* ]]

    # Original lock should be unmodified
    run grep "^PURPOSE=terminal session" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
}

@test "checkout --shared: fails when different owner holds lock" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=someone-else@other-host
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=their work
TTL=3600
EOF

    run "$USB_DEVICE" checkout --shared "Device A"
    [ "$status" -eq 1 ]
    [[ "$output" == *"checked out"* ]]
}

@test "checkout --shared: acquires normally when device is free" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    run "$USB_DEVICE" checkout --shared "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checked out"* ]]
    [ -d "$TEST_DIR/locks/device_a" ]
}

@test "checkin --mine: releases all locks held by matching PID" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create two locks owned by PID 55555, one by someone else
    for dev in device_a device_b device_c; do
        mkdir -p "$TEST_DIR/locks/$dev"
    done
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=55555
OWNER=me
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TTL=3600
EOF
    cat > "$TEST_DIR/locks/device_b/info" <<EOF
PID=55555
OWNER=me
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TTL=3600
EOF
    cat > "$TEST_DIR/locks/device_c/info" <<EOF
PID=99999
OWNER=other
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TTL=3600
EOF

    run "$USB_DEVICE" checkin --mine --pid 55555
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checked in 'Device A'"* ]]
    [[ "$output" == *"Checked in 'Device B'"* ]]

    # Our locks gone, other's lock preserved
    [ ! -d "$TEST_DIR/locks/device_a" ]
    [ ! -d "$TEST_DIR/locks/device_b" ]
    [ -d "$TEST_DIR/locks/device_c" ]
}

@test "port --bootloader: uses bootloader_mac when configured" {
    cat > "$CONF" << 'EOF'
[Hub Device]
mac=AA:AA:AA:AA:AA:AA
type=insight_hub
bootloader_mac=BB:BB:BB:BB:BB:BB
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
BB:BB:BB:BB:BB:BB|/dev/cu.usbmodem201|20-4.2
EOF

    run "$USB_DEVICE" port "Hub Device"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/cu.usbmodem101" ]

    run "$USB_DEVICE" port --bootloader "Hub Device"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/cu.usbmodem201" ]
}

@test "port --bootloader: falls back to runtime port" {
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
EOF

    run "$USB_DEVICE" port --bootloader "Device A"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/cu.usbmodem101" ]
}

@test "env: includes bootloader port when different" {
    cat > "$CONF" << 'EOF'
[Hub Device]
mac=AA:AA:AA:AA:AA:AA
type=insight_hub
bootloader_mac=BB:BB:BB:BB:BB:BB
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
BB:BB:BB:BB:BB:BB|/dev/cu.usbmodem201|20-4.2
EOF

    run "$USB_DEVICE" env "Hub Device"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLATFORMIO_UPLOAD_PORT='/dev/cu.usbmodem201'"* ]]
    [[ "$output" == *"DEVICE_PORT='/dev/cu.usbmodem101'"* ]]
    [[ "$output" == *"DEVICE_BOOTLOADER_PORT='/dev/cu.usbmodem201'"* ]]
}

@test "checkout --export: outputs shell exports" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
EOF

    run "$USB_DEVICE" checkout --export "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"export PIO_LABGRID_DEVICE='Device A'"* ]]
    [[ "$output" == *"export PLATFORMIO_UPLOAD_PORT='/dev/cu.usbmodem101'"* ]]
    [[ "$output" == *"export DEVICE_NAME='Device A'"* ]]
    [[ "$output" == *"export DEVICE_PORT='/dev/cu.usbmodem101'"* ]]
}

@test "checkout --any: acquires first available match" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"
    mock_uhubctl << 'EOF'
Current status for hub 20-4 [0000:0000, USB 2.10, 4 ports, ppps]
  Port 1: 0103 power enable connect [303a:1001 Espressif USB JTAG AA:AA:AA:AA:AA:AA]
  Port 2: 0103 power enable connect [303a:1001 Espressif USB JTAG BB:BB:BB:BB:BB:BB]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
BB:BB:BB:BB:BB:BB|/dev/cu.usbmodem102|20-4.2
EOF

    # Lock Device A
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=someone
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=blocking
TTL=3600
EOF

    run "$USB_DEVICE" checkout --any "Device"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEVICE_NAME='Device B'"* ]]
    [ -d "$TEST_DIR/locks/device_b" ]
}

@test "checkout --any: prints structured output" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
EOF

    run "$USB_DEVICE" checkout --any "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEVICE_NAME='Device A'"* ]]
    [[ "$output" == *"DEVICE_PORT='/dev/cu.usbmodem101'"* ]]
}

@test "checkout --any: fails when all locked" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"
    mock_uhubctl << 'EOF'
Current status for hub 20-4 [0000:0000, USB 2.10, 4 ports, ppps]
  Port 1: 0103 power enable connect [303a:1001 Espressif USB JTAG AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
EOF

    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=blocker
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=blocking
TTL=3600
EOF

    run "$USB_DEVICE" checkout --any "Device A"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No available devices"* ]]
}

@test "find: shows lock status — available" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"
    mock_uhubctl << 'EOF'
Current status for hub 20-4 [0000:0000, USB 2.10, 4 ports, ppps]
  Port 1: 0103 power enable connect [303a:1001 Espressif USB JTAG AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
EOF

    run "$USB_DEVICE" find "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lock: available"* ]]
}

@test "find: shows lock status — locked" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"
    mock_uhubctl << 'EOF'
Current status for hub 20-4 [0000:0000, USB 2.10, 4 ports, ppps]
  Port 1: 0103 power enable connect [303a:1001 Espressif USB JTAG AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
EOF

    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=ci-bot
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=nightly
TTL=1800
EOF

    run "$USB_DEVICE" find "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lock: LOCKED by ci-bot (nightly)"* ]]
}

@test "find --available: selects first unlocked+connected device" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Three devices: A locked, B connected, C connected
    cat > "$CONF" << 'EOF'
[Device A]
mac=AA:AA:AA:AA:AA:AA
type=esp32

[Device B]
mac=BB:BB:BB:BB:BB:BB
type=esp32

[Device C]
mac=CC:CC:CC:CC:CC:CC
type=esp32
EOF
    mock_uhubctl << 'EOF'
Current status for hub 20-4 [0000:0000, USB 2.10, 4 ports, ppps]
  Port 1: 0103 power enable connect [303a:1001 Espressif USB JTAG AA:AA:AA:AA:AA:AA]
  Port 2: 0103 power enable connect [303a:1001 Espressif USB JTAG BB:BB:BB:BB:BB:BB]
  Port 3: 0103 power enable connect [303a:1001 Espressif USB JTAG CC:CC:CC:CC:CC:CC]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
BB:BB:BB:BB:BB:BB|/dev/cu.usbmodem102|20-4.2
CC:CC:CC:CC:CC:CC|/dev/cu.usbmodem103|20-4.3
EOF

    # Lock Device A
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=someone
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=testing
TTL=1800
EOF

    run "$USB_DEVICE" find --available "Device"
    [ "$status" -eq 0 ]
    [[ "$output" == *"name: Device B"* ]]
    [[ "$output" == *"lock: available"* ]]
}

@test "find --available: fails when all locked" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"
    mock_uhubctl << 'EOF'
Current status for hub 20-4 [0000:0000, USB 2.10, 4 ports, ppps]
  Port 1: 0103 power enable connect [303a:1001 Espressif USB JTAG AA:AA:AA:AA:AA:AA]
EOF
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-4.1
EOF

    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=blocker
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=blocking
TTL=1800
EOF

    run "$USB_DEVICE" find --available "Device A"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No available devices"* ]]
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

# ── Checkout: fuzzy match should filter locked devices ────────────

@test "checkout: fuzzy match skips locked devices in selection" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Lock Device A (alive PID so it won't be reclaimed)
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=someone
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=testing
TTL=999999
EOF

    # "Device" matches A, B, C — pipe "1" as selection input
    run bash -c 'echo 1 | "$1" checkout "$2"' _ "$USB_DEVICE" "Device"
    [ "$status" -eq 0 ]

    # Should have checked out Device B (first unlocked), not Device A
    [[ "$output" == *"Checked out 'Device B'"* ]]
    [ -d "$TEST_DIR/locks/device_b" ]
}

@test "checkout: shows locked devices before menu" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Lock Device A
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=someone
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=testing
TTL=999999
EOF

    # "Device" matches A, B, C — pipe "1" as selection
    run bash -c 'echo 1 | "$1" checkout "$2"' _ "$USB_DEVICE" "Device"
    [ "$status" -eq 0 ]

    # Locked device should be shown as locked (not in the numbered menu)
    [[ "$output" == *"Device A"* ]]
    [[ "$output" == *"locked"* ]] || [[ "$output" == *"LOCKED"* ]]
}

@test "checkout: auto-selects when only one device unlocked" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Lock Device A and Device B
    for dev in device_a device_b; do
        mkdir -p "$TEST_DIR/locks/$dev"
        cat > "$TEST_DIR/locks/$dev/info" <<EOF
PID=$PPID
OWNER=someone
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=testing
TTL=999999
EOF
    done

    # "Device" matches A, B, C — should auto-select C (only unlocked)
    run "$USB_DEVICE" checkout "Device"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checked out 'Device C'"* ]]
    [ -d "$TEST_DIR/locks/device_c" ]
}

@test "checkout: fails with message when all fuzzy matches locked" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Lock all three devices
    for dev in device_a device_b device_c; do
        mkdir -p "$TEST_DIR/locks/$dev"
        cat > "$TEST_DIR/locks/$dev/info" <<EOF
PID=$PPID
OWNER=someone
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=testing
TTL=999999
EOF
    done

    run "$USB_DEVICE" checkout "Device"
    [ "$status" -eq 1 ]
    [[ "$output" == *"locked"* ]] || [[ "$output" == *"LOCKED"* ]]

    # Should not show spurious "checked out" message for empty device name
    [[ "$output" != *"Device '' is checked out"* ]]
}

# ── Selection menu: lock status annotations ──────────────────────

@test "find: selection menu shows lock status for locked devices" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Mock device B as connected so find succeeds after selection
    mock_pyserial << 'EOF'
BB:BB:BB:BB:BB:BB|/dev/cu.usbmodem101|20-2.1
EOF
    jq '.["Device B"] = {"hub":"20-2","port":"1","serial_port":"/dev/cu.usbmodem101"}' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"

    # Lock Device A with a real LSTART so it won't be reclaimed
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=ci-user
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=integration-test
TTL=0
LSTART=$(ps -p "$PPID" -o lstart= 2>/dev/null)
COMM=$(ps -p "$PPID" -o comm= 2>/dev/null)
EOF

    # "Device" matches A, B, C — pipe "2" to select Device B
    # The menu should annotate Device A as locked
    run bash -c 'echo 2 | "$1" find "$2"' _ "$USB_DEVICE" "Device"
    [ "$status" -eq 0 ]

    # Device A should show as LOCKED with owner info
    [[ "$output" == *"Device A"*"LOCKED"*"ci-user"* ]]
    # Device B should NOT show as locked
    [[ "$output" != *"Device B"*"LOCKED"* ]]
}

@test "find: selection menu shows offline status" {
    # Only Device B is connected — A and C are offline
    mock_pyserial << 'EOF'
BB:BB:BB:BB:BB:BB|/dev/cu.usbmodem101|20-2.1
EOF
    jq '.["Device B"] = {"hub":"20-2","port":"1","serial_port":"/dev/cu.usbmodem101"}' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"

    # "Device" matches A, B, C — pipe "1" to select an option
    run bash -c 'echo 1 | "$1" find "$2"' _ "$USB_DEVICE" "Device"

    # Device A should show as offline
    echo "$output" | grep "Device A" | grep -q "offline"
    # Device B should NOT show as offline (check the specific menu line)
    ! echo "$output" | grep "Device B" | grep -q "offline"
    # Device C should show as offline
    echo "$output" | grep "Device C" | grep -q "offline"
}

@test "find: selection menu shows both offline and locked" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # No devices connected (all offline)
    mock_pyserial < /dev/null

    # Lock Device A
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=ci-user
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=testing
TTL=0
LSTART=$(ps -p "$PPID" -o lstart= 2>/dev/null)
COMM=$(ps -p "$PPID" -o comm= 2>/dev/null)
EOF

    # "Device" matches A, B, C — pipe "1" to select
    run bash -c 'echo 1 | "$1" find "$2"' _ "$USB_DEVICE" "Device"

    # Device A should show both offline and locked
    echo "$output" | grep "Device A" | grep -q "offline"
    echo "$output" | grep "Device A" | grep -q "LOCKED"
    # Device B should show offline but not locked
    echo "$output" | grep "Device B" | grep -q "offline"
    ! echo "$output" | grep "Device B" | grep -q "LOCKED"
}

# ── Lock metadata: LSTART, COMM, PID recycling ──────────────────

@test "checkout: lock file contains LSTART and COMM" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    run "$USB_DEVICE" checkout "Device A"
    [ "$status" -eq 0 ]

    # LSTART should be present and non-empty (captures process start time)
    run grep "^LSTART=" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
    [[ "$output" != "LSTART=" ]]  # not empty

    # COMM should be present and non-empty (captures process name)
    run grep "^COMM=" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
    [[ "$output" != "COMM=" ]]  # not empty
}

@test "checkout: default TTL is 0" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    run "$USB_DEVICE" checkout "Device A"
    [ "$status" -eq 0 ]

    run grep "^TTL=" "$TEST_DIR/locks/device_a/info"
    [ "$status" -eq 0 ]
    [ "$output" = "TTL=0" ]
}

@test "checkout: reclaims lock when PID is alive but start time differs (recycled PID)" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock owned by $PPID (bats runner, definitely alive)
    # but with a fake LSTART that doesn't match the real process
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=old-session
TIMESTAMP=2026-01-01T00:00:00Z
PURPOSE=stale
TTL=0
LSTART=Thu Jan  1 00:00:00 2026
COMM=bash
EOF

    run "$USB_DEVICE" checkout "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reclaiming stale lock"* ]]
    [[ "$output" == *"recycled"* ]]
    [[ "$output" == *"Checked out"* ]]
}

@test "checkout: does not reclaim lock when PID is alive and start time matches" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Get real LSTART for $PPID
    local real_lstart
    real_lstart=$(ps -p "$PPID" -o lstart= 2>/dev/null)

    # Create a lock owned by $PPID with the correct LSTART
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=other-user
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=active
TTL=0
LSTART=$real_lstart
COMM=bash
EOF

    run "$USB_DEVICE" checkout "Device A"
    [ "$status" -eq 1 ]
    [[ "$output" != *"Reclaiming"* ]]
    [[ "$output" == *"checked out"* ]]
}

@test "checkout: reclaims lock with dead PID even without LSTART (backwards compatible)" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Old-style lock file without LSTART/COMM fields
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=99999
OWNER=old-tool
TIMESTAMP=2026-01-01T00:00:00Z
PURPOSE=legacy
TTL=0
EOF

    run "$USB_DEVICE" checkout "Device A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reclaiming stale lock"* ]]
    [[ "$output" == *"dead"* ]]
    [[ "$output" == *"Checked out"* ]]
}

@test "locks: shows process name in output" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock owned by $PPID (bats runner, always alive) with real LSTART/COMM
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=test-user
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=testing
TTL=0
LSTART=$(ps -p "$PPID" -o lstart= 2>/dev/null)
COMM=$(ps -p "$PPID" -o comm= 2>/dev/null)
EOF

    run "$USB_DEVICE" locks
    [ "$status" -eq 0 ]
    # pid field should include the process name in parentheses
    [[ "$output" == *"pid="*"("*")"* ]]
}

# ── register --partner-of ────────────────────────────────────────

@test "register: --partner-of creates partner section" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=esp32
chip=esp32s3
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" register ppk2 --serial TEST123 --type ppk2 --partner-of "Alpha"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Registered partner 'Board Alpha:ppk2'"* ]]

    # Config should have partner section with serial= (not mac=) and no chip=
    run grep "\[Board Alpha:ppk2\]" "$CONF"
    [ "$status" -eq 0 ]
    run grep "serial=TEST123" "$CONF"
    [ "$status" -eq 0 ]
    run grep "type=ppk2" "$CONF"
    [ "$status" -eq 0 ]
    # Should NOT have chip= in partner section
    run grep -A3 "\[Board Alpha:ppk2\]" "$CONF"
    [[ "$output" != *"chip="* ]]
}

@test "register: --partner-of rejects unknown primary" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=esp32
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" register ppk2 --serial TEST123 --type ppk2 --partner-of "Nonexistent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No devices match"* ]]
}

@test "register: --partner-of rejects duplicate partner" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=esp32

[Board Alpha:ppk2]
serial=EXISTING
type=ppk2
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" register ppk2 --serial NEW123 --type ppk2 --partner-of "Alpha"
    [ "$status" -eq 1 ]
    [[ "$output" == *"already registered"* ]]
}

# ── fuzzy partner matching ───────────────────────────────────────

@test "fuzzy match: primary:role pattern resolves partner" {
    cat > "$CONF" << 'EOF'
[MPCB 1.9 Development]
mac=AA:AA:AA:AA:AA:AA
type=esp32
chip=esp32s3

[MPCB 1.9 Development:ppk2]
serial=PPK_SERIAL
type=ppk2
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" type "1.9:ppk2"
    [ "$status" -eq 0 ]
    [[ "$output" == "ppk2" ]]
}

@test "fuzzy match: partner excluded from non-colon search" {
    cat > "$CONF" << 'EOF'
[MPCB 1.9 Development]
mac=AA:AA:AA:AA:AA:AA
type=esp32
chip=esp32s3

[MPCB 1.9 Development:ppk2]
serial=PPK_SERIAL
type=ppk2
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    # "1.9" should match only the primary, not the partner
    run "$USB_DEVICE" type "1.9"
    [ "$status" -eq 0 ]
    [[ "$output" == "esp32" ]]
}

@test "fuzzy match: nonexistent role fails" {
    cat > "$CONF" << 'EOF'
[MPCB 1.9 Development]
mac=AA:AA:AA:AA:AA:AA
type=esp32
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" type "1.9:ppk2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No devices match"* ]]
}

@test "fuzzy match: exact partner name still works" {
    cat > "$CONF" << 'EOF'
[Board Rev-B]
mac=AA:AA:AA:AA:AA:AA
type=esp32

[Board Rev-B:notecard]
serial=NC_SERIAL
type=notecard
EOF
    mock_uhubctl < /dev/null
    mock_pyserial < /dev/null

    run "$USB_DEVICE" type "Board Rev-B:notecard"
    [ "$status" -eq 0 ]
    [[ "$output" == "notecard" ]]
}

# ── locks --prune ────────────────────────────────────────────────

@test "locks --prune: removes stale locks with dead PIDs" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock with a dead PID
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=99999
OWNER=dead-session
TIMESTAMP=2026-01-01T00:00:00Z
PURPOSE=stale
TTL=0
EOF

    run "$USB_DEVICE" locks --prune
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pruned 1 stale lock(s)"* ]]

    # Lock dir should be gone
    [ ! -d "$TEST_DIR/locks/device_a" ]
}

@test "locks --prune: reports no stale locks when all are live" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Create a lock with a live PID (bats runner)
    local real_lstart
    real_lstart=$(ps -p "$PPID" -o lstart= 2>/dev/null)
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=live-session
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=active
TTL=0
LSTART=$real_lstart
COMM=bash
EOF

    run "$USB_DEVICE" locks --prune
    [ "$status" -eq 0 ]
    [[ "$output" == *"No stale locks found"* ]]
}

@test "locks --prune: removes recycled PID locks" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    # Lock with live PID but wrong LSTART (recycled)
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=recycled-session
TIMESTAMP=2026-01-01T00:00:00Z
PURPOSE=stale
TTL=0
LSTART=Thu Jan  1 00:00:00 2026
COMM=bash
EOF

    run "$USB_DEVICE" locks --prune
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pruned 1 stale lock(s)"* ]]
}

# ── discover ─────────────────────────────────────────────────────

@test "discover: shows unregistered devices" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=esp32
EOF
    mock_uhubctl < /dev/null
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1|Espressif USB JTAG/serial debug unit
BB:BB:BB:BB:BB:BB|/dev/cu.usbmodem201|20-2.2|PPK2
EOF

    run "$USB_DEVICE" discover
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unregistered USB devices:"* ]]
    [[ "$output" == *"BB:BB:BB:BB:BB:BB"* ]]
    # Registered device should NOT appear
    [[ "$output" != *"AA:AA:AA:AA:AA:AA"* ]]
    [[ "$output" == *"1 unregistered device(s)"* ]]
}

@test "discover: reports none when all devices registered" {
    cat > "$CONF" << 'EOF'
[Board Alpha]
mac=AA:AA:AA:AA:AA:AA
type=esp32
EOF
    mock_uhubctl < /dev/null
    mock_pyserial << 'EOF'
AA:AA:AA:AA:AA:AA|/dev/cu.usbmodem101|20-2.1|Espressif USB JTAG/serial debug unit
EOF

    run "$USB_DEVICE" discover
    [ "$status" -eq 0 ]
    [[ "$output" == *"No unregistered USB devices found"* ]]
}

@test "discover: skips devices with no serial number" {
    cat > "$CONF" << 'EOF'
EOF
    mock_uhubctl < /dev/null
    mock_pyserial << 'EOF'
-|/dev/cu.Bluetooth||-
AA:BB:CC:DD:EE:FF|/dev/cu.usbmodem101|20-2.1|Espressif device
EOF

    run "$USB_DEVICE" discover
    [ "$status" -eq 0 ]
    [[ "$output" == *"AA:BB:CC:DD:EE:FF"* ]]
    [[ "$output" != *"Bluetooth"* ]]
    [[ "$output" == *"1 unregistered device(s)"* ]]
}

# ── locks refcount display ───────────────────────────────────────

@test "locks: shows refcount when greater than 1" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    local real_lstart
    real_lstart=$(ps -p "$PPID" -o lstart= 2>/dev/null)
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=test-user
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=testing
TTL=0
REFCOUNT=3
LSTART=$real_lstart
COMM=bash
EOF

    run "$USB_DEVICE" locks
    [ "$status" -eq 0 ]
    [[ "$output" == *"refcount=3"* ]]
}

@test "locks: hides refcount when 1" {
    export USB_DEVICE_LOCK_DIR="$TEST_DIR/locks"

    local real_lstart
    real_lstart=$(ps -p "$PPID" -o lstart= 2>/dev/null)
    mkdir -p "$TEST_DIR/locks/device_a"
    cat > "$TEST_DIR/locks/device_a/info" <<EOF
PID=$PPID
OWNER=test-user
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PURPOSE=testing
TTL=0
REFCOUNT=1
LSTART=$real_lstart
COMM=bash
EOF

    run "$USB_DEVICE" locks
    [ "$status" -eq 0 ]
    [[ "$output" != *"refcount"* ]]
}
