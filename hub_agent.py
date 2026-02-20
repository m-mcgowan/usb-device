# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# hub_agent.py — USB Insight Hub display agent
"""Keeps USB Insight Hub displays updated with device names and connection status.

Auto-detects the Insight Hub on the USB bus, maps registered devices to hub
channels (CH1-CH3), and pushes display updates via the hub's JSON serial API.

Usage (via usb-device hub):
    usb-device hub status       # show hub info and channel assignments
    usb-device hub sync         # one-shot push to displays
    usb-device hub watch        # continuous daemon mode

Or directly:
    hub-agent                   # watch mode (default)
    hub-agent --once            # sync once and exit
    hub-agent --status          # print status and exit
"""

import argparse
import json
import os
import re
import signal
import struct
import sys
import threading
import time

from serial.tools.list_ports import comports

# Insight Hub identification
INSIGHT_HUB_PRODUCT = "InsightHUB Controller"
INSIGHT_HUB_VID = 0x303A
INSIGHT_HUB_PID = 0x1001
CHANNELS = ["CH1", "CH2", "CH3"]
MAX_NAME_LEN = 14


def find_insight_hub():
    """Auto-detect the Insight Hub CDC serial port and hub location.

    Returns (serial_port, hub_location) or (None, None).
    The hub location is derived from the controller's USB location by stripping
    the last segment (the controller is port 4 on its own internal hub).
    """
    for p in comports():
        if p.product == INSIGHT_HUB_PRODUCT or (p.vid == INSIGHT_HUB_VID and p.pid == INSIGHT_HUB_PID):
            hub_location = None
            if p.location:
                # Location like "20-3.3.4" -> hub is "20-3.3"
                hub_location = p.location.rsplit(".", 1)[0] if "." in p.location else None
            return p.device, hub_location
    return None, None


def truncate(s, maxlen=MAX_NAME_LEN):
    """Truncate string to maxlen characters."""
    return s[:maxlen] if len(s) > maxlen else s


