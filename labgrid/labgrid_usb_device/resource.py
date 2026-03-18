# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
"""Labgrid resources for usb-device managed hardware.

USBDevice is a standalone resource (does NOT inherit SerialPort) because
a device group typically has multiple serial ports (host, notecard, ppk2).
Each port gets its own SerialPort resource; the USBDevice holds group
identity, metadata, and power control bindings.
"""

from __future__ import annotations

import attr
from labgrid.resource import Resource, NetworkResource
from labgrid.factory import target_factory


@target_factory.reg_resource
@attr.s(eq=False)
class USBDevice(Resource):
    """A USB device managed by the usb-device tool.

    Represents a single device entry from devices.conf (either a primary
    device or a partner). For composite fixtures, the labgrid place groups
    multiple USBDevice + SerialPort resources together.

    Attributes:
        device_name: Full name in devices.conf (e.g. "Board Rev-A"
                     or "Board Rev-A:notecard").
        device_type: Type from devices.conf (esp32, notecard, ppk2, generic).
        group_name:  Primary device name (before ':'). Same as device_name
                     for primary devices.
        role:        Partner role (after ':'), or None for primary devices.
        extra:       All additional key-value pairs from devices.conf.
                     Device-specific metadata (chip, sku, device_uid, modem,
                     etc.) flows through here without schema changes.
    """

    device_name = attr.ib(validator=attr.validators.instance_of(str))
    device_type = attr.ib(default="generic")
    group_name = attr.ib(default=None)
    role = attr.ib(default=None)
    extra = attr.ib(factory=dict)

    def __attrs_post_init__(self):
        super().__attrs_post_init__()
        if self.group_name is None:
            self.group_name = self.device_name


@target_factory.reg_resource
@attr.s(eq=False)
class NetworkUSBDevice(NetworkResource):
    """Remote USBDevice exported over the labgrid coordinator.

    Mirrors USBDevice attributes for network access. The exporter creates
    local USBDevice instances; the coordinator distributes them as
    NetworkUSBDevice to clients.
    """

    device_name = attr.ib(validator=attr.validators.instance_of(str))
    device_type = attr.ib(default="generic")
    group_name = attr.ib(default=None)
    role = attr.ib(default=None)
    extra = attr.ib(factory=dict)
    # Serial port info (if this device has a serial port)
    port = attr.ib(default=None)
    speed = attr.ib(default=115200)
