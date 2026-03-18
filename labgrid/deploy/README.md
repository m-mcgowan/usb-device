# labgrid Coordinator & Exporter Deployment

Deploy a labgrid coordinator and exporter for shared hardware reservation
across local developers and CI.

## Architecture

```
Coordinator (gRPC, port 20408)
    |
    +-- Exporter (usb-device-exporter)
    |     Reads exporter.yaml, exports USBDevice resources
    |     from devices.conf to the coordinator
    |
    +-- Clients (labgrid-client, pio-labgrid)
          Reserve and acquire places to get exclusive
          access to devices
```

**Coordinator** — lightweight gRPC router. Holds place definitions and brokers
resource access between exporters and clients. Stateless (places are recreated
on startup by the setup script).

**Exporter** — runs on each machine with physical devices. Uses
`usb-device-exporter` (`python -m labgrid_usb_device.run_exporter`) instead of
the stock `labgrid-exporter`. This registers the `USBDevice` resource type so
`exporter.yaml` can reference devices from `devices.conf`.

**Places** — named reservation targets. Each place matches one or more resource
groups from the exporter. Places must be explicitly created and matched.

## Quick Start

```bash
cd path/to/usb-device/labgrid/deploy

# Install dependencies (creates venv, installs labgrid + bridge)
./setup.sh install

# Edit exporter.yaml with your device names from devices.conf
vim exporter.yaml

# Start coordinator + exporter, create places
./setup.sh start

# Verify
./setup.sh status
```

## Setup Script

`setup.sh` handles the full lifecycle:

| Command | Description |
|---------|-------------|
| `./setup.sh install` | Create venv, install labgrid + bridge, create exporter.yaml from template |
| `./setup.sh start` | Start coordinator + exporter, create places |
| `./setup.sh stop` | Stop coordinator + exporter |
| `./setup.sh status` | Show running processes, resources, and places |
| `./setup.sh places` | Create/update places from exporter.yaml |
| `./setup.sh launchd-install` | Install macOS launchd services (auto-start on login) |
| `./setup.sh launchd-uninstall` | Remove launchd services |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LG_COORDINATOR` | `localhost:20408` | Coordinator address (labgrid's native env var) |
| `LABGRID_COORDINATOR` | (none) | Used by `pio-labgrid` clients |
| `LABGRID_PORT` | `20408` | Override coordinator port in setup.sh |

labgrid 25.x uses `LG_COORDINATOR` as the default for `-x`/`-c` flags. Set
this in your shell profile so `labgrid-client` commands work without `-x`:

```bash
export LG_COORDINATOR=your-coordinator-host:20408
```

For `pio-labgrid` clients, also set:

```bash
export LABGRID_COORDINATOR=$LG_COORDINATOR
```

## Exporter Configuration

`exporter.yaml` defines resource groups. Each group name becomes a labgrid
place. Use descriptive names: `location-board-peripherals`.

```yaml
workshop-mpcb-1.10-ppk2-1:
  USBDevice:
    device_name: "MPCB 1.10 Development"

lab-mpcb-1.9-standalone-1:
  USBDevice:
    device_name: "MPCB 1.9 Development"
```

The file is gitignored — create it from `exporter.yaml.example` and customize
for your local devices. `setup.sh install` copies the template automatically.

## Fixture Metadata (Tags)

`fixtures.yaml` defines tags for each place. Tags describe the physical test
environment — things the firmware can't detect on its own. Clients can filter
places by tag (e.g. "give me a board with GPS sky access").

```yaml
workshop-mpcb-1.10-ppk2-1:
  board: mpcb-1.10
  chip: esp32s3
  gps_sky_access: "true"
  rfid_tag_id: "141041190395"
  rfid_has_temperature: "true"
  battery_connected: "false"
  power_source: ppk2
  power_source_mv: "3700"
```

Tags are applied to places by `setup.sh places` (or automatically during
`setup.sh start`). They're visible in `labgrid-client -p NAME show` and can
be used for filtering:

```bash
# Find places with GPS sky access
labgrid-client places --tag gps_sky_access=true

# Reserve any board with a specific capability
labgrid-client reserve board=mpcb-1.10 gps_sky_access=true
```

The file is gitignored — create it from `fixtures.yaml.example`. This replaces
the `~/.config/test-fixtures/*.json` files with centralized, coordinator-managed
metadata.

### Why usb-device-exporter?

The stock `labgrid-exporter` only handles built-in resource types (udev-backed
USB devices, serial ports via ser2net, etc.). `USBDevice` is a custom resource
type that represents a device managed by the `usb-device` tool.

`usb-device-exporter` is a thin wrapper (~10 lines) that registers `USBDevice`
in labgrid's export registry as a passthrough resource, then delegates to
labgrid's standard exporter. No ser2net or udev is needed — the resource is
exported as-is with its `device_name` parameter.

### Places and Matching

Places are created automatically by `setup.sh start` or `setup.sh places`.
For each group in `exporter.yaml`, the script creates a place with the same
name and a wildcard match:

```
labgrid-client -p workshop-mpcb-1.10-ppk2-1 create
labgrid-client -p workshop-mpcb-1.10-ppk2-1 add-match "*/workshop-mpcb-1.10-ppk2-1/*"
labgrid-client -p workshop-mpcb-1.10-ppk2-1 set-tags board=mpcb-1.10 gps_sky_access=true ...
```

Clients reserve and acquire places by name:

```bash
labgrid-client -p workshop-mpcb-1.10-ppk2-1 acquire
# ... use the device ...
labgrid-client -p workshop-mpcb-1.10-ppk2-1 release
```

Or by capability (tag matching):

```bash
labgrid-client reserve board=mpcb-1.10 gps_sky_access=true --wait
```

## Adding Devices

1. Register the device with `usb-device`:
   ```bash
   usb-device register "My New Board" --mac AA:BB:CC:DD:EE:FF --type esp32
   ```

2. Add a group to `exporter.yaml`:
   ```yaml
   lab-myboard-1:
     USBDevice:
       device_name: "My New Board"
   ```

3. Add fixture tags to `fixtures.yaml` (optional):
   ```yaml
   lab-myboard-1:
     board: myboard
     chip: esp32s3
     gps_sky_access: "true"
   ```

4. Restart and apply:
   ```bash
   ./setup.sh stop && ./setup.sh start
   ```

## Logs

```bash
tail -f /tmp/labgrid-coordinator.log
tail -f /tmp/labgrid-exporter.log
```

## Linux Exporters

For Linux machines (e.g. SBCs), you can either:

1. Install `usb-device` + bridge and use the same setup (recommended for
   consistency)
2. Use the stock `labgrid-exporter` with native udev resources:

```yaml
my-linux-rig:
  USBSerialPort:
    match:
      ID_SERIAL_SHORT: "ABC123"
    speed: 115200
```

Both approaches register resources with the same coordinator. Clients don't
need to know which exporter type is used.
