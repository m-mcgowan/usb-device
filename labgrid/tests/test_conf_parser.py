# SPDX-License-Identifier: MIT
"""Tests for devices.conf parser."""

from __future__ import annotations

import sys
import textwrap
from pathlib import Path

# Allow importing conf_parser without labgrid installed
sys.modules.setdefault("labgrid_usb_device", type(sys)("labgrid_usb_device"))
if hasattr(sys.modules["labgrid_usb_device"], "__path__"):
    pass
else:
    sys.modules["labgrid_usb_device"].__path__ = [
        str(Path(__file__).parent.parent / "labgrid_usb_device")
    ]

from labgrid_usb_device.conf_parser import (  # noqa: E402
    parse_config,
    group_devices,
    find_device,
    DeviceEntry,
)


def _write_conf(tmp_path: Path, content: str) -> Path:
    conf = tmp_path / "devices.conf"
    conf.write_text(textwrap.dedent(content))
    return conf


def test_empty_file(tmp_path):
    conf = _write_conf(tmp_path, "")
    entries = parse_config(conf)
    assert entries == []


def test_comments_and_blanks(tmp_path):
    conf = _write_conf(
        tmp_path,
        """\
        # Comment
        # Another comment

        """,
    )
    entries = parse_config(conf)
    assert entries == []


def test_legacy_flat_format(tmp_path):
    conf = _write_conf(
        tmp_path,
        """\
        My Device=AA:BB:CC:DD:EE:FF
        """,
    )
    entries = parse_config(conf)
    assert len(entries) == 1
    assert entries[0].name == "My Device"
    assert entries[0].mac == "AA:BB:CC:DD:EE:FF"
    assert entries[0].device_type == "generic"


def test_ini_section(tmp_path):
    conf = _write_conf(
        tmp_path,
        """\
        [Board Rev-A]
        mac=B8:F8:62:D2:2A:FC
        type=esp32
        chip=esp32s3
        hub_name=Rev-A Dev
        """,
    )
    entries = parse_config(conf)
    assert len(entries) == 1
    e = entries[0]
    assert e.name == "Board Rev-A"
    assert e.mac == "B8:F8:62:D2:2A:FC"
    assert e.device_type == "esp32"
    assert e.chip == "esp32s3"
    assert e.hub_name == "Rev-A Dev"
    assert e.partner_role is None
    assert e.primary_name == "Board Rev-A"


def test_serial_alias(tmp_path):
    """serial= should work the same as mac=."""
    conf = _write_conf(
        tmp_path,
        """\
        [PPK2 Dev]
        serial=C9F6358AC307
        type=ppk2
        """,
    )
    entries = parse_config(conf)
    assert entries[0].mac == "C9F6358AC307"


def test_partners(tmp_path):
    conf = _write_conf(
        tmp_path,
        """\
        [Board Rev-B]
        mac=B8:F8:62:D2:2A:FC
        type=esp32
        chip=esp32s3

        [Board Rev-B:notecard]
        serial=DEV00012345
        type=notecard
        device_uid=dev:xxxxxxxxxxxx
        sku=NOTE-WBNA-500
        modem=BG95-M3

        [Board Rev-B:ppk2]
        serial=C9F6358AC307
        type=ppk2
        """,
    )
    entries = parse_config(conf)
    assert len(entries) == 3

    # Check partner attributes
    notecard = entries[1]
    assert notecard.name == "Board Rev-B:notecard"
    assert notecard.partner_role == "notecard"
    assert notecard.primary_name == "Board Rev-B"
    assert notecard.device_type == "notecard"
    assert notecard.is_partner_of("Board Rev-B")
    assert not notecard.is_partner_of("Board Rev-A")

    # Extra attrs flow through
    assert notecard.attrs["device_uid"] == "dev:xxxxxxxxxxxx"
    assert notecard.attrs["sku"] == "NOTE-WBNA-500"
    assert notecard.attrs["modem"] == "BG95-M3"


def test_group_devices(tmp_path):
    conf = _write_conf(
        tmp_path,
        """\
        [Board A]
        mac=AA:AA:AA:AA:AA:AA
        type=esp32

        [Board A:notecard]
        serial=NC001
        type=notecard

        [Board A:ppk2]
        serial=PPK001
        type=ppk2

        [Board B]
        mac=BB:BB:BB:BB:BB:BB
        type=esp32
        """,
    )
    entries = parse_config(conf)
    groups = group_devices(entries)

    assert len(groups) == 2
    assert "Board A" in groups
    assert "Board B" in groups

    group_a = groups["Board A"]
    assert group_a.name == "Board A"
    assert group_a.primary.mac == "AA:AA:AA:AA:AA:AA"
    assert len(group_a.partners) == 2
    assert "notecard" in group_a.partners
    assert "ppk2" in group_a.partners
    assert len(group_a.all_entries()) == 3

    group_b = groups["Board B"]
    assert len(group_b.partners) == 0


def test_hub_sections_excluded(tmp_path):
    conf = _write_conf(
        tmp_path,
        """\
        [hub:insight]
        port=/dev/cu.usbmodemXXXX
        location=20-3.3

        [My Device]
        mac=AA:BB:CC:DD:EE:FF
        """,
    )
    entries = parse_config(conf)
    assert len(entries) == 1
    assert entries[0].name == "My Device"


def test_orphan_partner(tmp_path):
    """Partner without a primary should create a placeholder group."""
    conf = _write_conf(
        tmp_path,
        """\
        [Ghost:ppk2]
        serial=PPK001
        type=ppk2
        """,
    )
    entries = parse_config(conf)
    groups = group_devices(entries)
    assert "Ghost" in groups
    assert groups["Ghost"].primary.mac is None
    assert "ppk2" in groups["Ghost"].partners


def test_find_device(tmp_path):
    conf = _write_conf(
        tmp_path,
        """\
        [Board Rev-A]
        mac=AA:AA:AA:AA:AA:AA

        [Board Rev-B]
        mac=BB:BB:BB:BB:BB:BB
        """,
    )
    entries = parse_config(conf)

    found = find_device(entries, "Board Rev-B")
    assert found is not None
    assert found.mac == "BB:BB:BB:BB:BB:BB"

    # Case insensitive
    found = find_device(entries, "board rev-b")
    assert found is not None

    assert find_device(entries, "nonexistent") is None


def test_all_attrs_preserved(tmp_path):
    """Any key=value pair should be preserved in attrs dict."""
    conf = _write_conf(
        tmp_path,
        """\
        [Custom Device]
        mac=AA:BB:CC:DD:EE:FF
        type=custom
        custom_field_1=value1
        custom_field_2=value2
        anything_goes=yes
        """,
    )
    entries = parse_config(conf)
    e = entries[0]
    assert e.attrs["custom_field_1"] == "value1"
    assert e.attrs["custom_field_2"] == "value2"
    assert e.attrs["anything_goes"] == "yes"
