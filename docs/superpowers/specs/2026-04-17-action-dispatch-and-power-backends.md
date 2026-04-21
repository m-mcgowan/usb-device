# Action Dispatch and Power Backends

## Problem

usb-device has hardcoded power control logic: a fallback chain of uhubctl → Insight Hub auto-detection, with type plugins for board-specific actions (bootloader, boot). This doesn't scale:

- **PPK2 power control** requires a daemon and a different protocol, currently not integrated
- **Insight Hub detection** is baked into the core rather than being a plugin
- **A relay board** (upcoming hardware) will add another power backend
- **Power relationships** are implicit (Insight Hub auto-detected by topology, PPK2 by naming convention) rather than explicit config
- **Cross-platform** is blocked by macOS-specific assumptions scattered through the core

## Design Principles

1. **Core is simple and standalone** — registry, discovery, locking, port resolution, event dispatch
2. **Actions dispatch to backends** — the core doesn't know how to power-cycle anything; backends do
3. **Config is explicit** — power relationships are declared, not inferred (with an `auto` fallback for convenience)
4. **Hooks for extensibility** — connect/disconnect events, pre/post action hooks
5. **Integrations are separate** — PlatformIO, labgrid, CI scripts are consumers, not part of core

## Power Backend Architecture

### Config: explicit `power=` field

The `power=` field on a device declares how its power is controlled. It's a pointer to another device or backend, not a description of the mechanism.

```ini
[MPCB 1.10 Development]
mac=B8:F8:62:C5:FC:D4
type=esp32
chip=esp32s3
power=PPK2 Workshop

[MPCB 1.9 Development]
mac=B8:F8:62:D2:2A:FC
type=esp32
chip=esp32s3
power=USB Insight Hub A1        # auto-maps to channel by topology

[Board Rev-A]
mac=AA:BB:CC:DD:EE:FF
type=esp32
power=Relay Board:port3         # explicit channel on a multi-port device
```

Power backends (the devices being pointed at):

```ini
[PPK2 Workshop]
serial=E2794420999B
type=ppk2

[USB Insight Hub A1]
mac=B43A45B5582C
type=insight_hub
chip=esp32s3

[Relay Board]
serial=XXXX
type=relay
```

### How `power=` resolves

When `usb-device reset "1.10"` runs:

1. Look up `power=` field on "MPCB 1.10 Development" → `PPK2 Workshop`
2. Resolve "PPK2 Workshop" as a registered device with `type=ppk2`
3. Dispatch `reset` to the `ppk2` type plugin, passing the PPK2's port/serial and the target device context
4. The ppk2 plugin talks to the PPK2 daemon to power-cycle

### Channel resolution

Some power devices serve multiple ports (Insight Hub has 3 channels, relay board has N ports). Two syntaxes:

**Explicit channel:** `power=Relay Board:port3` — the channel is part of the config. Passed to the type plugin as-is.

**Auto-mapped channel:** `power=USB Insight Hub A1` (no channel specified) — the backend plugin uses USB topology to determine which channel the target device is on. This is what the Insight Hub does today, just moved from hardcoded core logic into the insight_hub type plugin.

This preserves today's Insight Hub UX (no channel config needed) while allowing explicit override when auto-detection isn't reliable.

### Partner API

Devices can have partners — related devices registered with a naming convention (`DeviceName:suffix`). The core provides a partner API so plugins don't each reinvent discovery:

```bash
# Find a specific partner by type suffix
usb-device partner "MPCB 1.10 Development" ppk2
# → MPCB 1.10 Development:ppk2     serial=E2794420999B  type=ppk2

# List all partners
usb-device partner "MPCB 1.10 Development" --all
# → MPCB 1.10 Development:ppk2     type=ppk2

# No partner found
usb-device partner "Board Rev-A" ppk2
# → (empty, exit 1)
```

The naming convention (`Name:suffix`) lives in core. Plugins query it — they don't parse device names themselves. This means existing configs like `MPCB 1.10 Development:ppk2` work without migration.

### When `power=` is not specified

When a device has no `power=` field, the system treats it as `power=auto`. The resolution order:

