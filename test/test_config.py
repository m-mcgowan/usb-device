#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
"""Tests for usb_device.config — config parsing and device registry."""

import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from usb_device.config import DeviceConfig, Device


# ── Config parsing ───────────────────────────────────────────────


class TestFlatFormat:
    def test_simple_flat(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text("Device A=AA:AA:AA:AA:AA:AA\n")
        cfg = DeviceConfig(conf)
        assert len(cfg.devices) == 1
        d = cfg.devices[0]
        assert d.name == "Device A"
        assert d.mac == "AA:AA:AA:AA:AA:AA"
        assert d.type == "generic"

    def test_multiple_flat(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "Device A=AA:AA:AA:AA:AA:AA\n"
            "Device B=BB:BB:BB:BB:BB:BB\n"
        )
        cfg = DeviceConfig(conf)
        assert len(cfg.devices) == 2
        assert cfg.devices[0].name == "Device A"
        assert cfg.devices[1].name == "Device B"

    def test_comments_and_blank_lines(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "# Comment\n"
            "\n"
            "Device A=AA:AA:AA:AA:AA:AA\n"
            "  # Indented comment\n"
            "\n"
        )
        cfg = DeviceConfig(conf)
        assert len(cfg.devices) == 1


class TestINIFormat:
    def test_section_with_mac(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[Board Rev-A]\n"
            "mac=B8:F8:62:D2:2A:FC\n"
            "type=esp32\n"
            "chip=esp32s3\n"
        )
        cfg = DeviceConfig(conf)
        assert len(cfg.devices) == 1
        d = cfg.devices[0]
        assert d.name == "Board Rev-A"
        assert d.mac == "B8:F8:62:D2:2A:FC"
        assert d.type == "esp32"
        assert d.chip == "esp32s3"

    def test_serial_field(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[PPK2 Dev]\n"
            "serial=C9F6358AC307\n"
            "type=ppk2\n"
        )
        cfg = DeviceConfig(conf)
        d = cfg.devices[0]
        assert d.mac == "C9F6358AC307"
        assert d.type == "ppk2"

    def test_location_field(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[Charger Port A]\n"
            "location=20-2.3\n"
            "type=power\n"
        )
        cfg = DeviceConfig(conf)
        d = cfg.devices[0]
        assert d.location == "20-2.3"
        assert d.type == "power"

    def test_hub_name(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[Board Rev-A]\n"
            "mac=B8:F8:62:D2:2A:FC\n"
            "type=esp32\n"
            "hub_name=Rev-A Dev\n"
        )
        cfg = DeviceConfig(conf)
        assert cfg.devices[0].hub_name == "Rev-A Dev"

    def test_default_type_is_generic(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[Simple Board]\n"
            "mac=AA:BB:CC:DD:EE:FF\n"
        )
        cfg = DeviceConfig(conf)
        assert cfg.devices[0].type == "generic"

    def test_multiple_sections(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[Board A]\n"
            "mac=AA:AA:AA:AA:AA:AA\n"
            "type=esp32\n"
            "\n"
            "[Board B]\n"
            "mac=BB:BB:BB:BB:BB:BB\n"
            "type=ppk2\n"
        )
        cfg = DeviceConfig(conf)
        assert len(cfg.devices) == 2
        assert cfg.devices[0].name == "Board A"
        assert cfg.devices[0].type == "esp32"
        assert cfg.devices[1].name == "Board B"
        assert cfg.devices[1].type == "ppk2"


class TestMixedFormat:
    def test_flat_and_ini(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "Legacy=AA:AA:AA:AA:AA:AA\n"
            "\n"
            "[Modern Board]\n"
            "mac=BB:BB:BB:BB:BB:BB\n"
            "type=esp32\n"
        )
        cfg = DeviceConfig(conf)
        assert len(cfg.devices) == 2
        assert cfg.devices[0].name == "Legacy"
        assert cfg.devices[0].type == "generic"
        assert cfg.devices[1].name == "Modern Board"
        assert cfg.devices[1].type == "esp32"


class TestHubConfig:
    def test_hub_section_not_a_device(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[hub:insight]\n"
            "port=/dev/cu.usbmodemXXXX\n"
            "location=20-3.3\n"
            "\n"
            "[Real Device]\n"
            "mac=AA:BB:CC:DD:EE:FF\n"
        )
        cfg = DeviceConfig(conf)
        assert len(cfg.devices) == 1
        assert cfg.devices[0].name == "Real Device"
        assert cfg.hub_conf_port == "/dev/cu.usbmodemXXXX"
        assert cfg.hub_conf_location == "20-3.3"


class TestArbitraryFields:
    def test_field_lookup(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[MPCB 1.10]\n"
            "mac=B8:F8:62:C5:FC:D4\n"
            "type=esp32\n"
            "notecard_uid=dev:860322068097069\n"
            "power=PPK2 Workshop\n"
        )
        cfg = DeviceConfig(conf)
        d = cfg.devices[0]
        assert d.field("notecard_uid") == "dev:860322068097069"
        assert d.field("power") == "PPK2 Workshop"
        assert d.field("nonexistent") is None

    def test_power_field(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[MPCB 1.10]\n"
            "mac=AA:BB:CC:DD:EE:FF\n"
            "power=PPK2 Workshop\n"
        )
        cfg = DeviceConfig(conf)
        assert cfg.devices[0].power == "PPK2 Workshop"

    def test_power_field_absent(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[MPCB 1.10]\n"
            "mac=AA:BB:CC:DD:EE:FF\n"
        )
        cfg = DeviceConfig(conf)
        assert cfg.devices[0].power is None


class TestWhitespace:
    def test_key_value_whitespace(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[Board]\n"
            "  mac = AA:BB:CC:DD:EE:FF  \n"
            "  type = esp32  \n"
        )
        cfg = DeviceConfig(conf)
        assert cfg.devices[0].mac == "AA:BB:CC:DD:EE:FF"
        assert cfg.devices[0].type == "esp32"


# ── Device lookup ────────────────────────────────────────────────


class TestDeviceLookup:
    @pytest.fixture
    def cfg(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[MPCB 1.10 Development]\n"
            "mac=AA:AA:AA:AA:AA:AA\n"
            "type=esp32\n"
            "\n"
            "[MPCB 1.10 Development #2]\n"
            "mac=BB:BB:BB:BB:BB:BB\n"
            "type=esp32\n"
            "\n"
            "[MPCB 1.9 Development]\n"
            "mac=CC:CC:CC:CC:CC:CC\n"
            "type=esp32\n"
            "\n"
            "[MPCB 1.10 Development:ppk2]\n"
            "serial=E2794420999B\n"
            "type=ppk2\n"
            "\n"
            "[PPK2 Workshop]\n"
            "serial=C7749C622998\n"
            "type=ppk2\n"
        )
        return DeviceConfig(conf)

    def test_exact_match(self, cfg):
        results = cfg.find("MPCB 1.10 Development")
        assert len(results) == 1
        assert results[0].name == "MPCB 1.10 Development"

    def test_exact_match_case_insensitive(self, cfg):
        results = cfg.find("mpcb 1.10 development")
        assert len(results) == 1
        assert results[0].name == "MPCB 1.10 Development"

    def test_substring_match(self, cfg):
        results = cfg.find("1.10")
        assert len(results) == 2
        names = {d.name for d in results}
        assert names == {"MPCB 1.10 Development", "MPCB 1.10 Development #2"}

    def test_substring_excludes_partners(self, cfg):
        results = cfg.find("1.10")
        names = {d.name for d in results}
        assert "MPCB 1.10 Development:ppk2" not in names

    def test_regex_match(self, cfg):
        results = cfg.find("MPCB 1\\.(9|10)")
        assert len(results) == 3

    def test_no_match(self, cfg):
        results = cfg.find("nonexistent")
        assert len(results) == 0

    def test_find_by_name(self, cfg):
        d = cfg.get("MPCB 1.10 Development")
        assert d is not None
        assert d.name == "MPCB 1.10 Development"

    def test_get_not_found(self, cfg):
        assert cfg.get("nonexistent") is None


# ── Partner API ──────────────────────────────────────────────────


class TestPartnerAPI:
    @pytest.fixture
    def cfg(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[MPCB 1.10 Development]\n"
            "mac=AA:AA:AA:AA:AA:AA\n"
            "type=esp32\n"
            "\n"
            "[MPCB 1.10 Development:ppk2]\n"
            "serial=E2794420999B\n"
            "type=ppk2\n"
            "\n"
            "[MPCB 1.10 Development:notecard]\n"
            "serial=dev:860322068097069\n"
            "type=notecard\n"
            "\n"
            "[MPCB 1.9 Development]\n"
            "mac=BB:BB:BB:BB:BB:BB\n"
            "type=esp32\n"
            "\n"
            "[PPK2 Workshop]\n"
            "serial=C7749C622998\n"
            "type=ppk2\n"
        )
        return DeviceConfig(conf)

    def test_find_partner_by_type(self, cfg):
        partner = cfg.partner("MPCB 1.10 Development", "ppk2")
        assert partner is not None
        assert partner.name == "MPCB 1.10 Development:ppk2"
        assert partner.type == "ppk2"

    def test_find_partner_notecard(self, cfg):
        partner = cfg.partner("MPCB 1.10 Development", "notecard")
        assert partner is not None
        assert partner.name == "MPCB 1.10 Development:notecard"

    def test_partner_not_found(self, cfg):
        partner = cfg.partner("MPCB 1.9 Development", "ppk2")
        assert partner is None

    def test_all_partners(self, cfg):
        partners = cfg.partners("MPCB 1.10 Development")
        assert len(partners) == 2
        types = {p.type for p in partners}
        assert types == {"ppk2", "notecard"}

    def test_no_partners(self, cfg):
        partners = cfg.partners("MPCB 1.9 Development")
        assert len(partners) == 0

    def test_partner_with_fuzzy_name(self, cfg):
        partner = cfg.partner("1.10 Development", "ppk2")
        assert partner is not None
        assert partner.name == "MPCB 1.10 Development:ppk2"

    def test_partner_of_partner_returns_none(self, cfg):
        partner = cfg.partner("MPCB 1.10 Development:ppk2", "notecard")
        assert partner is None


# ── Partner search via find ──────────────────────────────────────


class TestPartnerSearch:
    @pytest.fixture
    def cfg(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text(
            "[MPCB 1.10 Development]\n"
            "mac=AA:AA:AA:AA:AA:AA\n"
            "type=esp32\n"
            "\n"
            "[MPCB 1.10 Development:ppk2]\n"
            "serial=E2794420999B\n"
            "type=ppk2\n"
        )
        return DeviceConfig(conf)

    def test_find_partner_with_colon(self, cfg):
        results = cfg.find("1.10:ppk2")
        assert len(results) == 1
        assert results[0].name == "MPCB 1.10 Development:ppk2"

    def test_find_excludes_partners_without_colon(self, cfg):
        results = cfg.find("1.10")
        assert len(results) == 1
        assert results[0].name == "MPCB 1.10 Development"


# ── MAC normalization ────────────────────────────────────────────


class TestMACNormalization:
    def test_normalize(self):
        from usb_device.config import normalize_mac
        assert normalize_mac("AA:BB:CC:DD:EE:FF") == "aabbccddeeff"
        assert normalize_mac("aa-bb-cc-dd-ee-ff") == "aabbccddeeff"
        assert normalize_mac("AABBCCDDEEFF") == "aabbccddeeff"
        assert normalize_mac("aabbccddeeff") == "aabbccddeeff"


# ── Missing config file ─────────────────────────────────────────


class TestMissingConfig:
    def test_missing_file(self, tmp_path):
        conf = tmp_path / "nonexistent.conf"
        cfg = DeviceConfig(conf)
        assert len(cfg.devices) == 0

    def test_empty_file(self, tmp_path):
        conf = tmp_path / "devices.conf"
        conf.write_text("")
        cfg = DeviceConfig(conf)
        assert len(cfg.devices) == 0
