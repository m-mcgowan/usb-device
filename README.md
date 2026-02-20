# USB Device Management

Scripts for managing named USB devices: power cycling, serial monitoring, bootloader entry, and persistent device tracking across reconnects and sleep cycles.

Board-specific commands (bootloader, boot) are provided by type plugins — the core is board-agnostic.

## Quick Start

```bash
# First-time setup (installs deps, configures PATH, installs git hooks)
scripts/usb-devices/setup.sh

# Register your devices (MAC from pyserial serial_number / pio device list)
nano ~/.config/usb-devices/devices.conf
```

## usb-device

Manage named USB devices via uhubctl and pyserial. Device names support fuzzy matching (exact, substring, or regex).

```bash
usb-device list                    # show all registered devices and their status
usb-device scan                    # scan bus, update last-known locations
usb-device check                   # verify all dependencies are installed
usb-device find "1.9"              # show hub/port/serial info + supported commands
usb-device type "1.9"              # print device type (for scripting)
usb-device port "1.9"              # print /dev/cu.* path (for scripts)
usb-device reset "1.9"             # power-cycle (escalates port → hub)
usb-device reset -f "1.9"          # force (skip hub confirmation)
usb-device off "1.9"               # turn off power
usb-device on "1.9"                # turn on power
usb-device bootloader "1.9"        # enter bootloader (requires type plugin)
usb-device boot "1.9"              # exit bootloader (requires type plugin)
usb-device checkout "1.9"          # acquire exclusive access
usb-device checkin "1.9"           # release exclusive access
usb-device locks                   # show all checked-out devices
```

### Chained commands

Put the device name first, then chain commands:

```bash
usb-device "1.9" reset bootloader    # power-cycle then enter bootloader
usb-device "1.9" off                 # same as: usb-device off "1.9"
```

### Device discovery

`scan` discovers devices by cross-referencing the registered MAC addresses in `devices.conf` with:

1. **uhubctl** — finds devices directly on power-switchable USB hub ports
2. **pyserial** — finds devices by MAC on any USB port, using the LOCATION field to map devices behind sub-hubs back to the nearest controllable port

Results are saved to `~/.config/usb-devices/locations.json`. This lets `find`, `list`, and `reset` work even when a device is sleeping or disconnected.

### Reset escalation

When `reset` is called:

1. **Port-level** — power-cycles just the device's port, waits up to 10s for re-enumeration
2. **Hub-level** — if the device doesn't come back, escalates to cycling the entire hub. Warns about other devices on the same hub and prompts for confirmation (use `-f` to skip)

### Device locking

Exclusive access for CI jobs and manual use:

```bash
usb-device checkout "1.9"                           # acquire lock
usb-device checkout --wait --timeout 60 "1.9"       # wait up to 60s
usb-device checkout --owner ci-job --purpose "PR 42" --ttl 600 "1.9"
usb-device checkin "1.9"                             # release
usb-device checkin -f "1.9"                          # force release
usb-device locks                                     # list all locks
```

Locks are advisory — mutating commands (`reset`, `off`, `on`, `bootloader`, `boot`) warn if a device is checked out by another process. Stale locks auto-reclaim via PID liveness and TTL expiry.

### USB Insight Hub integration

