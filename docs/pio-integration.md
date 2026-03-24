# PlatformIO Integration

## Shell Functions

Source `shell-integration.sh` from your shell profile:

```bash
source ~/e/usb-device/shell-integration.sh
```

This provides:

- **`piodev "1.10"`** — set PIO env vars for a device (no locking)
- **`piodevlock "1.10"`** — lock a device + set PIO env vars
- **`piodevlock --any "MPCB"`** — lock first available match
- **`piodevunlock`** — unlock all your devices + unset env vars

### What gets exported

`piodevlock` and `piodev` export:

| Variable | Description |
|---|---|
| `PIO_LABGRID_DEVICE` | Device name (for pio-labgrid reservation) |
| `PLATFORMIO_UPLOAD_PORT` | Bootloader port (PIO reads this for uploads) |
| `DEVICE_NAME` | Device name (for serial-monitor, scripts) |
| `DEVICE_PORT` | Runtime serial port |
| `DEVICE_BOOTLOADER_PORT` | Only exported when different from runtime port |

For devices where bootloader and runtime ports differ (e.g. TinyUSB devices),
set `bootloader_mac` in `devices.conf`:

```ini
[USB Insight Hub A1]
mac=B43A45B5582C
type=insight_hub
bootloader_mac=B4:3A:45:B5:58:2C
```

## PIO Aliases (.bashrc)

The `pioupload`, `piotest`, and `piomonitor` functions resolve ports per-invocation.
Last argument is always the device name:

```bash
pioupload -e esp32s3-idf 1.10       # build + upload (uses bootloader port)
piotest -e esp32s3-idf -v 1.10      # build + upload + test (bootloader + runtime ports)
piomonitor 1.10                      # serial monitor (runtime port)
```

These pass `--upload-port`, `--test-port`, and `--port` explicitly to PIO,
which is the most reliable method (avoids auto-detection issues when multiple
devices are connected, e.g. USB Insight Hub).

## pio-labgrid (Locking Only)

[pio-labgrid](https://github.com/m-mcgowan/pio-labgrid) is a PIO extra_script
that handles device **locking only** (not port management):

- **`pio run` (build only):** no lock acquired
- **`pio run -t upload` / `pio test`:** acquires lock, releases on exit
- **Lock failure aborts the build** — no silent continuation
- **`PIO_LABGRID_SKIP=1`** disables all reservation

Configuration:

```bash
export PIO_LABGRID_DEVICE="MPCB 1.10 Development"   # which device to lock
export LABGRID_COORDINATOR=ws://host:20408/ws         # optional: labgrid coordinator
```

Or in `platformio.ini`:

```ini
custom_labgrid_device = MPCB 1.10 Development
```

Port management is separate — use `piodevlock`, `piodev`, the PIO aliases,
or `run_tests.sh`.

## Typical Workflows

### Terminal session

```bash
piodevlock "1.10"                    # lock + set up env
pio run -t upload                    # uses PLATFORMIO_UPLOAD_PORT
./run_tests.sh                       # passes explicit ports
serial-monitor "$DEVICE_NAME"        # uses DEVICE_NAME
piodevunlock                         # release
```

### Quick upload (no locking)

```bash
pioupload -e esp32s3-idf 1.10       # resolves port per-call
```

### PIO port precedence

For `upload_port`:

| Priority | Source |
|---|---|
| 1 (highest) | `env["UPLOAD_PORT"]` set by extra_script in SCons |
| 2 | `PLATFORMIO_UPLOAD_PORT` shell env var |
| 3 | `upload_port` in platformio.ini |
| 4 | Auto-detection (unreliable with multiple devices) |

`test_port` and `monitor_port` have **no env var support** in PIO — they
must be set via CLI flags (`--test-port`, `-p`) or `platformio.ini`.

## Hardware Power and Reset

**MPCB 1.9 and earlier** — powered via USB:

```bash
usb-device reset "1.9"              # power-cycle USB port (wakes from sleep)
usb-device off "1.9"                # cut USB power
usb-device on "1.9"                 # restore USB power
```

**MPCB 1.10 and later** — NOT powered via USB (always has battery or external power):

- If awake: `usb-device reset "1.10"` resets via USB CDC (1200 baud touch)
- If asleep on battery with no USB power source: **physical reset button is the only option**
- Workshop 1.10 device: powered by a Nordic PPK2 (`~/e/ppk2-python`) which can be power-cycled

## Device Properties

Custom fields in `~/.config/usb-devices/devices.conf` are readable via `usb-device field`:

```ini
[MPCB 1.10 Development]
mac=B8:F8:62:C5:FC:D4
type=esp32
chip=esp32s3
notecard_uid=dev:860322068097069
```

```bash
usb-device field "1.10" notecard_uid    # → dev:860322068097069
usb-device field "1.10" chip            # → esp32s3
usb-device port "1.10"                  # → /dev/cu.usbmodem...
usb-device port --bootloader "1.10"     # → bootloader port (falls back to runtime)
```
