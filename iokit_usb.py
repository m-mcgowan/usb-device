# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# iokit_usb.py — IOKit USB device event notifications via ctypes
"""Lightweight bridge to macOS IOKit for USB device add/remove events.

Zero dependencies beyond the system frameworks (IOKit, CoreFoundation)
and Python's ctypes stdlib module.

Usage:
    watcher = USBWatcher(on_event=lambda: print("USB change!"))
    watcher.start()      # background thread, returns immediately
    ...
    watcher.stop()       # clean shutdown

The callback fires on any USB device arrival or removal. It does NOT
tell you which device changed — the caller should re-scan (e.g. via
pyserial comports()) to diff the current state.
"""

import ctypes
import ctypes.util
import threading
from ctypes import CFUNCTYPE, POINTER, byref, c_bool, c_char_p, c_double
from ctypes import c_int32, c_uint32, c_void_p

# ── Load frameworks ───────────────────────────────────────────────

_iokit = ctypes.cdll.LoadLibrary(ctypes.util.find_library("IOKit"))
_cf = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))

# ── Constants ─────────────────────────────────────────────────────

_kIOUSBDeviceClassName = b"IOUSBHostDevice"
_kIOFirstMatchNotification = b"IOServiceFirstMatch"
_kIOTerminatedNotification = b"IOServiceTerminate"
_kCFRunLoopDefaultMode = c_void_p.in_dll(_cf, "kCFRunLoopDefaultMode")
_kIOMasterPortDefault = c_uint32(0)

# ── Function signatures ──────────────────────────────────────────

_iokit.IONotificationPortCreate.restype = c_void_p
_iokit.IONotificationPortCreate.argtypes = [c_uint32]

_iokit.IONotificationPortGetRunLoopSource.restype = c_void_p
_iokit.IONotificationPortGetRunLoopSource.argtypes = [c_void_p]

_iokit.IONotificationPortDestroy.restype = None
_iokit.IONotificationPortDestroy.argtypes = [c_void_p]

_iokit.IOServiceMatching.restype = c_void_p
_iokit.IOServiceMatching.argtypes = [c_char_p]

_IOServiceMatchingCallback = CFUNCTYPE(None, c_void_p, c_uint32)

_iokit.IOServiceAddMatchingNotification.restype = c_int32
_iokit.IOServiceAddMatchingNotification.argtypes = [
    c_void_p, c_char_p, c_void_p,
    _IOServiceMatchingCallback, c_void_p, POINTER(c_uint32),
]

_iokit.IOIteratorNext.restype = c_uint32
_iokit.IOIteratorNext.argtypes = [c_uint32]

_iokit.IOObjectRelease.restype = c_int32
_iokit.IOObjectRelease.argtypes = [c_uint32]

_cf.CFRunLoopGetCurrent.restype = c_void_p
_cf.CFRunLoopGetCurrent.argtypes = []

_cf.CFRunLoopAddSource.restype = None
_cf.CFRunLoopAddSource.argtypes = [c_void_p, c_void_p, c_void_p]

_cf.CFRunLoopRunInMode.restype = c_int32
_cf.CFRunLoopRunInMode.argtypes = [c_void_p, c_double, c_bool]

_cf.CFRunLoopStop.restype = None
_cf.CFRunLoopStop.argtypes = [c_void_p]


# ── Helpers ───────────────────────────────────────────────────────

def _drain_iterator(iterator):
    """Drain an IOKit iterator, releasing each object.

    Must be called after IOServiceAddMatchingNotification to arm the
    notification, and inside each callback to re-arm it.
    """
    while True:
        obj = _iokit.IOIteratorNext(iterator)
        if obj == 0:
            break
        _iokit.IOObjectRelease(obj)


# ── Public API ────────────────────────────────────────────────────

class USBWatcher:
    """Watch for USB device add/remove events via IOKit notifications.

    Runs a CFRunLoop on a background thread. Calls on_event() (no args)
    whenever a USB device is added or removed. The callback runs on the
    background thread — keep it fast or post to a queue.
    """

    def __init__(self, on_event):
        self._on_event = on_event
        self._thread = None
        self._run_loop = None
        self._notify_port = None
        # Must hold strong references to prevent GC of ctypes callbacks
        self._cb_added = _IOServiceMatchingCallback(self._on_added)
        self._cb_removed = _IOServiceMatchingCallback(self._on_removed)

    def _on_added(self, _refcon, iterator):
        _drain_iterator(iterator)
        self._on_event()

    def _on_removed(self, _refcon, iterator):
        _drain_iterator(iterator)
        self._on_event()

    def _run(self):
        """Background thread: set up notifications and run the CFRunLoop."""
        self._notify_port = _iokit.IONotificationPortCreate(_kIOMasterPortDefault)
        rls = _iokit.IONotificationPortGetRunLoopSource(self._notify_port)

        self._run_loop = _cf.CFRunLoopGetCurrent()
        _cf.CFRunLoopAddSource(self._run_loop, rls, _kCFRunLoopDefaultMode)

        # Subscribe to device additions
        add_iter = c_uint32(0)
        match_add = _iokit.IOServiceMatching(_kIOUSBDeviceClassName)
        _iokit.IOServiceAddMatchingNotification(
            self._notify_port, _kIOFirstMatchNotification, match_add,
            self._cb_added, None, byref(add_iter),
        )
        _drain_iterator(add_iter.value)  # arm

        # Subscribe to device removals
        rem_iter = c_uint32(0)
        match_rem = _iokit.IOServiceMatching(_kIOUSBDeviceClassName)
        _iokit.IOServiceAddMatchingNotification(
            self._notify_port, _kIOTerminatedNotification, match_rem,
            self._cb_removed, None, byref(rem_iter),
        )
        _drain_iterator(rem_iter.value)  # arm

        # Run until stopped
        # Use RunInMode with a long timeout so we can check periodically
        # if stop() was called (CFRunLoopStop breaks out of RunInMode)
        while self._run_loop is not None:
            _cf.CFRunLoopRunInMode(_kCFRunLoopDefaultMode, 60.0, False)

    def start(self):
        """Start watching in a background daemon thread."""
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        """Stop the watcher and clean up."""
        rl = self._run_loop
        self._run_loop = None  # signal loop exit
        if rl:
            _cf.CFRunLoopStop(rl)
        if self._thread:
            self._thread.join(timeout=2)
            self._thread = None
        if self._notify_port:
            _iokit.IONotificationPortDestroy(self._notify_port)
            self._notify_port = None