def parse_devices_conf(conf_path):
    """Parse devices.conf and return list of device dicts.

    Returns: [{"name": str, "serial_number": str, "type": str, "hub_name": str}, ...]
    """
    devices = []
    if not os.path.isfile(conf_path):
        return devices

    section = None
    sec = {}

    def flush():
        if not section:
            return
        if section.startswith("hub:"):
            return  # skip hub config sections
        serial_number = sec.get("mac") or sec.get("serial") or ""
        if not serial_number:
            return
        hub_name = sec.get("hub_name") or truncate(section)
        devices.append({
            "name": section,
            "serial_number": serial_number,
            "type": sec.get("type", "generic"),
            "hub_name": truncate(hub_name),
        })

    with open(conf_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^\[(.+)\]$", line)
            if m:
                flush()
                section = m.group(1)
                sec = {}
                continue
            if "=" in line:
                if section:
                    key, val = line.split("=", 1)
                    sec[key.strip()] = val.strip()
                else:
                    # Legacy flat format: NAME=MAC
                    name, mac = line.split("=", 1)
                    devices.append({
                        "name": name.strip(),
                        "serial_number": mac.strip(),
                        "type": "generic",
                        "hub_name": truncate(name.strip()),
                    })
    flush()
    return devices


def port_to_channel(device_location, hub_location):
    """Map a device's USB location to an Insight Hub channel.

    Returns "CH1", "CH2", "CH3", or None if not on this hub.
    """
    if not device_location or not hub_location:
        return None
    if not device_location.startswith(hub_location + "."):
        return None
    remainder = device_location[len(hub_location) + 1:]
    # First segment after hub prefix is the port number
    port_str = remainder.split(".")[0]
    try:
        port = int(port_str)
    except ValueError:
        return None
    if 1 <= port <= 3:
        return f"CH{port}"
    return None


def probe_bootloader(port_path, timeout=0.15):
    """Send an ESP32 ROM bootloader SYNC command and check for a response.

    Returns True if the device is in bootloader mode (~8ms).
    Returns False if running normally (~150ms, limited by timeout).
    """
    import serial as pyserial
    ESP_SYNC = 0x08
    sync_data = b"\x07\x07\x12\x20" + 32 * b"\x55"
    # Build SLIP-encoded frame: direction(1) + cmd(1) + size(2) + checksum(4) + data
    pkt = struct.pack("<BBHI", 0x00, ESP_SYNC, len(sync_data), 0) + sync_data
    frame = b"\xc0"
    for b in pkt:
        if b == 0xC0:
            frame += b"\xdb\xdc"
        elif b == 0xDB:
            frame += b"\xdb\xdd"
        else:
            frame += bytes([b])
    frame += b"\xc0"

    try:
        s = pyserial.Serial(port_path, 115200, timeout=timeout)
        s.reset_input_buffer()
        s.write(frame)
        s.flush()
        resp = s.read(100)
        s.close()
        return b"\xc0" in resp and len(resp) > 4
    except Exception:
        return False


class HubAgent:
    """Watch USB devices and sync names/status to Insight Hub displays.

    The hub clears display text after 4.5s of serial silence (hardcoded in
    firmware). We must re-push display state on every poll cycle to keep it
    visible. This also lets us show live device state changes.
    """

    def __init__(self, hub_serial_port, hub_location, devices, interval=2.0):
        self.hub_serial_port = hub_serial_port
        self.hub_location = hub_location
        self.devices = {d["serial_number"]: d for d in devices}
        self.interval = interval
        self._ser = None
        self._channel_display = {}  # CH -> display dict (what we last pushed)
        self._channel_serials = {}  # CH -> serial_number (for detecting arrivals)
        self._channel_states = {}   # CH -> last probed state
        self._hub_lost = False      # set by _send on serial errors
        self._usb_event = threading.Event()  # signaled by IOKit watcher
        self._usb_watcher = None
        self.running = False

    def _open_hub(self):
        """Open serial connection to Insight Hub."""
        import serial
        try:
            self._ser = serial.Serial(self.hub_serial_port, 115200, timeout=1)
            self._ser.dtr = True  # DTR must be asserted per API spec
            return True
        except serial.SerialException as e:
            print(f"[hub-agent] Cannot open {self.hub_serial_port}: {e}", file=sys.stderr)
            return False

    def _close_hub(self):
        if self._ser:
            try:
                self._ser.close()
            except Exception:
                pass
            self._ser = None

    def _send(self, msg):
        """Send JSON command to hub, return parsed response or None.

        Returns None on error. Sets self._hub_lost on serial errors so the
        main loop knows to reconnect.
        """
        if not self._ser or not self._ser.is_open:
            return None
        try:
            payload = json.dumps(msg, separators=(",", ":")) + "\n"
            self._ser.write(payload.encode())
            self._ser.flush()
            response_line = self._ser.readline().decode("utf-8", errors="replace").strip()
            if response_line:
                return json.loads(response_line)
        except json.JSONDecodeError as e:
            print(f"[hub-agent] JSON error: {e}", file=sys.stderr)
        except OSError as e:
            print(f"[hub-agent] Serial error: {e}", file=sys.stderr)
            self._hub_lost = True
        return None

    def _build_display(self, hub_name, state="running"):
        """Build the display dict for a channel.

        States: running, bootloader, sleeping, off, disconnected
        """
        color_map = {
            "running":      "GREEN",
            "bootloader":   "ORANGE",
            "sleeping":     "CYAN",
            "off":          "RED",
            "disconnected": "RED",
        }
        name_color = color_map.get(state, "GREEN")

        lines = {"T1": {"txt": truncate(hub_name), "color": name_color}}
        if state != "running":
            lines["T2"] = {"txt": state, "color": color_map.get(state, "DARKGREY")}

        return {"Dev1_name": lines, "numDev": "10", "usbType": "2"}

    def _push_channel(self, channel, display, log=True):
        """Push a display dict to a channel. Returns True on success."""
        msg = {"action": "set", "params": {channel: display}}
        result = self._send(msg)
        ok = result and result.get("status") == "ok"
        if log:
            name = display.get("Dev1_name", {}).get("T1", {}).get("txt", "?")
            color = display.get("Dev1_name", {}).get("T1", {}).get("color", "?")
            print(f"[hub-agent] {channel}: {name} ({color.lower()}) [{'ok' if ok else 'FAIL'}]", file=sys.stderr)
        return ok

    def _empty_display(self):
        return {"Dev1_name": {"T1": {"txt": "---", "color": "DARKGREY"}}, "numDev": "10", "usbType": "2"}

    def _probe_state(self, port_info, device_type):
        """Probe device state. Only checks bootloader for esp32 devices."""
        if not port_info or not port_info.device:
            return "sleeping"
        if device_type == "esp32" and probe_bootloader(port_info.device):
            return "bootloader"
        return "running"

    def _scan_channels(self):
        """Scan comports and build desired display state for all channels.

        Returns dict: {CH1: display_dict, CH2: display_dict, CH3: display_dict}

        Bootloader probing only happens when a device first appears on a
        channel (transition from absent to present). On subsequent polls the
        cached state is reused to avoid the ~150ms probe overhead and serial
        port contention.
        """
        channel_devices = {}
        for p in comports():
            if not p.serial_number or p.serial_number not in self.devices:
                continue
            channel = port_to_channel(p.location, self.hub_location)
            if channel:
                channel_devices[channel] = (p.serial_number, p)

        displays = {}
        for ch in CHANNELS:
            if ch in channel_devices:
                sn, p = channel_devices[ch]
                dev = self.devices[sn]
                prev_sn = self._channel_serials.get(ch)
                if sn != prev_sn:
                    # Device just appeared — probe its state
                    state = self._probe_state(p, dev.get("type", "generic"))
                    self._channel_states[ch] = state
                else:
                    state = self._channel_states.get(ch, "running")
                self._channel_serials[ch] = sn
                displays[ch] = self._build_display(dev["hub_name"], state)
            else:
                self._channel_serials.pop(ch, None)
                self._channel_states.pop(ch, None)
                displays[ch] = self._empty_display()

        return displays

    def refresh(self, log_changes_only=True):
        """Scan and push display state for all channels.

        Always pushes to keep the hub's activity timer alive.
        Only logs when state changes (unless log_changes_only=False).
        """
        desired = self._scan_channels()

        for ch in CHANNELS:
            display = desired[ch]
            changed = (display != self._channel_display.get(ch))
            self._push_channel(ch, display, log=(changed or not log_changes_only))
            self._channel_display[ch] = display

    def status(self):
        """Print hub status and channel assignments."""
        print(f"Insight Hub: {self.hub_serial_port}")
        print(f"Hub location: {self.hub_location}")
        print(f"Registered devices: {len(self.devices)}")
        print()

        channel_devices = {}
        for p in comports():
            if not p.serial_number:
                continue
            channel = port_to_channel(p.location, self.hub_location)
            if channel:
                dev = self.devices.get(p.serial_number)
                channel_devices[channel] = {
                    "serial_number": p.serial_number,
                    "device": p.device,
                    "name": dev["name"] if dev else p.description,
                    "hub_name": dev["hub_name"] if dev else truncate(p.description or "?"),
                    "registered": dev is not None,
                }

        for ch in CHANNELS:
            if ch in channel_devices:
                d = channel_devices[ch]
                reg = "" if d["registered"] else " (unregistered)"
                print(f"  {ch}: {d['name']}{reg}")
                print(f"       dev={d['device']}  hub_name={d['hub_name']}")
            else:
                print(f"  {ch}: (empty)")

    def _reconnect(self):
        """Close current connection and try to re-detect and reopen the hub.

        Updates hub_serial_port if the hub moved to a different port path.
        Returns True on success, False if hub not found.
        """
        self._close_hub()
        self._hub_lost = False
        self._channel_display.clear()
        self._channel_serials.clear()
        self._channel_states.clear()

        port, location = find_insight_hub()
        if not port or not location:
            return False

        self.hub_serial_port = port
        self.hub_location = location
        return self._open_hub()

    def stop(self, *_args):
        self.running = False

    def _start_usb_watcher(self):
        """Start IOKit USB event watcher if available."""
        try:
            from iokit_usb import USBWatcher
            self._usb_watcher = USBWatcher(on_event=self._on_usb_event)
            self._usb_watcher.start()
            return True
        except (ImportError, OSError):
            return False

    def _stop_usb_watcher(self):
        if self._usb_watcher:
            self._usb_watcher.stop()
            self._usb_watcher = None

    def _on_usb_event(self):
        """Called from IOKit background thread on USB device add/remove."""
        self._usb_event.set()

    def run(self, once=False):
        """Main loop. If once=True, sync once and exit."""
        if not self._open_hub():
            if once:
                sys.exit(1)
            # Daemon mode: fall through to reconnect loop below
            self._hub_lost = True

        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGTERM, self.stop)

        try:
            if once:
                self.refresh(log_changes_only=False)
                return

            self.running = True
            has_iokit = self._start_usb_watcher()
            if has_iokit:
                print("[hub-agent] Using IOKit USB events.", file=sys.stderr)

            if not self._hub_lost:
                self.refresh(log_changes_only=False)
            print(f"[hub-agent] Watching (keepalive every {self.interval}s, Ctrl-C to stop)...", file=sys.stderr)

            while self.running:
                # Wait for IOKit event or keepalive timeout (whichever first)
                triggered = self._usb_event.wait(timeout=self.interval)
                self._usb_event.clear()

                if not self.running:
                    break

                if self._hub_lost:
                    if self._reconnect():
                        print("[hub-agent] Reconnected to Insight Hub.", file=sys.stderr)
                        self.refresh(log_changes_only=False)
                    continue

                if triggered:
                    # IOKit event: device changed. Brief delay for USB
                    # enumeration to settle before scanning comports.
                    time.sleep(0.5)
                    # Drain any additional events that fired during settle
                    self._usb_event.clear()

                self.refresh(log_changes_only=not triggered)
        finally:
            self._stop_usb_watcher()
            self._close_hub()


