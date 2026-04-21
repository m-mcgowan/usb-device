# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
"""Config parsing and device registry for usb-device.

Parses devices.conf in two formats:
  - INI: [Section Name] with key=value pairs
  - Flat: Name=MAC (legacy)

Both formats can be mixed in the same file.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path


def normalize_mac(mac: str) -> str:
    """Strip colons/dashes and lowercase."""
    return mac.replace(":", "").replace("-", "").lower()


@dataclass
class Device:
    """A registered USB device."""

    name: str
    mac: str = ""
    type: str = "generic"
    location: str = ""
    chip: str = ""
    hub_name: str = ""
    _fields: dict[str, str] = field(default_factory=dict, repr=False)

    @property
    def power(self) -> str | None:
        return self._fields.get("power")

    @property
    def is_partner(self) -> bool:
        return ":" in self.name

    @property
    def primary_name(self) -> str:
        """The primary device name (before the colon for partners)."""
        return self.name.split(":")[0] if self.is_partner else self.name

    @property
    def partner_role(self) -> str | None:
        """The partner role suffix (after the colon), or None."""
        return self.name.split(":", 1)[1] if self.is_partner else None

    def field(self, key: str) -> str | None:
        """Look up an arbitrary config field."""
        # Check well-known attributes first
        well_known = {
            "mac": self.mac, "serial": self.mac, "type": self.type,
            "location": self.location, "chip": self.chip, "hub_name": self.hub_name,
        }
        if key in well_known:
            return well_known[key] or None
        return self._fields.get(key)


def _is_regex(pattern: str) -> bool:
    """Check if a pattern contains regex special characters."""
    return bool(re.search(r"[.+*?^${}()|\\[\]]", pattern))


class DeviceConfig:
    """Parse devices.conf and provide device lookup."""

    def __init__(self, conf_path: str | Path):
        self.conf_path = Path(conf_path)
        self.devices: list[Device] = []
        self.hub_conf_port: str = ""
        self.hub_conf_location: str = ""
        self._parse()

    def _parse(self):
        if not self.conf_path.is_file():
            return

        section: str = ""
        sec_fields: dict[str, str] = {}

        for raw_line in self.conf_path.read_text().splitlines():
            line = raw_line.strip()

            # Skip comments and blank lines
            if not line or line.startswith("#"):
                continue

            # Section header: [Name]
            m = re.match(r"^\[(.+)]$", line)
            if m:
                self._flush_section(section, sec_fields)
                section = m.group(1)
                sec_fields = {}
                continue

            # Key=value
            if "=" in line:
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip()

                if section:
                    sec_fields[key] = val
                else:
                    # Flat format: Name=MAC
                    self._add_device(Device(name=key, mac=val))

        # Flush last section
        self._flush_section(section, sec_fields)

    def _flush_section(self, name: str, fields: dict[str, str]):
        if not name:
            return

        # Hub config sections are not devices
        if name.startswith("hub:"):
            self.hub_conf_location = fields.get("location", self.hub_conf_location)
            self.hub_conf_port = fields.get("port", self.hub_conf_port)
            return

        mac = fields.get("mac", "") or fields.get("serial", "")
        dev = Device(
            name=name,
            mac=mac,
            type=fields.get("type", "generic"),
            location=fields.get("location", ""),
            chip=fields.get("chip", ""),
            hub_name=fields.get("hub_name", ""),
            _fields={k: v for k, v in fields.items()
                     if k not in ("mac", "serial", "type", "location", "chip", "hub_name")},
        )
        self._add_device(dev)

    def _add_device(self, dev: Device):
        self.devices.append(dev)

    # ── Lookup ───────────────────────────────────────────────────

    def get(self, name: str) -> Device | None:
        """Exact (case-insensitive) lookup by name."""
        name_lower = name.lower()
        for d in self.devices:
            if d.name.lower() == name_lower:
                return d
        return None

    def find(self, pattern: str) -> list[Device]:
        """Find devices matching a pattern (exact, substring, or regex).

        Partner devices (name contains ':') are excluded from fuzzy matches
        unless the pattern itself contains ':'.
        """
        include_partners = ":" in pattern

        # Exact match (case-insensitive) — always considers all devices
        for d in self.devices:
            if d.name.lower() == pattern.lower():
                return [d]

        # Partner search: split on ':', fuzzy-match primary, exact-match role
        if include_partners:
            primary_pattern, _, role = pattern.partition(":")
            matches = []
            primaries = self._fuzzy_match(primary_pattern, exclude_partners=True)
            for primary in primaries:
                composed = f"{primary.name}:{role}"
                found = self.get(composed)
                if found:
                    matches.append(found)
            return matches

        # Non-partner fuzzy match
        return self._fuzzy_match(pattern, exclude_partners=True)

    def _fuzzy_match(self, pattern: str, exclude_partners: bool) -> list[Device]:
        """Substring or regex match against device names."""
        matches = []
        if _is_regex(pattern):
            try:
                rx = re.compile(pattern, re.IGNORECASE)
            except re.error:
                return []
            for d in self.devices:
                if exclude_partners and d.is_partner:
                    continue
                if rx.search(d.name):
                    matches.append(d)
        else:
            pat_lower = pattern.lower()
            for d in self.devices:
                if exclude_partners and d.is_partner:
                    continue
                if pat_lower in d.name.lower():
                    matches.append(d)
        return matches

    # ── Partner API ──────────────────────────────────────────────

    def partner(self, device_name: str, role: str) -> Device | None:
        """Find a partner device by role suffix.

        If device_name is an exact match, looks for 'device_name:role'.
        If device_name is a fuzzy match, resolves to the primary first.
        Returns None for partner devices (no partner-of-partner).
        """
        # Resolve the primary device
        primary = self.get(device_name)
        if primary is None:
            candidates = self.find(device_name)
            if len(candidates) == 1:
                primary = candidates[0]
            else:
                return None

        # Partners don't have partners
        if primary.is_partner:
            return None

        return self.get(f"{primary.name}:{role}")

    def partners(self, device_name: str) -> list[Device]:
        """Find all partners for a device."""
        primary = self.get(device_name)
        if primary is None:
            candidates = self.find(device_name)
            if len(candidates) == 1:
                primary = candidates[0]
            else:
                return []

        if primary.is_partner:
            return []

        prefix = f"{primary.name}:"
        return [d for d in self.devices if d.name.startswith(prefix)]
