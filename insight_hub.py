#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# insight_hub.py — USB Insight Hub serial API for power control
"""Per-port power control and monitoring for USB Insight Hub.

The Insight Hub's Renesas hub chip does not support standard USB power switching
(uhubctl), so power must be controlled via the ESP32's JSON serial API.

Commands:
    detect                             Find hub, print port and location
    channel <hub_location> <port>      Resolve to CHx
    power <CHx> <on|off>               Set power state (verified)
    data <CHx> <on|off>                Set USB 2.0 data lines
    cycle <CHx> [off_seconds]          Power cycle (off, wait, on)
    query <CHx>                        Full channel state (JSON)
    voltage <CHx>                      Read voltage (mV)
    current <CHx>                      Read current (mA)
    status                             Summary of all channels
    set <param> <value>                Set a global parameter
    set <CHx> <param> <value>          Set a channel parameter
    get <param> [param...]             Get global/channel parameters

Exit codes: 0 = success, 1 = error
"""

import json
import sys
import time

from serial.tools.list_ports import comports

# Insight Hub identification (shared with hub_agent.py)
INSIGHT_HUB_PRODUCT = "InsightHUB Controller"
INSIGHT_HUB_VID = 0x303A
INSIGHT_HUB_PID = 0x1001


def find_insight_hub():
    """Auto-detect the Insight Hub CDC serial port and hub location.

    Returns (serial_port, hub_location) or (None, None).
    """
    for p in comports():
        if p.product == INSIGHT_HUB_PRODUCT or (p.vid == INSIGHT_HUB_VID and p.pid == INSIGHT_HUB_PID):
            hub_location = None
            if p.location:
                hub_location = p.location.rsplit(".", 1)[0] if "." in p.location else None
            return p.device, hub_location
    return None, None


class HubConnection:
    """Persistent serial connection to an Insight Hub."""

    def __init__(self, serial_port, timeout=2.0):
        import serial as pyserial
        self._ser = pyserial.Serial(serial_port, 115200, timeout=timeout)
        self._ser.dtr = True
        time.sleep(0.1)  # let DTR settle
        self._ser.reset_input_buffer()

    def send(self, msg):
        """Send JSON command, return parsed response or None."""
        try:
            payload = json.dumps(msg, separators=(",", ":")) + "\n"
            self._ser.write(payload.encode())
            self._ser.flush()
            line = self._ser.readline().decode("utf-8", errors="replace").strip()
            if line:
                return json.loads(line)
        except json.JSONDecodeError as e:
            print(f"error: JSON parse: {e}", file=sys.stderr)
        except OSError as e:
            print(f"error: serial: {e}", file=sys.stderr)
        return None

    def close(self):
        if self._ser and self._ser.is_open:
            self._ser.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def hub_set(conn, channel, params):
    """Set one or more parameters on a channel. Returns True on success."""
    msg = {"action": "set", "params": {channel: params}}
    result = conn.send(msg)
    return result and result.get("status") == "ok"


def hub_get(conn, *params):
    """Get parameters. Returns data dict or None."""
    msg = {"action": "get", "params": list(params)}
    result = conn.send(msg)
    if result and result.get("status") == "ok":
        return result.get("data", {})
    return None


def hub_query_channel(conn, channel):
    """Query full channel state. Returns dict or None."""
    data = hub_get(conn, channel)
    if data:
        return data.get(channel, data)
    return None


def hub_power(conn, channel, enable):
    """Set power state for a channel. Returns True if confirmed."""
    value = "true" if enable else "false"
    if not hub_set(conn, channel, {"powerEn": value}):
        print(f"error: set powerEn={value} on {channel} failed", file=sys.stderr)
        return False

    # Verify
    state = hub_query_channel(conn, channel)
    if state is None:
        print(f"warning: could not verify {channel} state", file=sys.stderr)
        return True

    actual = state.get("powerEn")
    if actual != enable:
        print(f"error: {channel} powerEn expected {enable}, got {actual}", file=sys.stderr)
        return False

    return True


def hub_cycle(conn, channel, off_time=2.0):
    """Power cycle: off, wait, on. Returns True if confirmed."""
    print(f"Power off {channel}...", file=sys.stderr)
    if not hub_power(conn, channel, False):
        return False

    time.sleep(off_time)

    print(f"Power on {channel}...", file=sys.stderr)
    if not hub_power(conn, channel, True):
        return False

    return True


def location_to_channel(hub_location, port):
    """Map hub location + port number to channel name."""
    try:
        port = int(port)
    except (ValueError, TypeError):
        return None
    if 1 <= port <= 3:
        return f"CH{port}"
    return None


