# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
"""Labgrid drivers for usb-device managed hardware.

USBDevicePowerDriver provides power control (on/off/cycle) by calling
the usb-device CLI, which dispatches to the appropriate type plugin.
"""

from __future__ import annotations

import logging
import subprocess

import attr
from labgrid.driver import Driver
from labgrid.protocol import PowerProtocol
from labgrid.factory import target_factory

from .resource import USBDevice, NetworkUSBDevice

logger = logging.getLogger(__name__)

_USB_DEVICE_BIN = "usb-device"


def _run_usb_device(
    *args: str,
    command_prefix: list[str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess:
    """Run a usb-device command, optionally via SSH (command_prefix)."""
    cmd = list(command_prefix or []) + [_USB_DEVICE_BIN, *args]
    logger.debug("Running: %s", " ".join(cmd))
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


@target_factory.reg_driver
@attr.s(eq=False)
class USBDevicePowerDriver(Driver, PowerProtocol):
    """Power control for usb-device managed hardware.

    Binds to a USBDevice or NetworkUSBDevice resource and calls
    usb-device on/off/reset for power control.

    For remote devices (NetworkUSBDevice), commands are executed via
    the resource's command_prefix (typically SSH).
    """

    bindings = {"device": {"USBDevice", "NetworkUSBDevice"}}

    def _get_prefix(self) -> list[str] | None:
        """Get SSH command prefix for remote devices."""
        if isinstance(self.device, NetworkUSBDevice):
            host = self.device.host
            if host:
                return ["ssh", "-x", host]
        return None

    @Driver.check_active
    def on(self):
        """Power on the device."""
        logger.info("Powering on: %s", self.device.device_name)
        _run_usb_device(
            "on",
            self.device.device_name,
            command_prefix=self._get_prefix(),
            check=False,
        )

    @Driver.check_active
    def off(self):
        """Power off the device."""
        logger.info("Powering off: %s", self.device.device_name)
        _run_usb_device(
            "off",
            self.device.device_name,
            command_prefix=self._get_prefix(),
            check=False,
        )

    @Driver.check_active
    def cycle(self):
        """Power cycle the device."""
        logger.info("Power cycling: %s", self.device.device_name)
        _run_usb_device(
            "reset",
            self.device.device_name,
            command_prefix=self._get_prefix(),
            check=False,
        )
