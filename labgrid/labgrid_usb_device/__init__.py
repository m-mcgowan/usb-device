# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
"""Labgrid integration for usb-device managed hardware.

Importing this package registers USBDevice, NetworkUSBDevice, and
USBDevicePowerDriver with labgrid's target_factory.
"""

from . import resource  # noqa: F401 — registers USBDevice, NetworkUSBDevice
from . import driver  # noqa: F401 — registers USBDevicePowerDriver
from .conf_parser import parse_config, group_devices, DeviceEntry, DeviceGroup
from .export import USBDeviceExport

__all__ = [
    "parse_config",
    "group_devices",
    "DeviceEntry",
    "DeviceGroup",
    "USBDeviceExport",
]
