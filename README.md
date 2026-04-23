# usb-device

A CLI tool for managing named USB devices on macOS. Give your dev boards friendly names, then power-cycle, reset, flash, and monitor them without hunting for port paths or remembering uhubctl incantations.

## Why

If you work with multiple USB dev boards, you know the pain:

- **Ports change** every time you unplug and replug, or the board wakes from sleep
- **Power cycling** requires knowing the right uhubctl hub ID, port number, and flags
- **Bootloader entry** varies by board family (esptool, nrfutil, etc.)
- **Which board is on which port?** Especially with identical-looking boards, you're guessing
- **CI needs exclusive access** but there's no coordination mechanism for shared hardware

`usb-device` solves all of this. Register your boards once by name, and everything just works — even after reconnects, sleep cycles, and hub topology changes.

## Features

- **Named devices** — fuzzy matching so `"Rev-A"` finds `"Board Rev-A"`
- **Persistent tracking** — `scan` remembers where devices were, so commands work even when boards are sleeping or disconnected
- **Power control** — `reset`, `on`, `off` with automatic port-to-hub escalation
- **Type plugins** — board-specific commands (bootloader, boot) via extensible shell plugins
- **Serial monitoring** — interactive and non-interactive, with device reset, delayed send, and timestamps
- **Device locking** — `checkout`/`checkin` for CI jobs with TTL, wait, and stale lock recovery
- **[USB Insight Hub](https://www.crowdsupply.com/aerio-solutions/usb-insight-hub) integration** — per-port power control via serial API (since uhubctl doesn't work on the Renesas hub), plus auto-updating displays with device names and connection status

### Tools at a glance

| Tool | Type | Purpose |
|------|------|---------|
| `usb-device` | CLI | Manage named USB devices — find, reset, power, lock |
| `serial-monitor` | CLI | Serial monitor with reset, bootloader, delayed send |
| `pioupload` | Script | Upload firmware to a named device via PlatformIO |
| `piotest` | Script | Build, upload, and run PIO tests on a named device |
| `piomonitor` | Script | PlatformIO serial monitor for a named device |
| `piosermon` | Script | serial-monitor wrapper for a named device |
| `piorun` | Script | Chain multiple PIO operations under one device lock |
| `piodev` | Shell fn | Set PIO env vars for a device (no locking) |
| `piodevlock` | Shell fn | Lock a device and set PIO env vars |
| `piodevunlock` | Shell fn | Unlock devices and unset env vars |

All tools resolve device names via `usb-device`, so fuzzy matching works everywhere.
Run any script with `--help` for usage details.

## Install

### Homebrew (recommended)

```bash
brew install m-mcgowan/tap/usb-device
```

This installs `usb-device`, `serial-monitor`, `hub-agent`, and all PlatformIO helper scripts (`pioupload`, `piotest`, `piomonitor`, `piosermon`, `piorun`) into your Homebrew bin directory.

### Script

```bash
curl -sSL https://raw.githubusercontent.com/m-mcgowan/usb-device/main/install.sh | bash
```

Installs to `~/.local/share/usb-device/` and symlinks `usb-device`, `serial-monitor`, `hub-agent` into `~/.local/bin/`. Add `~/.local/bin` to your PATH if it isn't already.

The PlatformIO helper scripts (`pioupload`, `piotest`, etc.) are not symlinked by the script installer — add the install directory to PATH for these:

```bash
export PATH="$HOME/.local/share/usb-device:$PATH"
```

### Clone

```bash
git clone https://github.com/m-mcgowan/usb-device.git
cd usb-device
./setup.sh
```

`setup.sh` adds the repo directory to PATH in your shell profile and sources `shell-integration.sh` for the PlatformIO shell functions (`piodevlock`, `piodev`, `piodevunlock`). All scripts are on PATH immediately after sourcing.

After installing, register your devices:

```bash
nano ~/.config/usb-devices/devices.conf
usb-device scan
usb-device list
```

## usb-device

Manage named USB devices via uhubctl and pyserial. Device names support fuzzy matching (exact, substring, or regex).

```bash
usb-device list                    # show all registered devices and their status
usb-device scan                    # scan bus, update last-known locations
usb-device check                   # verify all dependencies are installed
usb-device find "1.9"              # show hub/port/serial info + lock status
usb-device find --available "MPCB" # first connected+unlocked match
usb-device type "1.9"              # print device type (for scripting)
usb-device port "1.9"              # print /dev/cu.* path (for scripts)
usb-device reset "1.9"             # power-cycle (escalates port → hub)
usb-device reset -f "1.9"          # force (skip hub confirmation)
usb-device off "1.9"               # turn off power
usb-device on "1.9"                # turn on power
usb-device bootloader "1.9"        # enter bootloader (requires type plugin)
usb-device boot "1.9"              # exit bootloader (requires type plugin)
usb-device checkout "1.9"          # acquire exclusive access (owned by caller)
usb-device checkout --any "MPCB"   # first available matching device
usb-device checkin "1.9"           # release (only if you own it)
usb-device checkin --mine           # release all your locks
usb-device locks                   # show all checked-out devices
usb-device version                 # print version
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

1. **Insight Hub** — if the device is behind an Insight Hub, power-cycles via the serial API (verified), waits for re-enumeration
2. **Port-level** — otherwise, power-cycles just the device's port via uhubctl, waits up to 10s for re-enumeration
3. **Hub-level** — if the device doesn't come back, escalates to cycling the entire hub. Warns about other devices on the same hub and prompts for confirmation (use `-f` to skip)

### Device locking

Exclusive access for CI jobs and development sessions:

```bash
usb-device checkout "1.9"                           # acquire lock (owned by caller's PID)
usb-device checkout --any "MPCB"                    # first available matching device
usb-device checkout --wait --timeout 60 "1.9"       # wait up to 60s if busy
usb-device checkout --purpose "PR 42" --ttl 600 "1.9"  # with metadata
usb-device checkin "1.9"                             # release (only if you own it)
usb-device checkin --mine                            # release all your locks
usb-device checkin -f "1.9"                          # force release anyone's lock
usb-device locks                                     # list all locks
usb-device find --available "MPCB"                   # first connected+unlocked match
```

**Ownership**: Locks are owned by the caller's process (`$PPID`). Locks are re-entrant — checking out a device you already hold refreshes the lock instead of failing.

Child processes automatically inherit the lock. `piodevlock` and `checkout --export` set `USB_DEVICE_LOCK_PID` in the environment, so scripts like `pioupload` can re-enter the lock without any extra flags:

```bash
piodevlock 1.10         # lock + set env vars (including USB_DEVICE_LOCK_PID)
pioupload               # inherits lock — no device arg needed
piotest                  # same — re-enters the lock
piodevunlock             # release
```

To grant access to an unrelated process (different terminal, CI job), use `--shared` with a common `--owner`:

```bash
# Terminal A
usb-device checkout --owner "ci-job-42" "Device A"
# Terminal B
usb-device checkout --shared --owner "ci-job-42" "Device A"
```

Use `--pid PID` to delegate ownership to a specific process.

**Safety**: `checkin` only releases locks you own. Releasing another session's lock requires `-f`. Bare `checkin` with no args requires `--mine` to prevent accidental release-all.

**`--any`**: Finds the first available device matching a pattern, skipping locked and offline devices. Prints structured output (`DEVICE_NAME`, `DEVICE_PORT`, `DEVICE_TYPE`) to stdout for script consumption.

Locks are advisory — mutating commands (`reset`, `off`, `on`, `bootloader`, `boot`) warn if a device is checked out by another process. Stale locks auto-reclaim via PID liveness and TTL expiry.

### USB Insight Hub integration

The [USB Insight Hub](https://www.crowdsupply.com/aerio-solutions/usb-insight-hub) uses a Renesas uPD720210 hub chip that does **not** support standard USB power switching — `uhubctl` commands appear to succeed but have no effect on actual power. Real power control is handled by AP22653 switches driven by the hub's ESP32-S3 via a JSON serial API.

`usb-device` auto-detects when a device is behind an Insight Hub and routes `reset`, `on`, and `off` through the serial API instead of uhubctl. No configuration needed — detection is automatic.

#### Power control

```bash
usb-device reset "1.9"             # power-cycle via serial API, wait for re-enumeration
usb-device off "1.9"               # power off via serial API
usb-device on "1.9"                # power on via serial API
```

Power state is verified after each set command — the tool queries the hub to confirm the switch actually changed.

#### Direct hub control (insight_hub.py)

For low-level access, use `insight_hub.py` directly:

```bash
insight_hub.py detect                      # find hub, print serial port and location
insight_hub.py status                      # summary of all 3 channels
insight_hub.py power CH1 on                # power on channel 1
insight_hub.py power CH2 off               # power off channel 2
insight_hub.py cycle CH3                   # power cycle (off, 2s wait, on)
insight_hub.py cycle CH1 5                 # power cycle with 5s off time
insight_hub.py query CH1                   # full channel state (JSON)
insight_hub.py voltage CH2                 # read voltage (mV)
insight_hub.py current CH3                 # read current (mA)
insight_hub.py data CH1 off                # disable USB 2.0 data lines (force re-enumeration)
insight_hub.py set CH1 fwdLimit 500        # set any channel parameter
insight_hub.py get startUpmode             # read global parameters
insight_hub.py get CH1 CH2 CH3             # read multiple parameters
```

#### Display management

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

The agent auto-detects the hub, reconnects if it's unplugged and replugged, and waits patiently if the hub isn't connected yet. Logs go to `~/Library/Logs/hub-agent.log`.

#### Display names

By default the device name from `devices.conf` is truncated to 14 chars. Override with `hub_name=`:

```ini
[Board Rev-A]
mac=B8:F8:62:D2:2A:FC
type=esp32
hub_name=Rev-A Dev
```

#### Manual hub config

The hub is auto-detected by its USB product string. To override:

```ini
[hub:insight]
port=/dev/cu.usbmodemXXXX
location=20-3.3
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

## PlatformIO Workflow

Standalone scripts and shell functions for PlatformIO development with named USB devices. All resolve ports via `usb-device` so you never pass raw `/dev/cu.*` paths.

### Quick commands

Last argument is always the device name. All other arguments pass through to PlatformIO.

```bash
pioupload 1.10                        # build + upload
pioupload -e esp32s3-idf 1.10         # specific PIO environment
piotest -e esp32s3-idf -v 1.10        # build + upload + run tests
piomonitor 1.10                       # PlatformIO serial monitor
piosermon 1.10                        # serial-monitor (Ctrl-R reset, Ctrl-B bootloader)
```

Each script acquires a device lock for the duration, resolves the correct port (bootloader for uploads, runtime for monitoring), and logs output to `logs/`.

### Chaining operations

`piorun` holds a single lock across multiple operations:

```bash
piorun 1.10 upload monitor            # upload then monitor
piorun 1.10 upload test               # upload then test
piorun 1.10 -e esp32s3-idf upload monitor   # with PIO environment
```

Commands: `upload`, `test`, `monitor`, `sermon`.

### Shell functions

For interactive terminal sessions where you want PIO env vars set in your shell. Source `shell-integration.sh` from your shell profile (done automatically by `setup.sh`):

```bash
piodevlock "1.10"                     # lock device + export env vars
pio run -t upload                     # uses $PLATFORMIO_UPLOAD_PORT automatically
serial-monitor "$DEVICE_NAME"         # uses $DEVICE_NAME
piodevunlock                          # release lock + unset vars

piodev "1.10"                         # set env vars without locking
piodevlock --any "MPCB"              # lock first available match
```

Exported variables: `PLATFORMIO_UPLOAD_PORT`, `DEVICE_PORT`, `DEVICE_NAME`, `PIO_LABGRID_DEVICE`.

### Raw port access

For cases where you need the port path directly:

```bash
pio run -t upload --upload-port $(usb-device port --bootloader "1.9")
pio test --upload-port $(usb-device port --bootloader "1.9") --test-port $(usb-device port "1.9")
```

See [docs/pio-integration.md](docs/pio-integration.md) for advanced topics (pio-labgrid locking, port precedence, hardware power management).

## Configuration

### Dependencies

| Tool | Purpose | Install |
|------|---------|---------|
| uhubctl | USB hub port power control | `brew install uhubctl` |
| pyserial | Serial port enumeration | `pip3 install pyserial` |
| jq | JSON processing for location DB | `brew install jq` |

Type-specific dependencies (e.g. esptool for ESP32) are checked by `usb-device check` based on registered device types.

### Config files

User config lives in `~/.config/usb-devices/`:

| File | Purpose |
|------|---------|
| `devices.conf` | Device registry |
| `locations.json` | Last-known hub/port locations (auto-updated by scan) |
| `types.d/` | Custom type plugins (override or extend shipped plugins) |

### Device registration

Simple flat format (type defaults to `generic`):

```ini
My Device=B8:F8:62:D2:2A:FC
```

INI-style sections with explicit type:

```ini
[Board Rev-A]
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
| `hub_name=` | Display name on Insight Hub (max 14 chars) | `Rev-A Dev` |

`mac` and `serial` are synonyms — both match against pyserial's `serial_number` field.

Find a device's serial number:

```bash
pio device list --json-output   # look for SER= field in hwid
```

## Type Plugins

Type plugins add board-specific commands (bootloader, boot, etc.) to the core tool.

### Plugin locations

Plugins are discovered in order (first match wins):

1. `<install-dir>/types.d/<type>.sh` — shipped with the tool
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

## Tests

```bash
# All bats tests
bats test/

# Basic tests (real environment)
bats test/usb-device.bats

# Mock tests (simulated devices, no hardware needed)
bats test/usb-device-mock.bats

# Python unit tests (insight_hub.py)
.venv/bin/python3 -m pytest test/test_insight_hub.py -v
```

Requires [bats-core](https://github.com/bats-core/bats-core): `brew install bats-core`

## Design

See [DESIGN.md](DESIGN.md) for technical details: event loop, IOKit bridge, channel mapping, bootloader detection, type plugin system, and file layout.

## License

[MIT](LICENSE)