def format_channel_summary(channel, state):
    """Format a channel state dict as a one-line summary."""
    power = "ON" if state.get("powerEn") else "OFF"
    data = "data" if state.get("dataEn") else "no-data"
    voltage = state.get("voltage", "?")
    current = state.get("current", "?")
    fwd = " FWD-ALERT" if state.get("fwdAlert") else ""
    back = " BACK-ALERT" if state.get("backAlert") else ""
    short = " SHORT" if state.get("shortAlert") else ""
    return f"{channel}: power={power} {data}  {voltage}mV  {current}mA{fwd}{back}{short}"


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    # Commands that don't need a connection
    if cmd == "detect":
        port, location = find_insight_hub()
        if port:
            print(f"{port}\t{location or 'unknown'}")
            sys.exit(0)
        else:
            print("error: Insight Hub not found", file=sys.stderr)
            sys.exit(1)

    if cmd == "channel":
        if len(sys.argv) < 4:
            print("usage: insight_hub.py channel <hub_location> <port>", file=sys.stderr)
            sys.exit(1)
        ch = location_to_channel(sys.argv[2], sys.argv[3])
        if ch:
            print(ch)
            sys.exit(0)
        else:
            print(f"error: port {sys.argv[3]} is not a device channel (1-3)", file=sys.stderr)
            sys.exit(1)

    # All remaining commands need the hub
    hub_port, hub_location = find_insight_hub()
    if not hub_port:
        print("error: Insight Hub not found on USB bus", file=sys.stderr)
        sys.exit(1)

    with HubConnection(hub_port) as conn:

        if cmd == "power":
            if len(sys.argv) < 4:
                print("usage: insight_hub.py power <CHx> <on|off>", file=sys.stderr)
                sys.exit(1)
            channel = sys.argv[2].upper()
            state = sys.argv[3].lower()
            if state not in ("on", "off"):
                print(f"error: state must be 'on' or 'off'", file=sys.stderr)
                sys.exit(1)
            ok = hub_power(conn, channel, state == "on")
            if ok:
                print(f"{channel} power {state}", file=sys.stderr)
            sys.exit(0 if ok else 1)

        if cmd == "data":
            if len(sys.argv) < 4:
                print("usage: insight_hub.py data <CHx> <on|off>", file=sys.stderr)
                sys.exit(1)
            channel = sys.argv[2].upper()
            state = sys.argv[3].lower()
            ok = hub_set(conn, channel, {"dataEn": "true" if state == "on" else "false"})
            if ok:
                print(f"{channel} data {state}", file=sys.stderr)
            sys.exit(0 if ok else 1)

        if cmd == "cycle":
            if len(sys.argv) < 3:
                print("usage: insight_hub.py cycle <CHx> [off_seconds]", file=sys.stderr)
                sys.exit(1)
            channel = sys.argv[2].upper()
            off_time = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
            ok = hub_cycle(conn, channel, off_time)
            sys.exit(0 if ok else 1)

        if cmd == "query":
            if len(sys.argv) < 3:
                print("usage: insight_hub.py query <CHx>", file=sys.stderr)
                sys.exit(1)
            channel = sys.argv[2].upper()
            state = hub_query_channel(conn, channel)
            if state:
                print(json.dumps(state, indent=2))
                sys.exit(0)
            else:
                print(f"error: query {channel} failed", file=sys.stderr)
                sys.exit(1)

        if cmd == "voltage":
            if len(sys.argv) < 3:
                print("usage: insight_hub.py voltage <CHx>", file=sys.stderr)
                sys.exit(1)
            state = hub_query_channel(conn, sys.argv[2].upper())
            if state and "voltage" in state:
                print(f"{state['voltage']} mV")
                sys.exit(0)
            sys.exit(1)

        if cmd == "current":
            if len(sys.argv) < 3:
                print("usage: insight_hub.py current <CHx>", file=sys.stderr)
                sys.exit(1)
            state = hub_query_channel(conn, sys.argv[2].upper())
            if state and "current" in state:
                print(f"{state['current']} mA")
                sys.exit(0)
            sys.exit(1)

        if cmd == "status":
            for ch in ["CH1", "CH2", "CH3"]:
                state = hub_query_channel(conn, ch)
                if state:
                    print(format_channel_summary(ch, state))
                else:
                    print(f"{ch}: error querying state")
            sys.exit(0)

        if cmd == "set":
            if len(sys.argv) < 4:
                print("usage: insight_hub.py set <param> <value>", file=sys.stderr)
                print("       insight_hub.py set <CHx> <param> <value>", file=sys.stderr)
                sys.exit(1)
            # Distinguish global set (2 args) from channel set (3 args)
            if len(sys.argv) == 4:
                # Global: set <param> <value>
                param = sys.argv[2]
                value = sys.argv[3]
                result = conn.send({"action": "set", "params": {param: value}})
                ok = result and result.get("status") == "ok"
                print(f"{'ok' if ok else 'FAILED'}: {param} = {value}")
            else:
                # Channel: set <CHx> <param> <value>
                channel = sys.argv[2].upper()
                param = sys.argv[3]
                value = sys.argv[4]
                ok = hub_set(conn, channel, {param: value})
                print(f"{'ok' if ok else 'FAILED'}: {channel}.{param} = {value}")
            sys.exit(0 if ok else 1)

        if cmd == "get":
            if len(sys.argv) < 3:
                print("usage: insight_hub.py get <param> [param...]", file=sys.stderr)
                sys.exit(1)
            data = hub_get(conn, *sys.argv[2:])
            if data:
                print(json.dumps(data, indent=2))
                sys.exit(0)
            sys.exit(1)

    print(f"error: unknown command '{cmd}'", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
