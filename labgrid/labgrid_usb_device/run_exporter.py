#!/usr/bin/env python3
"""Custom labgrid exporter that registers usb-device resource types.

This is a thin wrapper around labgrid's built-in exporter. It registers
USBDevice as a passthrough resource type so the standard exporter.yaml
format works with our custom resources.

Usage:
    python -m labgrid_usb_device.run_exporter -c HOST:PORT exporter.yaml
    # or via entry point:
    usb-device-exporter -c HOST:PORT exporter.yaml
"""

from labgrid.remote.exporter import exports
from labgrid.remote.exporter import main as _labgrid_main
from labgrid.remote.common import ResourceEntry

# Register usb-device resource types as passthrough exports.
# ResourceEntry makes the resource available on the coordinator
# without special handling (no ser2net, no udev matching).
exports["USBDevice"] = ResourceEntry


def main():
    _labgrid_main()


if __name__ == "__main__":
    main()