1. **Type plugin self-power** — if the device's own type plugin implements `reset` directly (e.g. soft-reset via serial), use it

2. **Partner lookup** — core calls `usb-device partner <target> <type>` for each power-capable type. For example, the ppk2 plugin is registered as power-capable, so core checks for `MPCB 1.10 Development:ppk2`. If found, dispatch with relationship=`partner`.

3. **Topology/heuristic scan** — call `can_power` on remaining power-capable devices with relationship=`auto`:
   - `insight_hub` plugin checks if the target is behind the hub by USB topology
   - `uhubctl` plugin checks if the target is on a switchable hub port

4. **Fail with guidance** — if no backend claims it:
   ```
   Cannot reset 'Board X': no power backend found.
   Add a power= field to devices.conf, e.g.:
     power=PPK2 Workshop
     power=USB Insight Hub A1
   See: usb-device help power
   ```

Explicit `power=` always wins and skips the auto chain entirely.

### Power dispatch context

When core dispatches a power action to a plugin, it provides context about how the relationship was resolved:

| Field | Description |
|-------|-------------|
| `POWER_DEVICE` | The power backend device name |
| `POWER_PORT` | The power backend's serial port |
| `POWER_CHANNEL` | Explicit channel from `power=Device:channel` (may be empty) |
| `POWER_RELATIONSHIP` | How resolved: `explicit`, `partner`, or `auto` |
| `TARGET_DEVICE` | The target device being power-controlled |
| `TARGET_PORT` | The target device's serial port |
| `TARGET_MAC` | The target device's MAC/serial |

This gives plugins enough context to make decisions. For example:

- **PPK2 plugin** with relationship=`explicit` or `partner`: proceed (the pairing is intentional)
- **Insight Hub plugin** with relationship=`auto` and no `POWER_CHANNEL`: auto-map channel from USB topology using `TARGET_MAC`
- **Insight Hub plugin** with `POWER_CHANNEL=CH2`: use that channel directly
- **uhubctl plugin** with relationship=`auto`: use target's hub/port from the location DB

## Action Dispatch (Generalizing Beyond Power)

### Two axes of dispatch

Actions have two orthogonal concerns:

| Axis | Examples | Determined by |
|------|----------|---------------|
| **Device type** | bootloader, boot, flash | `type=` field → type plugin |
| **Power backend** | reset, on, off, cycle | `power=` field → power device's type plugin |

`usb-device bootloader "1.10"` dispatches to the `esp32` type plugin (device type).
`usb-device reset "1.10"` dispatches to the `ppk2` type plugin (power backend).

Some actions may involve both: "enter bootloader" on some boards requires a specific power sequence. The type plugin orchestrates this — it can call the power backend as needed.

### Type plugin interface (extended)

Today's type plugin interface:

```bash
type_<name>_commands()      # list supported commands
type_<name>_check()         # verify dependencies
type_<name>_bootloader()    # enter bootloader
type_<name>_boot()          # exit bootloader
```

Extended with power backend methods:

```bash
type_<name>_power_commands()  # list power commands this type supports (reset, on, off)
type_<name>_reset()           # power cycle (as a power backend)
type_<name>_on()              # power on
type_<name>_off()             # power off
type_<name>_can_power()       # auto-detection: can this device manage power for a given target?
```

When a type plugin provides `power_commands`, it registers as a power backend. Core uses this to:
- Know which types to query during partner lookup (step 2 of auto resolution)
- Know which types to call `can_power` on during topology scan (step 3)

The dispatch context (see table above) is passed to power methods as environment variables, so plugins have full context without parsing arguments.

### Partner API beyond power

The partner mechanism is generic — it's not specific to power. A device could have partners for other purposes:

```ini
[MPCB 1.10 Development]
mac=B8:F8:62:C5:FC:D4
type=esp32

[MPCB 1.10 Development:ppk2]       # power partner
serial=E2794420999B
type=ppk2

[MPCB 1.10 Development:notecard]   # notecard partner (for provisioning, diagnostics)
serial=dev:860322068097069
type=notecard
```

