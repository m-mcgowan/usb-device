# Device Query and JSON Output

## Problem

usb-device has grown into a device registry with arbitrary metadata (notecard_uid, pin assignments, etc.), but there's no way to query devices by properties or get structured output for tooling. Users need to find available devices with specific capabilities (e.g. "a board with a notecard") without building a custom query language.

## Design Boundary

usb-device is the **local device ops** layer. It handles USB discovery, power, bootloader, serial, and type plugins on a single machine.

For single-machine use cases, usb-device provides:
- JSON output on any command (`--json`)
- Simple `--with` filtering for common cases
- `--jq` filtering for advanced cases (jq is the query language, not a custom DSL)
- Pluggable output: human-readable TUI (default) or JSON

For distributed/team/CI use cases, **labgrid** is the registry and query layer. The existing labgrid exporter (`export.py`) bridges devices.conf into labgrid's tag-based filtering and multi-machine coordination. Non-USB transports (WiFi, BLE) are labgrid's domain.

usb-device intentionally stays limited here. Installing labgrid is the upgrade path.

## Architecture

### Output format layer

All commands that produce device output go through a format layer:
- **TUI (default):** Human-readable table/detail output (current behavior)
- **JSON (`--json`):** Machine-readable, suitable for piping to jq

`--json` is a global flag, not per-command. Any command that outputs device info respects it. When `--json` is active, all non-JSON output (headers, skip messages, progress) is suppressed.

### Query pipeline

```
devices.conf  ──→  device_query.py   ──→  jq filter  ──→  output formatter
                   (config + runtime       (--with or       (TUI or JSON)
                    + pyserial + locks)      --jq)
```

1. Python assembles the full device model (config fields + runtime state)
2. Optional jq filter reduces the set
3. Output formatter renders the result

`--with` is syntactic sugar that generates a jq expression internally. This means jq is a dependency for `--with` and `--jq`, but not for basic operation (`list`, `find`, `port`, etc. without filters).

### Bash/Python boundary

**Problem:** The bash `parse_config()` only extracts fixed fields into parallel arrays. Custom fields, partner grouping, and JSON assembly all need the richer model that Python `conf_parser.py` already provides. Additionally, the current bash layer spawns a separate Python process per device for serial port discovery (`find_serial_port()`) and bootloader detection (`detect_device_mode()`), which is slow for N devices.

**Solution:** A single Python helper (`device_query.py`) that does everything in one process:
1. Parses `devices.conf` via `conf_parser.py` (all fields, partner groups)
2. Enumerates serial ports once via `serial.tools.list_ports.comports()` and matches all devices
3. Detects bootloader state for connected devices (USB product string check)
4. Reads lock state from the lock directory (`/tmp/usb-device-locks/`)
5. Queries uhubctl for hub/port info
6. Applies jq filter if provided (via `subprocess.run(["jq", ...])`)
7. Outputs JSON to stdout

This replaces the N+1 Python subprocess pattern (N `find_serial_port` calls + N `detect_device_mode` calls + 1 query call) with a single Python invocation that handles config parsing, device enumeration, and runtime state collection together.

Bash remains the CLI entry point, argument parser, and dispatcher. For commands that need the device model (list, find with filters), it calls `device_query.py` once and consumes the JSON output. For simple commands that already work (port, reset, etc.), the existing bash flow is unchanged.

### Importing `conf_parser.py`

`conf_parser.py` currently lives inside the labgrid package (`labgrid/labgrid_usb_device/conf_parser.py`). Options for `device_query.py` to import it:
- **(a) Extract to shared location** (e.g. `lib/conf_parser.py`) — cleanest but requires updating labgrid package imports
- **(b) sys.path manipulation** — `device_query.py` adds `labgrid/` to path at import time. Simple, no restructuring.
- **(c) Inline the parsing** — duplicate the small parser. Avoids coupling but creates drift risk.

**Decision:** Option (b) for now. It's pragmatic and the coupling to the labgrid package path is acceptable since both live in the same repo. Extract to a shared `lib/` if the dependency becomes awkward.

## Changes

### 1. `--json` — Global JSON output flag

Any command that outputs device information supports `--json` to emit structured JSON instead of human-readable text. Commands affected: `list`, `find`, `checkout`, `checkin`, `locks`.

**JSON envelope:**
```json
{
  "_schema": 1,
  "devices": [
    {
      "name": "MPCB 1.9 Development",
      "type": "esp32",
      "chip": "esp32s3",
      "mac": "B8:F8:62:D2:2A:FC",
      "notecard_uid": "dev:xxxxxxxxxxxx",
      "notecard_i2c_sda": "5",
      "notecard_i2c_scl": "6",
      "connected": true,
      "available": true,
      "online": true,
      "locked": false,
      "port": "/dev/cu.usbmodem1234",
      "hub": "20-1.2",
      "hub_port": "3",
      "partners": {
        "ppk2": {
          "type": "ppk2",
          "serial": "C9F6358AC307",
          "connected": true,
          "available": true,
          "port": "/dev/cu.usbmodem5678"
        }
      }
    }
  ]
}
```

