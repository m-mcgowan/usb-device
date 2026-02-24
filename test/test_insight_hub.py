#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# Unit tests for insight_hub.py — mock-based, no hardware required.

import json
import sys
import unittest
from io import BytesIO
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent))
import insight_hub


class FakeSerial:
    """Mock serial port that records writes and returns canned responses."""

    def __init__(self, responses=None):
        self.responses = list(responses or [])
        self.written = []
        self.is_open = True
        self.dtr = None

    def write(self, data):
        self.written.append(data)

    def flush(self):
        pass

    def readline(self):
        if self.responses:
            resp = self.responses.pop(0)
            if isinstance(resp, str):
                return (resp + "\n").encode()
            return resp
        return b""

    def reset_input_buffer(self):
        pass

    def close(self):
        self.is_open = False


class TestHubConnection(unittest.TestCase):

    @patch("insight_hub.pyserial", create=True)
    def test_send_returns_parsed_json(self, _mock_pyserial):
        fake = FakeSerial([json.dumps({"status": "ok", "data": {"CH1": {"powerEn": True}}})])
        conn = insight_hub.HubConnection.__new__(insight_hub.HubConnection)
        conn._ser = fake

        result = conn.send({"action": "get", "params": ["CH1"]})
        assert result["status"] == "ok"
        assert result["data"]["CH1"]["powerEn"] is True
        # Verify command was sent as compact JSON + newline
        sent = fake.written[0].decode()
        assert sent.endswith("\n")
        parsed = json.loads(sent.strip())
        assert parsed["action"] == "get"

    @patch("insight_hub.pyserial", create=True)
    def test_send_returns_none_on_empty_response(self, _):
        fake = FakeSerial([])
        conn = insight_hub.HubConnection.__new__(insight_hub.HubConnection)
        conn._ser = fake

        result = conn.send({"action": "get", "params": ["CH1"]})
        assert result is None

    @patch("insight_hub.pyserial", create=True)
    def test_send_returns_none_on_bad_json(self, _):
        fake = FakeSerial(["not json at all"])
        conn = insight_hub.HubConnection.__new__(insight_hub.HubConnection)
        conn._ser = fake

        result = conn.send({"action": "get", "params": ["CH1"]})
        assert result is None

    def test_close(self):
        fake = FakeSerial()
        conn = insight_hub.HubConnection.__new__(insight_hub.HubConnection)
        conn._ser = fake
        conn.close()
        assert not fake.is_open

    def test_context_manager(self):
        fake = FakeSerial()
        conn = insight_hub.HubConnection.__new__(insight_hub.HubConnection)
        conn._ser = fake
        with conn:
            assert fake.is_open
        assert not fake.is_open


class TestHubFunctions(unittest.TestCase):

    def _make_conn(self, responses):
        fake = FakeSerial(responses)
        conn = insight_hub.HubConnection.__new__(insight_hub.HubConnection)
        conn._ser = fake
        return conn, fake

    def test_hub_set_success(self):
        conn, _ = self._make_conn([json.dumps({"status": "ok"})])
        assert insight_hub.hub_set(conn, "CH1", {"powerEn": "true"}) is True

    def test_hub_set_failure(self):
        conn, _ = self._make_conn([json.dumps({"status": "error"})])
        assert insight_hub.hub_set(conn, "CH1", {"powerEn": "true"}) is False

    def test_hub_get_returns_data(self):
        resp = {"status": "ok", "data": {"CH1": {"voltage": "5019.9"}}}
        conn, _ = self._make_conn([json.dumps(resp)])
        data = insight_hub.hub_get(conn, "CH1")
        assert data["CH1"]["voltage"] == "5019.9"

    def test_hub_get_returns_none_on_error(self):
        conn, _ = self._make_conn([json.dumps({"status": "error"})])
        assert insight_hub.hub_get(conn, "CH1") is None

    def test_hub_query_channel(self):
        resp = {"status": "ok", "data": {"CH2": {"powerEn": True, "voltage": "5000"}}}
        conn, _ = self._make_conn([json.dumps(resp)])
        state = insight_hub.hub_query_channel(conn, "CH2")
        assert state["powerEn"] is True
        assert state["voltage"] == "5000"

    def test_hub_power_on_verified(self):
        # First call: set powerEn=true → ok
        # Second call: get CH1 → powerEn: true (verification)
        set_resp = json.dumps({"status": "ok"})
        get_resp = json.dumps({"status": "ok", "data": {"CH1": {"powerEn": True}}})
        conn, _ = self._make_conn([set_resp, get_resp])
        assert insight_hub.hub_power(conn, "CH1", True) is True

    def test_hub_power_off_verified(self):
        set_resp = json.dumps({"status": "ok"})
        get_resp = json.dumps({"status": "ok", "data": {"CH1": {"powerEn": False}}})
        conn, _ = self._make_conn([set_resp, get_resp])
        assert insight_hub.hub_power(conn, "CH1", False) is True

    def test_hub_power_verify_mismatch(self):
        # Set succeeds but verify shows wrong state
        set_resp = json.dumps({"status": "ok"})
        get_resp = json.dumps({"status": "ok", "data": {"CH1": {"powerEn": True}}})
        conn, _ = self._make_conn([set_resp, get_resp])
        # Requesting off but verify shows True
        assert insight_hub.hub_power(conn, "CH1", False) is False

    def test_hub_power_set_fails(self):
        conn, _ = self._make_conn([json.dumps({"status": "error"})])
        assert insight_hub.hub_power(conn, "CH1", True) is False


