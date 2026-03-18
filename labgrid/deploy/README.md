# labgrid Coordinator & Exporter Deployment

Deploy a labgrid coordinator and exporter for shared hardware reservation across local developers and CI.

## Prerequisites

```bash
# Install labgrid (coordinator + client + exporter)
pip install labgrid

# Install the usb-device labgrid bridge (macOS USB discovery)
pip install -e path/to/usb-device/labgrid
```

## Environment Variables

The same `LABGRID_COORDINATOR` variable used by `pio-labgrid` clients also configures the exporter and CLI tools:

```bash
# Set once in your shell profile
export LABGRID_COORDINATOR=ws://COORDINATOR_HOST:20408/ws
```

## Setup

Create your local exporter config from the template:

```bash
cp exporter.yaml.example exporter.yaml
# Edit exporter.yaml with your device names (from devices.conf)
```

`exporter.yaml` is gitignored so local config won't be overwritten by pulls.

## Quick Start (manual)

```bash
# Set coordinator address (also used by pio-labgrid clients)
export LG_COORDINATOR=localhost:20408

# Terminal 1: start coordinator
labgrid-coordinator -l 0.0.0.0:20408

# Terminal 2: start exporter (uses usb-device-exporter, not stock labgrid-exporter)
python -m labgrid_usb_device.run_exporter -c $LG_COORDINATOR exporter.yaml

# Terminal 3: create a place and match it to the exported resource group
labgrid-client -p test-rig-1 create
labgrid-client -p test-rig-1 add-match "*/test-rig-1/*"

# Verify
labgrid-client resources
labgrid-client -p test-rig-1 show
```

**Important:** labgrid requires places to be explicitly created and matched to
resource groups. The exporter advertises resources; places give them a name that
clients can reserve and acquire.

## Install as macOS launchd Services

The `.plist` files are templates. Edit them to set correct paths before installing.

```bash
# Edit exporter.plist — update the exporter.yaml path and WorkingDirectory
vim exporter.plist

# Copy plists to LaunchAgents
cp coordinator.plist ~/Library/LaunchAgents/com.usb-device.labgrid-coordinator.plist
cp exporter.plist ~/Library/LaunchAgents/com.usb-device.labgrid-exporter.plist

# Load services (start immediately and on login)
launchctl load ~/Library/LaunchAgents/com.usb-device.labgrid-coordinator.plist
launchctl load ~/Library/LaunchAgents/com.usb-device.labgrid-exporter.plist
```

## Verify

From any machine that can reach the coordinator (e.g. via VPN or local network):

```bash
# List exported resources
labgrid-client resources

# List places
labgrid-client places

# Show reservations
labgrid-client reservations
```

## Managing Services

```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.usb-device.labgrid-coordinator.plist
launchctl unload ~/Library/LaunchAgents/com.usb-device.labgrid-exporter.plist

# View logs
tail -f /tmp/labgrid-coordinator.log
tail -f /tmp/labgrid-exporter.log

# Restart (unload + load)
launchctl unload ~/Library/LaunchAgents/com.usb-device.labgrid-exporter.plist
launchctl load ~/Library/LaunchAgents/com.usb-device.labgrid-exporter.plist
```

## Adding Devices

Edit `exporter.yaml` to add new device places. The exporter reads `devices.conf` to auto-discover each device and its partners (e.g. notecard, power profiler).

```yaml
my-new-rig:
  USBDevice:
    device_name: "My Device Name"
```

Then restart the exporter service.

## Configuration

### Coordinator

The coordinator is a lightweight WAMP router. It holds no state — it brokers messages between exporters and clients. Default port is 20408.

- Listens on `0.0.0.0` so it's reachable from other machines
- Auto-restarts on crash (`KeepAlive: true`)
- Logs to `/tmp/labgrid-coordinator.log`

### Exporter

The exporter advertises local devices to the coordinator. Use
`usb-device-exporter` (or `python -m labgrid_usb_device.run_exporter`) instead
of the stock `labgrid-exporter`. This registers the `USBDevice` resource type
with labgrid's export system so `exporter.yaml` can reference devices from
`devices.conf`.

On Linux, you can use the stock `labgrid-exporter` with native udev resources
(see below), or use `usb-device-exporter` if `usb-device` is installed.

- Connects to the coordinator on `localhost:20408` (assuming co-located)
- `USBDevice` resources are exported as passthrough (no ser2net or udev needed)
- Auto-restarts on crash when run as a launchd service

### Linux Exporters

For Linux machines (e.g. SBCs), use labgrid's native resources in `exporter.yaml`:

```yaml
my-linux-rig:
  USBSerialPort:
    match:
      ID_SERIAL_SHORT: "ABC123"
```

No bridge package needed — labgrid handles udev natively.