**Flat output (`--flat`, requires `--json`):**

Flattens partners into top-level entries with `role` and `partner_of` fields. `--flat` without `--json` is an error.

```json
{
  "_schema": 1,
  "devices": [
    {
      "name": "MPCB 1.9 Development",
      "type": "esp32",
      "chip": "esp32s3",
      "mac": "B8:F8:62:D2:2A:FC",
      "notecard_uid": "dev:xxxxxxxxxxxx",
      "connected": true,
      "available": true,
      "online": true,
      "locked": false,
      "port": "/dev/cu.usbmodem1234",
      "hub": "20-1.2",
      "hub_port": "3"
    },
    {
      "name": "MPCB 1.9 Development:ppk2",
      "role": "ppk2",
      "partner_of": "MPCB 1.9 Development",
      "type": "ppk2",
      "serial": "C9F6358AC307",
      "connected": true,
      "available": true,
      "port": "/dev/cu.usbmodem5678"
    }
  ]
}
```

**Runtime state fields:**
- `connected` — device is reachable. For serial-number devices: pyserial can enumerate them. For static-location devices (no MAC): hub port is powered on.
- `online` — connected and not in bootloader. For device types that cannot detect bootloader state, `online` equals `connected` (optimistic default).
- `available` — connected and not locked.
- `locked` — checkout lock is held
- `lock_owner`, `lock_purpose`, `lock_pid`, `lock_ttl`, `lock_since` — lock metadata (present only when locked). `lock_since` is the ISO 8601 timestamp when the lock was acquired.
- `port` — current /dev/cu.* path (null if not connected)
- `hub`, `hub_port` — USB hub location (null if not on uhubctl hub)
- All config fields from devices.conf flow through as-is

**Partner state:** Partners have their own `connected`, `available`, and `locked` fields. Partners can be independently locked (labgrid exporter checks out all group members).

**Empty results:** `list --json` returns `{"_schema": 1, "devices": []}`. `find --json` with no match returns the same and exits non-zero.

### 2. `--with` and `--jq` — Device filtering

#### `--with <field>[=<value>]` — Simple property filter

Syntactic sugar over jq. Stackable (AND logic). Case-sensitive value matching.

```bash
# Board with a notecard (has notecard_uid field)
usb-device find --available --with notecard_uid "MPCB"

# Board with specific chip
usb-device find --available --with chip=esp32s3 "MPCB"

# Board with notecard AND ppk2 partner
usb-device find --available --with notecard_uid --with partner:ppk2 "MPCB"
```

**Field resolution:**
- Bare field name (e.g. `notecard_uid`): checks field exists and is non-null on the primary device
- `partner:<role>` (e.g. `partner:ppk2`): checks `.partners.<role>` exists in the nested model. This is a **config-level check** — it confirms the partner is registered, not that it's currently connected. Use `--jq '.partners.ppk2.connected'` to filter on partner runtime state.
- `<field>=<value>`: exact case-sensitive value match on the primary device

**Translation to jq:** `--with notecard_uid --with chip=esp32s3 --with partner:ppk2` becomes:
```jq
select(.notecard_uid and .chip == "esp32s3" and .partners.ppk2)
```

#### `--jq <expr>` — Advanced jq filter

Passes a raw jq select expression. The expression receives each device object and should return truthy/falsy.

```bash
# Boards where notecard_i2c_sda is pin 5 or 21
usb-device find --available --jq '.notecard_i2c_sda == "5" or .notecard_i2c_sda == "21"'

# Boards with any partner that is connected
usb-device list --jq '.partners | to_entries | any(.value.connected)'
```

Output is rendered in the current output format (TUI by default, JSON if `--json`). jq is only used as a filter, not for output transformation.

`--with` and `--jq` can be combined (AND logic — `--with` filters run first).

**jq dependency:** Required only when `--with` or `--jq` is used. If jq is not installed, error message suggests `brew install jq`. Basic commands (`list`, `find`, `port`, etc.) never require jq.

### 3. Status flags on `find`

```bash
usb-device find --available "MPCB"    # connected + not locked (existing, unchanged)
usb-device find --connected "MPCB"    # present on USB (bootloader or running)
usb-device find --online "MPCB"       # connected + not in bootloader
```

`--available` implies `--connected`. `--online` implies `--connected`. These combine with `--with` and `--jq`.

