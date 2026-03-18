# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# USB Insight Hub type plugin for usb-device
#
# Provides bootloader entry/exit for the Insight Hub.
# The Hub uses USB-OTG (TinyUSB) for its CDC serial API. Bootloader entry is
# via 1200-baud touch (after enabling reboot via the JSON serial API). The ROM
# bootloader then enumerates on USB Serial JTAG.
#
# Config fields:
#   type=insight_hub
#   chip=esp32s3

type_insight_hub_commands() {
    echo "bootloader boot restart"
}

type_insight_hub_check() {
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
    if $PYTHON -c "import serial" &>/dev/null; then
        echo "[ok] pyserial (for 1200-baud bootloader entry)"
    else
        echo "[FAIL] pyserial not found"
        fail=$((fail + 1))
    fi
    return $fail
}

# Enter ROM bootloader via 1200-baud touch.
# The Hub requires reboot_enabled=1 via JSON serial API first, then a
# 1200-baud line coding change triggers FORCE_DOWNLOAD_BOOT.
# After reset, the Hub enumerates on USB Serial JTAG (same MAC, colon-separated).
# Args: $1=serial_port $2=device_name
type_insight_hub_bootloader() {
    local serial_port="$1" name="$2"

    echo "Entering ROM bootloader on '$name' ($serial_port)..."
    local bl_port
    bl_port=$($PYTHON -c "
import json, serial, time, sys
from serial.tools.list_ports import comports

port = '$serial_port'

# Open serial and enable reboot
s = serial.Serial(port, 115200, timeout=2)
s.dtr = True
time.sleep(0.5)
s.reset_input_buffer()

def send(msg):
    payload = json.dumps(msg, separators=(',', ':')) + '\n'
    s.write(payload.encode())
    s.flush()
    return s.readline().decode('utf-8', errors='replace').strip()

resp = send({'action': 'set', 'params': {'reboot_enabled': 1}})
if 'ok' not in resp:
    print(f'Failed to enable reboot: {resp}', file=sys.stderr)
    sys.exit(1)

# Get the app serial number AND location for matching the bootloader port
app_serial = None
app_location = None
for p in comports():
    if p.device == port:
        app_serial = p.serial_number
        app_location = p.location
        break
print(f'App port: {port} location={app_location} serial={app_serial}', file=sys.stderr)

# Try dedicated bootloader command first, fall back to 1200-baud touch
resp = send({'action': 'bootloader'})
print(f'bootloader response: {resp}', file=sys.stderr)
use_1200 = 'error' in resp or 'ok' not in resp
s.close()

if use_1200:
    print('Bootloader command not supported, falling back to 1200-baud touch', file=sys.stderr)
    time.sleep(0.3)
    s = serial.Serial(port, 1200)
    time.sleep(0.5)
    s.close()

# Wait for bootloader to enumerate — match by BOTH serial AND location
def normalize(sn):
    return (sn or '').replace(':', '').replace('-', '').lower()

norm_app = normalize(app_serial)
# Location prefix: e.g. '20-3.3.4' -> '20-3.3' (parent hub stays the same)
loc_prefix = '.'.join((app_location or '').split('.')[:-1]) if app_location else ''

deadline = time.monotonic() + 15.0
while time.monotonic() < deadline:
    time.sleep(0.5)
    for p in comports():
        if p.vid == 0x303A and p.product == 'USB JTAG/serial debug unit':
            if normalize(p.serial_number) != norm_app:
                continue
            # Verify location matches (same parent hub path)
            p_loc_prefix = '.'.join((p.location or '').split('.')[:-1])
            if loc_prefix and p_loc_prefix != loc_prefix:
                print(f'Skipping {p.device} location={p.location} (expected {loc_prefix}.*)', file=sys.stderr)
                continue
            print(f'Bootloader: {p.device} location={p.location} serial={p.serial_number}', file=sys.stderr)
            print(p.device)
            sys.exit(0)

print('Bootloader did not enumerate within 15s', file=sys.stderr)
# Show what IS on the bus for debugging
for p in comports():
    if p.vid:
        print(f'  {p.device} product={p.product!r} serial={p.serial_number!r} location={p.location!r}', file=sys.stderr)
sys.exit(1)
" 2>&1)

    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "$bl_port" >&2  # error message from Python
        return 1
    fi

    echo "Bootloader active on $bl_port"
    echo "$bl_port"
}

# Exit bootloader: clear FORCE_DOWNLOAD_BOOT and hard-reset into application.
# Args: $1=serial_port $2=device_name
# Note: $1 here is the APP serial port. If the device is in bootloader,
# we need to find the bootloader port by MAC.
type_insight_hub_boot() {
    local serial_port="$1" name="$2"
    local chip="${RESOLVED_CHIP:-esp32s3}"
    local esptool
    esptool=$(_esp32_find_esptool) || die "esptool not found"

    # Find the actual bootloader port (device may be in bootloader mode)
    local bl_port
    bl_port=$($PYTHON -c "
from serial.tools.list_ports import comports
import sys

# Try to find the app port first — if it exists, device is already booted
for p in comports():
    if p.device == '$serial_port':
        if p.product == 'InsightHUB Controller':
            print('already_booted')
            sys.exit(0)
        # If the app port exists but is a bootloader, use it
        print(p.device)
        sys.exit(0)

# App port not found — look for bootloader port by MAC
# The app MAC (without colons) should match the bootloader MAC (with colons)
app_mac = '$RESOLVED_MAC'.replace(':', '').replace('-', '').lower()
for p in comports():
    if p.vid == 0x303A and p.product == 'USB JTAG/serial debug unit':
        bl_mac = (p.serial_number or '').replace(':', '').replace('-', '').lower()
        if bl_mac == app_mac:
            print(p.device)
            sys.exit(0)

print('not_found', file=sys.stderr)
sys.exit(1)
" 2>&1)

    if [ "$bl_port" = "already_booted" ]; then
        echo "'$name' is already running application firmware."
        return 0
    fi

    if [ -z "$bl_port" ] || [ "$bl_port" = "not_found" ]; then
        echo "Could not find bootloader port for '$name'" >&2
        return 1
    fi

    echo "Clearing FORCE_DOWNLOAD_BOOT and resetting '$name' ($bl_port)..."
    $esptool --chip "$chip" --port "$bl_port" --before no_reset --no-stub \
        --after hard_reset write_mem 0x6000812C 0x0 0x1

    # Wait for application to come up
    echo "Waiting for application to boot..."
    local attempts=0
    while [ $attempts -lt 20 ]; do
        sleep 1
        if $PYTHON -c "
from serial.tools.list_ports import comports
for p in comports():
    if p.vid == 0x303A and p.product == 'InsightHUB Controller':
        mac = (p.serial_number or '').replace(':', '').replace('-', '').lower()
        if mac == '$RESOLVED_MAC'.replace(':', '').replace('-', '').lower():
            print(p.device)
            exit(0)
exit(1)
" &>/dev/null; then
            echo "'$name' is back online."
            return 0
        fi
        attempts=$((attempts + 1))
    done

    echo "'$name' did not come back within 20s" >&2
    return 1
}

# Restart the Hub via serial API.
# Args: $1=serial_port $2=device_name
type_insight_hub_restart() {
    local serial_port="$1" name="$2"

    echo "Restarting '$name' via serial API ($serial_port)..."
    $PYTHON -c "
import json, serial, time, sys

port = '$serial_port'
s = serial.Serial(port, 115200, timeout=2)
s.dtr = True
time.sleep(0.5)
s.reset_input_buffer()

def send(msg):
    payload = json.dumps(msg, separators=(',', ':')) + '\n'
    s.write(payload.encode())
    s.flush()
    return s.readline().decode('utf-8', errors='replace').strip()

# Enable reboot first
resp = send({'action': 'set', 'params': {'reboot_enabled': 1}})
if 'ok' not in resp:
    print(f'Failed to enable reboot: {resp}', file=sys.stderr)
    sys.exit(1)

resp = send({'action': 'restart'})
if 'ok' not in resp:
    print(f'Restart failed: {resp}', file=sys.stderr)
    sys.exit(1)
print('Restart command sent.', file=sys.stderr)
s.close()
" 2>&1

    local rc=$?
    if [ $rc -ne 0 ]; then
        return 1
    fi

    # Wait for device to come back
    echo "Waiting for '$name' to restart..."
    local attempts=0
    while [ $attempts -lt 20 ]; do
        sleep 1
        local port
        port=$(find_serial_port "$RESOLVED_MAC")
        if [ -n "$port" ]; then
            local mode
            mode=$(detect_device_mode "$RESOLVED_MAC")
            if [ "$mode" = "app" ]; then
                echo "'$name' is back online."
                return 0
            fi
        fi
        attempts=$((attempts + 1))
    done

    echo "'$name' did not come back within 20s" >&2
    return 1
}

# ── Internal helpers (shared with esp32 plugin) ─────────────────

# Only define if not already loaded (esp32 plugin may have defined it)
if ! declare -f _esp32_find_esptool >/dev/null 2>&1; then
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
fi
