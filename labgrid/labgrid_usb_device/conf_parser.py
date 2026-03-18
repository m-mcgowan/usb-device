# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
"""Parse usb-device devices.conf INI files.

Returns all key-value pairs per section — the parser is deliberately
schema-agnostic so that new device metadata fields (notecard deviceID,
modem type, etc.) flow through without code changes.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class DeviceEntry:
    """A single device section from devices.conf."""

    name: str
    attrs: dict[str, str] = field(default_factory=dict)

    # Convenience accessors for common fields
    @property
    def mac(self) -> str | None:
        return self.attrs.get("mac") or self.attrs.get("serial")

    @property
    def device_type(self) -> str:
        return self.attrs.get("type", "generic")

    @property
    def chip(self) -> str | None:
        return self.attrs.get("chip")

    @property
    def location(self) -> str | None:
        return self.attrs.get("location")

    @property
    def hub_name(self) -> str | None:
        return self.attrs.get("hub_name")

    def is_partner_of(self, primary_name: str) -> bool:
        """True if this entry is a partner of primary_name (name contains ':')."""
        return ":" in self.name and self.name.rsplit(":", 1)[0] == primary_name

    @property
    def partner_role(self) -> str | None:
        """The partner role (part after ':'), or None for primary devices."""
        if ":" in self.name:
            return self.name.rsplit(":", 1)[1]
        return None

    @property
    def primary_name(self) -> str:
        """The primary device name (part before ':' if partner, else full name)."""
        if ":" in self.name:
            return self.name.rsplit(":", 1)[0]
        return self.name


@dataclass
class DeviceGroup:
    """A primary device and its partners."""

    primary: DeviceEntry
    partners: dict[str, DeviceEntry] = field(default_factory=dict)

    @property
    def name(self) -> str:
        return self.primary.name

    def all_entries(self) -> list[DeviceEntry]:
        """Primary + all partners, ordered."""
        return [self.primary] + list(self.partners.values())


def parse_config(path: str | Path | None = None) -> list[DeviceEntry]:
    """Parse a devices.conf file, returning all device entries.

    Args:
        path: Path to devices.conf. If None, uses USB_DEVICE_CONF env var,
              then falls back to ~/.config/usb-devices/devices.conf.

    Returns:
        List of DeviceEntry (includes both primary devices and partners).
    """
    if path is None:
        path = os.environ.get(
            "USB_DEVICE_CONF",
            os.path.join(
                os.environ.get(
                    "USB_DEVICE_CONFIG_DIR",
                    os.path.expanduser("~/.config/usb-devices"),
                ),
                "devices.conf",
            ),
        )
    path = Path(path)
    if not path.exists():
        return []

    entries: list[DeviceEntry] = []
    current_section: str | None = None
    current_attrs: dict[str, str] = {}

    def flush():
        nonlocal current_section, current_attrs
        if current_section is not None:
            # Skip hub config sections
            if not current_section.startswith("hub:"):
                entries.append(DeviceEntry(name=current_section, attrs=current_attrs))
            current_section = None
            current_attrs = {}

    for line in path.read_text().splitlines():
        line = line.strip()

        # Skip comments and blank lines
        if not line or line.startswith("#"):
            continue

        # Section header: [Name] or [Name:partner]
        m = re.match(r"^\[(.+)\]$", line)
        if m:
            flush()
            current_section = m.group(1)
            current_attrs = {}
            continue

        # Key=value inside a section
        if current_section is not None and "=" in line:
            key, _, val = line.partition("=")
            current_attrs[key.strip()] = val.strip()
            continue

        # Legacy flat format: NAME=MAC (only outside sections)
        if current_section is None and "=" in line:
            name, _, mac = line.partition("=")
            entries.append(
                DeviceEntry(name=name.strip(), attrs={"mac": mac.strip()})
            )

    flush()
    return entries


def group_devices(entries: list[DeviceEntry]) -> dict[str, DeviceGroup]:
    """Group device entries into primary + partners.

    Returns:
        Dict keyed by primary device name → DeviceGroup.
    """
    groups: dict[str, DeviceGroup] = {}

    # First pass: create groups for primary devices
    for entry in entries:
        if entry.partner_role is None:
            groups[entry.name] = DeviceGroup(primary=entry)

    # Second pass: attach partners to their primary
    for entry in entries:
        role = entry.partner_role
        if role is not None:
            primary_name = entry.primary_name
            if primary_name not in groups:
                # Orphan partner — create a placeholder primary
                groups[primary_name] = DeviceGroup(
                    primary=DeviceEntry(name=primary_name)
                )
            groups[primary_name].partners[role] = entry

    return groups


def find_device(
    entries: list[DeviceEntry], pattern: str
) -> DeviceEntry | None:
    """Find a device entry by exact name (case-insensitive).

    Args:
        entries: List from parse_config().
        pattern: Device name to match.

    Returns:
        Matching DeviceEntry or None.
    """
    pattern_lower = pattern.lower()
    for entry in entries:
        if entry.name.lower() == pattern_lower:
            return entry
    return None