class TestLocationToChannel(unittest.TestCase):

    def test_valid_ports(self):
        assert insight_hub.location_to_channel("20-3", 1) == "CH1"
        assert insight_hub.location_to_channel("20-3", "2") == "CH2"
        assert insight_hub.location_to_channel("20-3", "3") == "CH3"

    def test_invalid_ports(self):
        assert insight_hub.location_to_channel("20-3", 0) is None
        assert insight_hub.location_to_channel("20-3", 4) is None
        assert insight_hub.location_to_channel("20-3", "abc") is None
        assert insight_hub.location_to_channel("20-3", None) is None


class TestFormatChannelSummary(unittest.TestCase):

    def test_power_on_with_data(self):
        state = {"powerEn": True, "dataEn": True, "voltage": "5019.9", "current": "120.5"}
        s = insight_hub.format_channel_summary("CH1", state)
        assert "CH1:" in s
        assert "power=ON" in s
        assert "data" in s
        assert "5019.9mV" in s
        assert "120.5mA" in s

    def test_power_off_no_data(self):
        state = {"powerEn": False, "dataEn": False, "voltage": "0.0", "current": "0.0"}
        s = insight_hub.format_channel_summary("CH2", state)
        assert "power=OFF" in s
        assert "no-data" in s

    def test_alerts(self):
        state = {"powerEn": True, "dataEn": True, "fwdAlert": True, "backAlert": True, "shortAlert": True}
        s = insight_hub.format_channel_summary("CH3", state)
        assert "FWD-ALERT" in s
        assert "BACK-ALERT" in s
        assert "SHORT" in s


class TestFindInsightHub(unittest.TestCase):

    @patch("insight_hub.comports")
    def test_found_by_product(self, mock_comports):
        port = MagicMock()
        port.product = insight_hub.INSIGHT_HUB_PRODUCT
        port.vid = 0
        port.pid = 0
        port.device = "/dev/cu.usbmodemHUB1"
        port.location = "20-3.4"
        mock_comports.return_value = [port]

        dev, loc = insight_hub.find_insight_hub()
        assert dev == "/dev/cu.usbmodemHUB1"
        assert loc == "20-3"  # parent hub (strip last component)

    @patch("insight_hub.comports")
    def test_found_by_vid_pid(self, mock_comports):
        port = MagicMock()
        port.product = "SomeOtherName"
        port.vid = insight_hub.INSIGHT_HUB_VID
        port.pid = insight_hub.INSIGHT_HUB_PID
        port.device = "/dev/cu.usbmodemHUB2"
        port.location = "10-2.3"
        mock_comports.return_value = [port]

        dev, loc = insight_hub.find_insight_hub()
        assert dev == "/dev/cu.usbmodemHUB2"
        assert loc == "10-2"

    @patch("insight_hub.comports")
    def test_not_found(self, mock_comports):
        mock_comports.return_value = []
        dev, loc = insight_hub.find_insight_hub()
        assert dev is None
        assert loc is None

    @patch("insight_hub.comports")
    def test_no_location(self, mock_comports):
        port = MagicMock()
        port.product = insight_hub.INSIGHT_HUB_PRODUCT
        port.vid = 0
        port.pid = 0
        port.device = "/dev/cu.usbmodemHUB1"
        port.location = None
        mock_comports.return_value = [port]

        dev, loc = insight_hub.find_insight_hub()
        assert dev == "/dev/cu.usbmodemHUB1"
        assert loc is None


if __name__ == "__main__":
    unittest.main()
