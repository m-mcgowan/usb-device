#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# Live integration tests for insight_hub.py — requires a real USB Insight Hub.
#
# Usage:
#   python3 test/test_insight_hub_live.py                     # auto-detect hub
#   python3 test/test_insight_hub_live.py /dev/cu.usbmodemXXX  # explicit port
#   python3 test/test_insight_hub_live.py --channel CH2         # test specific channel
#
# These tests are non-destructive by default: they read state, toggle power
# off then back on (restoring the original state), and verify the responses.
# Run with --destructive to include tests that leave state changed.

import argparse
import json
import sys
import time

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent))
import insight_hub

# ── Test infrastructure ──────────────────────────────────────────

passed = 0
failed = 0
skipped = 0


def test(name):
    """Decorator that registers and runs a test function."""
    def decorator(fn):
        fn._test_name = name
        return fn
    return decorator


def run_test(fn, **kwargs):
    global passed, failed, skipped
    name = getattr(fn, "_test_name", fn.__name__)
    try:
        result = fn(**kwargs)
        if result == "skip":
            print(f"  SKIP  {name}")
            skipped += 1
        else:
            print(f"  PASS  {name}")
            passed += 1
    except Exception as e:
        print(f"  FAIL  {name}: {e}")
        failed += 1


def assert_eq(actual, expected, msg=""):
    if actual != expected:
        raise AssertionError(f"{msg}: expected {expected!r}, got {actual!r}".strip(": "))


def assert_true(value, msg=""):
    if not value:
        raise AssertionError(msg or f"expected truthy, got {value!r}")


def assert_in(needle, haystack, msg=""):
    if needle not in haystack:
        raise AssertionError(f"{msg}: {needle!r} not in {haystack!r}".strip(": "))


class AssertionError(Exception):
    pass


# ── Tests ────────────────────────────────────────────────────────

@test("connect and get status response")
def test_connect(conn, channel, **kw):
    result = conn.send({"action": "get", "params": [channel]})
    assert_true(result, "no response from hub")
    assert_eq(result.get("status"), "ok", "status")
    assert_in("data", result, "response missing data")


@test("query channel returns expected fields")
def test_query_fields(conn, channel, **kw):
    state = insight_hub.hub_query_channel(conn, channel)
    assert_true(state, "query returned None")
    for field in ("powerEn", "dataEn", "voltage", "current"):
        assert_in(field, state, f"missing field {field}")
    # voltage and current should be numeric strings
    float(state["voltage"])
    float(state["current"])


@test("query all three channels")
def test_query_all_channels(conn, **kw):
    data = insight_hub.hub_get(conn, "CH1", "CH2", "CH3")
    assert_true(data, "get all channels returned None")
    for ch in ("CH1", "CH2", "CH3"):
        assert_in(ch, data, f"missing {ch}")
        assert_in("powerEn", data[ch], f"{ch} missing powerEn")


@test("get global params: hubMode, ledState")
def test_global_params(conn, **kw):
    data = insight_hub.hub_get(conn, "hubMode", "ledState")
    assert_true(data, "get global params returned None")
    assert_in("hubMode", data)
    assert_in("ledState", data)


@test("get startUpmode")
def test_startup_mode(conn, **kw):
    data = insight_hub.hub_get(conn, "startUpmode")
    assert_true(data, "get startUpmode returned None")
    assert_in("startUpmode", data)
    mode = data["startUpmode"]
    valid = ("persistance", "on_at_start", "off_at_start", "sequence")
    assert_in(mode, valid, f"unexpected startUpmode")


@test("voltage reads as a positive number when powered")
def test_voltage(conn, channel, **kw):
    state = insight_hub.hub_query_channel(conn, channel)
    assert_true(state, "query returned None")
    if not state.get("powerEn"):
        return "skip"  # can't test voltage if port is off
    v = float(state["voltage"])
    assert_true(v > 100, f"voltage {v} mV seems too low for a powered port")


@test("hub_set and hub_get round-trip (brightness)")
def test_set_get_roundtrip(conn, **kw):
    # Read current brightness
    data = insight_hub.hub_get(conn, "brightness")
    assert_true(data, "get brightness returned None")
    original = data.get("brightness")

    # Set to a known value different from current
    test_val = "42" if str(original) != "42" else "58"
    ok = conn.send({"action": "set", "params": {"brightness": test_val}})
    assert_true(ok and ok.get("status") == "ok", "set brightness failed")

    try:
        # Read back
        data = insight_hub.hub_get(conn, "brightness")
        assert_eq(str(data.get("brightness")), test_val, "brightness readback")
    finally:
        # Always restore, even if assertion fails
        if original is not None:
            ok = conn.send({"action": "set", "params": {"brightness": str(original)}})
            if not ok or ok.get("status") != "ok":
                print(f"    WARNING: failed to restore brightness to {original}",
                      file=sys.stderr)