Keep the [USB Insight Hub](https://www.crowdsupply.com/aerio-solutions/usb-insight-hub) displays updated with device names and connection status. Auto-detects the hub on the bus.

```bash
usb-device hub status              # show hub info and channel assignments
usb-device hub sync                # one-shot: push device names to displays
usb-device hub watch               # daemon: update displays on connect/disconnect
usb-device hub install             # install as macOS LaunchAgent (auto-start on login)
usb-device hub uninstall           # remove LaunchAgent
usb-device hub log                 # tail the agent log file
```

Devices on the hub's 3 ports (CH1-CH3) are auto-mapped by USB topology. Connected devices show in GREEN, bootloader in ORANGE, disconnected in RED.

#### Background service

Install as a LaunchAgent to keep displays updated automatically:

```bash
usb-device hub install             # installs and starts immediately
```

The agent auto-detects the hub, reconnects if it's unplugged and replugged, and waits patiently if the hub isn't connected yet. Logs go to `~/Library/Logs/hub-agent.log`. The `setup.sh` script offers to install this during first-time setup.

#### Display names

By default the device name from `devices.conf` is truncated to 14 chars. Override with `hub_name=`:

```ini
[MPCB 1.9 Development]
mac=B8:F8:62:D2:2A:FC
type=esp32
hub_name=1.9 Dev
```

#### Manual hub config

The hub is auto-detected by its USB product string. To override:

```ini
[hub:insight]
port=/dev/cu.usbmodemXXXX
location=20-3.3
```

### Use with PlatformIO

```bash
pio run -t upload --upload-port $(usb-device port "1.9")
pio test -e esp32s3-idf --upload-port $(usb-device port "1.9")
```

## serial-monitor

Serial monitor with device reset and bootloader support. Designed for both interactive (TTY) and non-interactive (scripts, CI) use.

```bash
serial-monitor "1.9"                          # monitor by device name
serial-monitor "1.9" -b 115200               # custom baud rate
serial-monitor "1.9" --timeout 30            # capture for 30s then exit
serial-monitor "1.9" --reset                 # 1200 baud touch reset first
serial-monitor "1.9" --bootloader            # enter bootloader (RTS/DTR)
serial-monitor "1.9" --boot                  # exit bootloader first
serial-monitor "1.9" --power-reset           # uhubctl power cycle first
serial-monitor "1.9" --send T --timeout 10   # send 'T' then capture 10s
serial-monitor "1.9" --send '@2xT' --send '@5xa' --timeout 60
                                              # send with delays
```

### Non-interactive mode (no TTY)

- Serial data goes to stdout, status messages to stderr
- Stops cleanly on SIGINT, SIGTERM, or `--timeout`
- Always use `--timeout` to avoid hanging

### Interactive keys (TTY)

| Key | Action |
|------|--------|
| Ctrl-R | Reset device (1200 baud touch) |
| Ctrl-B | Enter bootloader (RTS/DTR) |
| Ctrl-T | Toggle timestamps |
| Ctrl-C | Quit |

### --send syntax

Send data to the serial port after connecting. Use `\n` for newline. Prefix with `@SECSx` to delay:

- `--send T` — send `T` after 0.5s default delay
- `--send '@2xT'` — send `T` after 2 second delay
- `--send '@0.5xhello\n'` — send `hello\n` after 0.5s delay

Multiple `--send` flags are processed sequentially, delays are relative to the previous send.

## Setup

### Dependencies

| Tool | Purpose | Install |
|------|---------|---------|
| uhubctl | USB hub port power control | `brew install uhubctl` |
| pyserial | Serial port enumeration | Included in PlatformIO venv |
| jq | JSON processing for location DB | `brew install jq` |

Type-specific dependencies (e.g. esptool for ESP32) are checked by `usb-device check` based on registered device types.

### Configuration

User config lives outside the repo:

| File | Purpose |
|------|---------|
| `~/.config/usb-devices/devices.conf` | Device registry |
| `~/.config/usb-devices/locations.json` | Last-known hub/port locations (auto-updated by scan) |
| `~/.config/usb-devices/types.d/` | Custom type plugins (override or extend shipped plugins) |

### Device registration

Simple flat format (type defaults to `generic`):

```ini
My Device=B8:F8:62:D2:2A:FC
```

INI-style sections with explicit type:

```ini
[MPCB 1.9 Development]
mac=B8:F8:62:D2:2A:FC
type=esp32
chip=esp32s3

[PPK2 Dev]
serial=C9F6358AC307
type=ppk2

[Charger Port A]
location=20-2.3
type=power
```

Both formats can be mixed in the same file.

### Device types

| Type | Identification | Extra commands (via plugin) |
|------|---------------|---------------------------|
| `generic` (default) | `mac=` or `serial=` | — |
| `esp32` | `mac=` or `serial=` | bootloader, boot |
| `ppk2` | `serial=` (Nordic serial number) | — |
| `power` | `location=` (static USB topology) | — |

All types support the core commands: find, type, port, reset, on, off, checkout, checkin.

### Identification fields

| Field | When to use | Example |
|-------|-------------|---------|
| `mac=` | ESP32 boards (chip MAC from pyserial) | `B8:F8:62:D2:2A:FC` |
| `serial=` | Non-ESP32 devices (pyserial serial_number) | `C9F6358AC307` |
| `location=` | Dumb USB power ports with no serial identity | `20-2.3` |
| `chip=` | Board variant (passed to type plugin) | `esp32s3`, `esp32c3` |
| `hub_name=` | Display name on Insight Hub (max 14 chars) | `1.9 Dev` |

`mac` and `serial` are synonyms — both match against pyserial's `serial_number` field.

Find a device's serial number:

```bash
pio device list --json-output   # look for SER= field in hwid
```

## Type Plugins

Type plugins add board-specific commands (bootloader, boot, etc.) to the core tool.

### Plugin locations

Plugins are discovered in order (first match wins):

1. `<script-dir>/types.d/<type>.sh` — shipped with the tool
2. `~/.config/usb-devices/types.d/<type>.sh` — user overrides

### Writing a plugin

Create `types.d/<typename>.sh` with functions named `type_<typename>_<action>`:

```bash
# types.d/myboard.sh

# Advertise supported commands
type_myboard_commands() {
    echo "bootloader boot"
}

# Validate dependencies. Print [ok]/[FAIL] lines, return failure count.
type_myboard_check() {
    if command -v mytool &>/dev/null; then
        echo "[ok] mytool found"
        return 0
    else
        echo "[FAIL] mytool not found"
        return 1
    fi
}

# Enter bootloader. Args: $1=serial_port $2=device_name
# Globals: RESOLVED_CHIP (from chip= config, may be empty)
type_myboard_bootloader() {
    echo "Entering bootloader on $2 ($1)..."
    mytool --port "$1" enter-bootloader
}

# Exit bootloader. Args: $1=serial_port $2=device_name
type_myboard_boot() {
    echo "Booting $2 ($1)..."
    mytool --port "$1" reset
}
```

Only define the functions your type supports. Missing functions = command not available for that type.

### Git hooks

`setup.sh` installs post-merge, post-checkout, and post-rewrite hooks that automatically re-run setup when these scripts change. Uses checksum-based dedup to avoid redundant runs.

## Future Improvements

- **`usb-device pio upload/test/monitor`** — PlatformIO wrappers that accept friendly device names instead of port paths. Auto-detect app name from the project directory or ELF file being uploaded, and push it to the Insight Hub display.
- **Serial identity protocol** — lightweight probe over serial (e.g. send `\x01`, firmware responds with `{"app":"simple_publish","ver":"1.2.3"}`). Hub agent probes on connect and displays app name + version. Implemented as a shared library across firmware projects.
- **Insight Hub official agent** — adopt the official macOS Enumeration Extraction Agent when available, or customize the open-source hub firmware (CC BY-SA 4.0) for deeper integration.
- **Device state detection** — detect sleep and power-off states for display on the hub (bootloader detection is already implemented via ESP32 SYNC probe).

## Tests

```bash
# All tests
bats scripts/usb-devices/test/

# Basic tests (real environment)
bats scripts/usb-devices/test/usb-device.bats

# Mock tests (simulated devices, no hardware needed)
bats scripts/usb-devices/test/usb-device-mock.bats
```

Requires [bats-core](https://github.com/bats-core/bats-core): `brew install bats-core`

## Design

See [DESIGN.md](DESIGN.md) for technical details: event loop, IOKit bridge, channel mapping, bootloader detection, type plugin system, and file layout.