```bash
usb-device partner "1.10" notecard
# → MPCB 1.10 Development:notecard  type=notecard
```

Type plugins for other purposes could use the same partner API. The core provides the lookup; plugins decide what to do with it.

## Core Daemon and Hooks

### Event-driven core

usb-device needs a daemon to watch USB topology changes (devices appearing/disappearing). This is the only OS-specific piece:

| Platform | Event source |
|----------|-------------|
| macOS | IOKit notifications |
| Linux | udev / inotify on /dev |
| Windows | WMI / SetupDi |

The daemon maintains the live device state and fires hooks on events.

### Hook system

Hooks are scripts or commands triggered by events. They can be configured per-device or globally:

**Per-device hooks** (in devices.conf):

```ini
[PPK2 Workshop]
serial=E2794420999B
type=ppk2
on_connect=ppk2-daemon start --serial $DEVICE_SERIAL
on_disconnect=ppk2-daemon stop --serial $DEVICE_SERIAL
```

**Global hooks** (in `~/.config/usb-devices/hooks.d/`):

```bash
# hooks.d/notify-connect.sh
# Runs for every device connect event
echo "Device $DEVICE_NAME connected on $DEVICE_PORT" | notify
```

### Hook events

| Event | When | Variables |
|-------|------|-----------|
| `on_connect` | Device appears on USB | DEVICE_NAME, DEVICE_PORT, DEVICE_TYPE, DEVICE_SERIAL |
| `on_disconnect` | Device disappears | DEVICE_NAME, DEVICE_SERIAL |
| `on_checkout` | Device locked | DEVICE_NAME, LOCK_OWNER, LOCK_PURPOSE |
| `on_checkin` | Device unlocked | DEVICE_NAME |
| `pre_reset` | Before power cycle | DEVICE_NAME |
| `post_reset` | After power cycle | DEVICE_NAME, DEVICE_PORT (new port after re-enumeration) |

### Example: PPK2 — partner discovery + hooks

The PPK2 integration requires no special support in core. Here's the full flow for `usb-device reset "1.10"` with no `power=` field configured:

1. Core checks `power=` on "MPCB 1.10 Development" → absent
2. Core checks self-power → esp32 plugin has no `reset` power method
3. Core iterates power-capable types. `ppk2` is registered (has `power_commands`).
   Core calls `usb-device partner "MPCB 1.10 Development" ppk2` → finds "MPCB 1.10 Development:ppk2"
4. Core dispatches `reset` to `ppk2` plugin with `POWER_RELATIONSHIP=partner`
5. PPK2 plugin calls `ppk2-daemon cycle` to power-cycle the DUT

If the PPK2 is later moved to a different board, the user adds `power=PPK2 Workshop` to the new target, and the partner convention is bypassed.

Components:

- **Type plugin** (`types.d/ppk2.sh`): implements `power_commands` (reset/on/off), talks to `ppk2-daemon` CLI
- **on_connect hook**: starts ppk2-daemon when the PPK2 appears on USB
- **on_disconnect hook**: stops ppk2-daemon when it disappears
- **Partner convention**: `DeviceName:ppk2` in the registry, discovered by core's partner API

usb-device core never mentions PPK2.

### Example: Insight Hub — topology auto-detection

Today, Insight Hub power control is hardcoded in core. With this architecture:

1. Core checks `power=` → `USB Insight Hub A1` (no channel)
2. Core resolves "USB Insight Hub A1" as type `insight_hub`
3. Core dispatches `reset` with `POWER_CHANNEL=` (empty) and `POWER_RELATIONSHIP=explicit`
4. Insight Hub plugin sees no channel, uses `TARGET_MAC` to map the target to a hub channel by USB topology (the same auto-detection logic, now in the plugin)
5. Plugin calls `insight_hub.py cycle CH2`

With explicit channel: `power=USB Insight Hub A1:CH2` → `POWER_CHANNEL=CH2`, plugin skips topology lookup.

Components:

