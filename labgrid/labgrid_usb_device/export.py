# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
"""Labgrid exporter integration for usb-device.

USBDeviceExport reads devices.conf, auto-discovers partners, and manages
the checkout/checkin lifecycle. It creates a USBDevice resource plus a
SerialPort for each device entry that has a discoverable serial port.
"""

from __future__ import annotations

import logging
import subprocess
from typing import Any

import attr
from labgrid.resource import SerialPort

from .conf_parser import parse_config, group_devices, DeviceGroup
from .resource import USBDevice

logger = logging.getLogger(__name__)

# usb-device CLI binary — can be overridden via USB_DEVICE_BIN env var
_USB_DEVICE_BIN = "usb-device"


def _run_usb_device(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    """Run a usb-device CLI command."""
    cmd = [_USB_DEVICE_BIN, *args]
    logger.debug("Running: %s", " ".join(cmd))
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def _get_serial_port(device_name: str) -> str | None:
    """Query usb-device for a device's serial port path."""
    result = _run_usb_device("port", device_name, check=False)
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    return None


def _get_device_type(device_name: str) -> str | None:
    """Query usb-device for a device's type."""
    result = _run_usb_device("type", device_name, check=False)
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    return None


@attr.s(eq=False)
class USBDeviceExport:
    """Exporter-side manager for a usb-device device group.

    Configured in exporter.yaml:

    .. code-block:: yaml

        test-rig-1:
          USBDevice:
            device_name: "Board Rev-B"
            setup_script: /path/to/setup.sh        # optional
            teardown_script: /path/to/teardown.sh   # optional

    On export, reads devices.conf to find the named device and all its
    partners. Creates USBDevice + SerialPort resources for each.

    Attributes:
        device_name: Primary device name in devices.conf.
        setup_script: Optional script to run on acquire (device_name as $1).
        teardown_script: Optional script to run on release.
    """

    device_name = attr.ib(validator=attr.validators.instance_of(str))
    setup_script = attr.ib(default=None)
    teardown_script = attr.ib(default=None)

    # Populated by __attrs_post_init__
    _group: DeviceGroup | None = attr.ib(init=False, default=None)
    _local_resources: list = attr.ib(init=False, factory=list)

    def __attrs_post_init__(self):
        entries = parse_config()
        groups = group_devices(entries)
        self._group = groups.get(self.device_name)
        if self._group is None:
            logger.warning(
                "Device '%s' not found in devices.conf", self.device_name
            )

    def get_resources(self) -> list[dict[str, Any]]:
        """Return resource definitions for the coordinator.

        Creates one USBDevice per entry (primary + partners) and one
        SerialPort per entry that has a discoverable serial port.
        """
        if self._group is None:
            return []

        resources = []
        for entry in self._group.all_entries():
            role = entry.partner_role
            # Resource name: primary uses group name, partners use role
            res_name = role if role else self._group.name

            # USBDevice resource
            usb_res = {
                "cls": "USBDevice",
                "name": res_name,
                "params": {
                    "device_name": entry.name,
                    "device_type": entry.device_type,
                    "group_name": self._group.name,
                    "role": role,
                    "extra": {
                        k: v
                        for k, v in entry.attrs.items()
                        if k not in ("type",)
                    },
                },
            }
            resources.append(usb_res)

            # SerialPort resource (if device has a serial port)
            port = _get_serial_port(entry.name)
            if port:
                serial_name = f"{res_name}-serial" if role else "serial"
                serial_res = {
                    "cls": "SerialPort",
                    "name": serial_name,
                    "params": {
                        "port": port,
                        "speed": 115200,
                    },
                }
                resources.append(serial_res)

        return resources

    def poll(self) -> dict[str, dict[str, Any]]:
        """Poll device availability and update serial port paths.

        Called periodically by the exporter. Returns updated params for
        each resource that has changed.
        """
        updates = {}
        if self._group is None:
            return updates

        for entry in self._group.all_entries():
            port = _get_serial_port(entry.name)
            role = entry.partner_role
            serial_name = f"{role}-serial" if role else "serial"
            if port:
                updates[serial_name] = {"port": port}

        return updates

    def start(self, place_name: str | None = None):
        """Acquire devices (checkout + setup script).

        Called when a place is acquired.
        """
        if self._group is None:
            return

        # Checkout all devices in the group
        names = [e.name for e in self._group.all_entries() if e.mac]
        if names:
            checkout_args = ["checkout"]
            if place_name:
                checkout_args.extend(["--purpose", place_name])
            checkout_args.extend(names)
            _run_usb_device(*checkout_args, check=False)

        # Run setup script
        if self.setup_script:
            port = _get_serial_port(self.device_name) or ""
            logger.info("Running setup script: %s", self.setup_script)
            subprocess.run(
                [self.setup_script, self.device_name, port],
                check=False,
            )

    def stop(self):
        """Release devices (teardown script + checkin).

        Called when a place is released.
        """
        if self._group is None:
            return

        # Run teardown script
        if self.teardown_script:
            port = _get_serial_port(self.device_name) or ""
            logger.info("Running teardown script: %s", self.teardown_script)
            subprocess.run(
                [self.teardown_script, self.device_name, port],
                check=False,
            )

        # Checkin all devices in the group
        names = [e.name for e in self._group.all_entries() if e.mac]
        if names:
            _run_usb_device("checkin", *names, check=False)