### 4. `list` gains filtering

`list` currently shows all devices. It now also supports `--with`, `--jq`, `--available`, `--connected`, and `--online` to filter the displayed set.

```bash
# All available boards with notecards, human-readable
usb-device list --available --with notecard_uid

# Same, as JSON for CI
usb-device list --available --with notecard_uid --json

# Advanced: boards with specific pin config
usb-device list --jq '.notecard_i2c_sda == "5"' --json
```

## Implementation

### Python helper: `device_query.py`

New script at the repo root. Handles the full query pipeline in a single process:

1. Parse `devices.conf` via `conf_parser.py` (imported via sys.path from `labgrid/labgrid_usb_device/`)
2. Enumerate all serial ports once via `serial.tools.list_ports.comports()`
3. Match serial ports to devices by MAC/serial number
4. Check bootloader state via USB product string (for types that support it)
5. Read lock directory for lock state per device
6. Query uhubctl for hub/port info (single call, parse output for all devices)
7. Build the full JSON model (config + runtime state + partner grouping)
8. Apply jq filter if provided
9. Output JSON to stdout

**CLI interface:**
```bash
# Full model, no filter
python3 device_query.py --config ~/.config/usb-devices/devices.conf --lock-dir /tmp/usb-device-locks

# With jq filter
python3 device_query.py --config ... --jq 'select(.available and .notecard_uid)'

# Flat output
python3 device_query.py --config ... --flat
```

### Type defaults

`type` defaults to `"generic"` in both the bash `_flush_section()` and Python `conf_parser.py` parsers. The `register` command defaults to `"esp32"` but writes it explicitly to the config file. The JSON layer reflects whatever the parser returns — no additional defaulting.

### Bootloader detection for `online`

`detect_device_mode()` works for ESP32 types (distinctive USB product string in pyserial's `product` field). For types without bootloader detection, `online` defaults to the value of `connected`. Type plugins can opt into bootloader detection by implementing `type_<name>_detect_mode` (following the existing `type_<name>_reset` pattern).

### Existing `partners` command

The script header documents `usb-device partners "1.9"` but no `cmd_partners` exists. This is now superseded by `find --json "1.9"` which includes partner info in the output. Remove the stale header reference.

## Future Work (Not This Change)

### Near-term
- Per-device config files (`~/.config/usb-devices/devices.d/` — concatenated like a `.d` directory)
- Auto-populate labgrid place tags from devices.conf custom fields
- `checkout --json` for CI tooling
- Extract `conf_parser.py` to shared `lib/` if the sys.path approach becomes awkward

### Cross-platform support
usb-device is open source and should be accessible beyond macOS. The core CLI (pyserial, uhubctl, config parsing) already works on Linux — the macOS coupling is mostly in the hub agent (IOKit events, launchd service) and setup scripts (Homebrew).

- **Phase 0:** Document Linux compatibility, fix `/dev/cu.*` in help text to show platform-appropriate paths
- **Phase 1:** Platform-aware setup (detect apt/brew/pacman, systemd vs launchd)
- **Phase 2:** udev event module (`udev_usb.py`) as alternative to `iokit_usb.py`, systemd unit generation
- **Phase 3:** Windows support (if needed — USB Insight Hub project may drive this)

### Device-initiated state
Today all state flows one direction: usb-device polls for device state. Future work to support device-initiated state changes:

- **Sleep notifications:** Devices send a message over serial (protocol TBD) indicating they are about to sleep. A monitoring agent catches this and updates state (hub display, JSON model). The JSON model would gain a `state` field (e.g. `"running"`, `"sleeping"`, `"bootloader"`) alongside the boolean `connected`/`online` fields.
- **USB connection detection:** Investigate whether USB Insight Hub hardware can detect physical USB connection via jumper resistors (as distinct from device being powered/enumerated). Would enable a `"physically_connected"` state separate from `"enumerated"`.

### Insight Hub as infrastructure
The USB Insight Hub could evolve beyond display into a device management primitive:

- **Serial proxy:** Hub intercepts device serial connections, allowing multiple listeners to attach (monitoring agent, sleep detection, user terminal) while providing an alias serial device for regular clients (screen, minicom). This decouples monitoring from exclusive serial port access.
- **Remote monitoring:** Hub functions as a primitive remote monitor, reporting device state changes to the network.
- **Cross-platform agent:** Hub agent project moving toward feature-equivalent agents on macOS, Linux, and Windows (contribution in progress).

These are captured here as direction, not commitments.

## What This Does NOT Build

- Custom query language (jq is the query language)
- Non-USB transport support (labgrid domain)
- Distributed coordination (use labgrid)
- Config format migration
- Device-initiated state or serial proxy (future work)