LAUNCHD_LABEL = "com.usb-devices.hub-agent"
LAUNCHD_PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{LAUNCHD_LABEL}.plist")
LAUNCHD_LOG = os.path.expanduser("~/Library/Logs/hub-agent.log")


def install_launchd():
    """Install and load the LaunchAgent plist."""
    import plistlib

    # Resolve paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = os.path.expanduser("~/.config/usb-devices/devices.conf")
    python_path = os.path.expanduser("~/.platformio/penv/bin/python3")
    if not os.path.isfile(python_path):
        python_path = sys.executable

    plist = {
        "Label": LAUNCHD_LABEL,
        "ProgramArguments": [
            python_path, "-u",
            os.path.join(script_dir, "hub_agent.py"),
            "--config", config_path,
        ],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        "StandardOutPath": LAUNCHD_LOG,
        "StandardErrorPath": LAUNCHD_LOG,
    }

    os.makedirs(os.path.dirname(LAUNCHD_PLIST), exist_ok=True)
    with open(LAUNCHD_PLIST, "wb") as f:
        plistlib.dump(plist, f)

    # Load the agent (unload first if already loaded)
    os.system(f"launchctl bootout gui/$(id -u) {LAUNCHD_PLIST} 2>/dev/null")
    rc = os.system(f"launchctl bootstrap gui/$(id -u) {LAUNCHD_PLIST}")
    if rc == 0:
        print(f"[ok] Installed and started {LAUNCHD_LABEL}")
        print(f"     Plist: {LAUNCHD_PLIST}")
        print(f"     Log:   {LAUNCHD_LOG}")
    else:
        print(f"[error] launchctl bootstrap failed (rc={rc})", file=sys.stderr)
        print(f"        Plist written to: {LAUNCHD_PLIST}", file=sys.stderr)
        sys.exit(1)