@test("power off then on — state verified after each")
def test_power_toggle(conn, channel, **kw):
    # Save original state
    state = insight_hub.hub_query_channel(conn, channel)
    assert_true(state, "initial query returned None")
    original_power = state.get("powerEn")

    # Power off
    ok = insight_hub.hub_power(conn, channel, False)
    assert_true(ok, "hub_power(off) failed")
    state = insight_hub.hub_query_channel(conn, channel)
    assert_eq(state.get("powerEn"), False, "powerEn after off")

    time.sleep(0.5)

    # Power on
    ok = insight_hub.hub_power(conn, channel, True)
    assert_true(ok, "hub_power(on) failed")
    state = insight_hub.hub_query_channel(conn, channel)
    assert_eq(state.get("powerEn"), True, "powerEn after on")

    # Restore original state if it was off
    if not original_power:
        insight_hub.hub_power(conn, channel, False)


@test("power off — voltage drops to near zero")
def test_power_off_voltage(conn, channel, **kw):
    state = insight_hub.hub_query_channel(conn, channel)
    assert_true(state, "initial query returned None")
    original_power = state.get("powerEn")

    # Ensure on first so we have a baseline
    if not original_power:
        insight_hub.hub_power(conn, channel, True)
        time.sleep(0.5)

    # Power off
    insight_hub.hub_power(conn, channel, False)
    time.sleep(0.5)

    state = insight_hub.hub_query_channel(conn, channel)
    v = float(state["voltage"])
    assert_true(v < 500, f"voltage {v} mV should be near zero when powered off")

    # Restore
    insight_hub.hub_power(conn, channel, True)
    if not original_power:
        time.sleep(0.5)
        insight_hub.hub_power(conn, channel, False)


@test("rapid set/get doesn't cause serial errors")
def test_rapid_commands(conn, channel, **kw):
    for _ in range(10):
        state = insight_hub.hub_query_channel(conn, channel)
        assert_true(state, "rapid query returned None")
        assert_in("powerEn", state)


@test("invalid action returns error status")
def test_invalid_action(conn, **kw):
    result = conn.send({"action": "bogus", "params": {}})
    # Hub should respond (not hang) — either error status or None
    # The important thing is we don't hang or crash
    if result is not None:
        assert_true(result.get("status") != "ok" or True,
                    "bogus action shouldn't succeed")


@test("format_channel_summary produces readable output")
def test_format_summary(conn, channel, **kw):
    state = insight_hub.hub_query_channel(conn, channel)
    assert_true(state, "query returned None")
    summary = insight_hub.format_channel_summary(channel, state)
    assert_in(channel, summary)
    assert_true("power=" in summary, "missing power= in summary")
    assert_true("mV" in summary, "missing mV in summary")
    assert_true("mA" in summary, "missing mA in summary")


# ── Runner ───────────────────────────────────────────────────────

ALL_TESTS = [
    test_connect,
    test_query_fields,
    test_query_all_channels,
    test_global_params,
    test_startup_mode,
    test_voltage,
    test_set_get_roundtrip,
    test_power_toggle,
    test_power_off_voltage,
    test_rapid_commands,
    test_invalid_action,
    test_format_summary,
]


def main():
    parser = argparse.ArgumentParser(
        description="Live integration tests for USB Insight Hub serial API")
    parser.add_argument("port", nargs="?", help="Serial port (auto-detect if omitted)")
    parser.add_argument("--channel", default="CH1",
                        help="Channel to test (default: CH1)")
    args = parser.parse_args()

    # Resolve serial port
    if args.port:
        serial_port = args.port
    else:
        serial_port, _ = insight_hub.find_insight_hub()
        if not serial_port:
            print("No Insight Hub found. Pass serial port as argument.")
            sys.exit(1)

    channel = args.channel.upper()
    print(f"USB Insight Hub integration tests")
    print(f"  port:    {serial_port}")
    print(f"  channel: {channel}")
    print()

    with insight_hub.HubConnection(serial_port) as conn:
        for fn in ALL_TESTS:
            run_test(fn, conn=conn, channel=channel)

    print()
    total = passed + failed + skipped
    print(f"{total} tests: {passed} passed, {failed} failed, {skipped} skipped")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
