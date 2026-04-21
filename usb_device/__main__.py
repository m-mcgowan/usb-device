# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
"""CLI entry point for usb_device Python core.

Called by the bash usb-device script for operations migrated to Python.
Usage: python3 -m usb_device <command> [args...]

Commands:
  find <pattern>                    Find devices matching a pattern
  get <name>                        Exact device lookup (exit 1 if not found)
  field <name> <key>                Get a config field value
  partner <name> <role>             Find a partner device
  partners <name>                   List all partners
  names                             List all device names
  parse                             Dump parsed config as JSON
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from .config import DeviceConfig, Device

DEFAULT_CONF = Path(
    os.environ.get("USB_DEVICE_CONF", "")
    or Path.home() / ".config" / "usb-devices" / "devices.conf"
)


def _load_config() -> DeviceConfig:
    conf = os.environ.get("USB_DEVICE_CONF", "") or str(DEFAULT_CONF)
    return DeviceConfig(conf)


def _device_dict(d: Device) -> dict:
    """Convert a Device to a dict for JSON output."""
    result = {"name": d.name, "mac": d.mac, "type": d.type}
    if d.location:
        result["location"] = d.location
    if d.chip:
        result["chip"] = d.chip
    if d.hub_name:
        result["hub_name"] = d.hub_name
    if d.is_partner:
        result["partner_of"] = d.primary_name
        result["role"] = d.partner_role
    if d.power:
        result["power"] = d.power
    return result


def cmd_find(args: list[str]) -> int:
    if not args:
        print("usage: python3 -m usb_device find <pattern>", file=sys.stderr)
        return 1
    cfg = _load_config()
    results = cfg.find(args[0])
    if not results:
        return 1
    for d in results:
        print(d.name)
    return 0


def cmd_get(args: list[str]) -> int:
    if not args:
        print("usage: python3 -m usb_device get <name>", file=sys.stderr)
        return 1
    cfg = _load_config()
    d = cfg.get(args[0])
    if d is None:
        return 1
    print(json.dumps(_device_dict(d)))
    return 0


def cmd_field(args: list[str]) -> int:
    if len(args) < 2:
        print("usage: python3 -m usb_device field <name> <key>", file=sys.stderr)
        return 1
    cfg = _load_config()
    d = cfg.get(args[0])
    if d is None:
        # Try fuzzy match
        results = cfg.find(args[0])
        if len(results) == 1:
            d = results[0]
        else:
            return 1
    val = d.field(args[1])
    if val is None:
        return 1
    print(val)
    return 0


def cmd_partner(args: list[str]) -> int:
    if len(args) < 2:
        print("usage: python3 -m usb_device partner <name> <role>", file=sys.stderr)
        return 1
    cfg = _load_config()
    p = cfg.partner(args[0], args[1])
    if p is None:
        return 1
    print(json.dumps(_device_dict(p)))
    return 0


def cmd_partners(args: list[str]) -> int:
    if not args:
        print("usage: python3 -m usb_device partners <name>", file=sys.stderr)
        return 1
    cfg = _load_config()
    partners = cfg.partners(args[0])
    if not partners:
        return 1
    for p in partners:
        print(json.dumps(_device_dict(p)))
    return 0


def cmd_names(args: list[str]) -> int:
    cfg = _load_config()
    for d in cfg.devices:
        print(d.name)
    return 0


def cmd_parse(args: list[str]) -> int:
    cfg = _load_config()
    output = {
        "devices": [_device_dict(d) for d in cfg.devices],
    }
    if cfg.hub_conf_port or cfg.hub_conf_location:
        output["hub"] = {
            "port": cfg.hub_conf_port,
            "location": cfg.hub_conf_location,
        }
    print(json.dumps(output, indent=2))
    return 0


COMMANDS = {
    "find": cmd_find,
    "get": cmd_get,
    "field": cmd_field,
    "partner": cmd_partner,
    "partners": cmd_partners,
    "names": cmd_names,
    "parse": cmd_parse,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd not in COMMANDS:
        print(f"unknown command: {cmd}", file=sys.stderr)
        print(f"available: {', '.join(COMMANDS)}", file=sys.stderr)
        sys.exit(1)

    sys.exit(COMMANDS[cmd](sys.argv[2:]))


if __name__ == "__main__":
    main()