def uninstall_launchd():
    """Unload and remove the LaunchAgent plist."""
    if not os.path.isfile(LAUNCHD_PLIST):
        print(f"Not installed ({LAUNCHD_PLIST} does not exist).")
        return

    os.system(f"launchctl bootout gui/$(id -u) {LAUNCHD_PLIST} 2>/dev/null")
    os.remove(LAUNCHD_PLIST)
    print(f"[ok] Uninstalled {LAUNCHD_LABEL}")
    print(f"     Removed: {LAUNCHD_PLIST}")


def main():
    parser = argparse.ArgumentParser(description="USB Insight Hub display agent")
    parser.add_argument("--config", default=os.path.expanduser("~/.config/usb-devices/devices.conf"),
                        help="Path to devices.conf")
    parser.add_argument("--hub-port", default=None,
                        help="Override: CDC serial port for Insight Hub")
    parser.add_argument("--hub-location", default=None,
                        help="Override: uhubctl hub ID for channel mapping")
    parser.add_argument("--interval", type=float, default=2.0,
                        help="Poll interval in seconds (default: 2.0, must be <4.5 for hub keepalive)")
    parser.add_argument("--once", action="store_true",
                        help="Sync once and exit")
    parser.add_argument("--status", action="store_true",
                        help="Print hub status and exit")
    parser.add_argument("--install", action="store_true",
                        help="Install as macOS LaunchAgent (auto-start on login)")
    parser.add_argument("--uninstall", action="store_true",
                        help="Uninstall macOS LaunchAgent")
    args = parser.parse_args()

    if args.install:
        install_launchd()
        return

    if args.uninstall:
        uninstall_launchd()
        return

    # Load device registry
    devices = parse_devices_conf(args.config)
    if not devices:
        print("No devices found in config. Add devices to:", file=sys.stderr)
        print(f"  {args.config}", file=sys.stderr)
        sys.exit(1)

    # Find Insight Hub
    hub_port = args.hub_port
    hub_location = args.hub_location

    if not hub_port or not hub_location:
        auto_port, auto_location = find_insight_hub()
        if not hub_port:
            hub_port = auto_port
        if not hub_location:
            hub_location = auto_location

    # In daemon mode (not --once/--status), wait for hub instead of exiting
    daemon_mode = not args.once and not args.status

    if not hub_port:
        if daemon_mode:
            print("[hub-agent] Insight Hub not found, will retry...", file=sys.stderr)
            hub_port = "pending"
            hub_location = "pending"
        else:
            print("Insight Hub not found. Is it connected?", file=sys.stderr)
            sys.exit(1)
    elif not hub_location:
        if not daemon_mode:
            print(f"Insight Hub found at {hub_port} but could not determine hub location.", file=sys.stderr)
            sys.exit(1)

    agent = HubAgent(hub_port, hub_location, devices, interval=args.interval)

    if hub_port == "pending":
        # Force reconnect loop on first iteration
        agent._hub_lost = True

    if args.status:
        agent.status()
    elif args.once:
        agent.run(once=True)
    else:
        agent.run()


if __name__ == "__main__":
    main()