- **Type plugin** (`types.d/insight_hub.sh`): implements power methods via `insight_hub.py` serial API. Implements `can_power` for auto-detection (relationship=`auto`) by checking USB topology.
- **on_connect hook** (optional): syncs display names, starts the display watch daemon
- **hub-agent** becomes a hook-launched daemon, not a core feature

### Example: uhubctl — fallback power backend

uhubctl isn't a "device" in the registry — it's a system tool. It serves as the power backend of last resort during auto-detection (step 3 of the resolution chain). It's implemented as a built-in plugin or a virtual type:

```bash
type_uhubctl_can_power() {
    # Check if the target is on a switchable USB hub port
    # Uses TARGET_MAC to look up hub/port from the location DB
    local hub port
    hub=$(_db_field "$TARGET_DEVICE" "hub")
    port=$(_db_field "$TARGET_DEVICE" "port")
    [ -n "$hub" ] && [ -n "$port" ] && uhubctl -l "$hub" -p "$port" -a status >/dev/null 2>&1
}

type_uhubctl_reset() {
    uhubctl -l "$hub" -p "$port" -a cycle
    # Wait for re-enumeration...
}
```

No registration, no config — it works for any device on a switchable hub port. It only runs during auto-detection when no explicit `power=` or partner is found.

## Separating Integrations

### PlatformIO

The pio-* scripts and shell functions become a separate installable integration:

```
usb-device/
├── core/            # registry, discovery, locking, actions, daemon
├── types.d/         # shipped type plugins
├── hooks.d/         # shipped hook examples
└── integrations/
    ├── platformio/  # pioupload, piotest, piomonitor, shell-integration.sh
    └── labgrid/     # exporter, driver, resource (already separated)
```

Integrations depend on `usb-device` CLI but are independently installable. They're not loaded by core.

### Cross-platform path

The refactoring naturally identifies the platform boundary:

- **Platform-specific**: daemon event source (IOKit/udev/WMI), daemon lifecycle (launchd/systemd/service)
- **Portable**: everything else (registry, config, locking, action dispatch, type plugins, hooks)

A Python core handles the portable parts. Platform-specific event sources are thin adapters. Type plugins could remain as shell scripts (simplest for users to write) or Python modules (for complex backends like PPK2/Insight Hub).

## Migration

This is an evolutionary change, not a rewrite:

1. **Add `power=` field and partner API** — `usb-device partner` command, `power=` field resolution, dispatch context. Fall back to current behavior when absent.
2. **Move Insight Hub logic into type plugin** — extract from core, preserve auto-detection via `can_power`
3. **Move uhubctl into a plugin** — extract from core, becomes the default auto-detection fallback
4. **Add PPK2 type plugin** — power methods + partner convention. First test of the partner API.
5. **Add hook system** — start with on_connect/on_disconnect, core daemon calls scripts
6. **Separate PlatformIO** — move to `integrations/platformio/`, update install paths
7. **Add relay board backend** — first test of multi-channel `power=Device:channel` syntax

Each step is independently shippable. Step 1 is the most impactful — it adds the partner API and power dispatch framework that everything else builds on.

## Open Questions

- **Plugin language**: Keep shell-only for type plugins, or also support Python plugins? PPK2 and Insight Hub are already Python. Shell plugins are easiest for users to write; Python plugins are more capable. Could support both (shell checked first, Python fallback).
- **Daemon protocol**: How do type plugins communicate with their daemons? The ppk2-daemon uses a CLI, insight_hub.py uses direct serial. A standard interface (CLI subcommands) keeps it simple.
- **Power field syntax**: `power=DeviceName` or `power=DeviceName:channel`. What about devices that need more config (voltage, current limit)? Those could be fields on the power device itself, not the reference.
- **Partner naming**: Is `Name:suffix` the right convention? Colons could conflict with MAC addresses in some contexts. Alternatives: `Name/suffix`, `Name.suffix`. Colon feels natural and hasn't caused issues so far.
- **Relay board**: The upcoming relay board will be the first test of this architecture with a new backend. Its type plugin needs: serial protocol, multi-channel support, and possibly bootloader control (if it manages boot pins too). Good validation of the `power=Device:channel` and dispatch context design.
