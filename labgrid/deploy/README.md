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
place. The `USBDevice` resource type references a device by its name in
`devices.conf`:

```yaml
test-rig-1:
  USBDevice:
    device_name: "My Board Rev A"

test-rig-2:
  USBDevice:
    device_name: "My Board Rev B"
```

The file is gitignored — create it from `exporter.yaml.example` and customize
for your local devices. `setup.sh install` copies the template automatically.

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
labgrid-client -p test-rig-1 create
labgrid-client -p test-rig-1 add-match "*/test-rig-1/*"
```

Clients reserve and acquire places by name:

```bash
labgrid-client -p test-rig-1 acquire
# ... use the device ...
labgrid-client -p test-rig-1 release
```

## Adding Devices

1. Register the device with `usb-device`:
   ```bash
   usb-device register "My New Board" --mac AA:BB:CC:DD:EE:FF --type esp32
   ```

2. Add a group to `exporter.yaml`:
   ```yaml
   new-rig:
     USBDevice:
       device_name: "My New Board"
   ```

3. Restart the exporter and create the place:
   ```bash
   ./setup.sh stop && ./setup.sh start
   # or if using launchd:
   launchctl unload ~/Library/LaunchAgents/com.usb-device.labgrid-exporter.plist
   launchctl load ~/Library/LaunchAgents/com.usb-device.labgrid-exporter.plist
   ./setup.sh places
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
