# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# serial_monitor.py — invoked by serial-monitor shell wrapper
"""serial-monitor — Serial monitor with device reset and bootloader support.

A replacement for `pio device monitor` that integrates with usb-device
for named device lookup, and supports reset/bootloader entry via serial.

Usage:
    serial-monitor [options] [device-name-or-port]

Examples:
    serial-monitor "1.9"                  # monitor by device name (fuzzy match)
    serial-monitor /dev/cu.usbmodem142101 # monitor by port path
    serial-monitor "1.9" -b 115200        # custom baud rate
    serial-monitor "1.9" --timeout 30     # capture for 30 seconds then exit
    serial-monitor "1.9" --reset          # reset device before monitoring
    serial-monitor "1.9" --bootloader     # enter bootloader (RTS/DTR sequence)
    serial-monitor "1.9" --send T --timeout 10   # send 'T' then capture 10s
    serial-monitor "1.9" --send '@2xT' --send '@5xa' --timeout 60
                                          # send 'T' after 2s, 'a' after 5s more

Interactive keys (TTY only):
    Ctrl-R    Reset device (1200 baud touch)
    Ctrl-B    Enter bootloader (RTS/DTR sequence)
    Ctrl-T    Toggle timestamps
    Ctrl-C    Quit
"""

import argparse
import codecs
import re
import os
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime

# Lazy imports for TTY-only modules
termios = None
tty = None


def resolve_port(name_or_port: str) -> str:
    """Resolve a device name or port path to a /dev/cu.* path."""
    if name_or_port.startswith("/dev/"):
        return name_or_port

    usb_device = os.path.join(os.path.dirname(os.path.abspath(__file__)), "usb-device")
    try:
        result = subprocess.run(
            [usb_device, "port", name_or_port],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Fallback: pyserial direct lookup
    try:
        from serial.tools.list_ports import comports
        name_lower = name_or_port.lower()
        for p in comports():
            if (p.serial_number and name_lower in p.serial_number.lower()) or \
               (p.description and name_lower in p.description.lower()):
                return p.device
    except ImportError:
        pass

    print(f"error: could not resolve '{name_or_port}' to a serial port", file=sys.stderr)
    sys.exit(1)


def reset_via_baud_touch(port: str, baud: int = 1200):
    """Reset an ESP32 by opening the port at 1200 baud and closing it."""
    import serial
    print(f"[monitor] Resetting via {baud} baud touch on {port}...", file=sys.stderr)
    try:
        with serial.Serial(port, baud) as s:
            s.dtr = False
            time.sleep(0.1)
        time.sleep(0.5)
    except serial.SerialException as e:
        print(f"[monitor] Reset failed: {e}", file=sys.stderr)


def enter_bootloader_rts_dtr(port: str, baud: int = 115200):
    """Enter ESP32 bootloader using the classic RTS/DTR sequence."""
    import serial
    print(f"[monitor] Entering bootloader via RTS/DTR on {port}...", file=sys.stderr)
    try:
        with serial.Serial(port, baud) as s:
            s.dtr = False
            s.rts = True
            time.sleep(0.1)
            s.dtr = True
            s.rts = False
            time.sleep(0.05)
            s.dtr = False
        time.sleep(0.5)
        print("[monitor] Bootloader entry sequence sent.", file=sys.stderr)
    except serial.SerialException as e:
        print(f"[monitor] Bootloader entry failed: {e}", file=sys.stderr)


def power_reset(name_or_port: str, force: bool = False):
    """Reset a device via usb-device power cycling."""
    usb_device = os.path.join(os.path.dirname(os.path.abspath(__file__)), "usb-device")
    args = [usb_device, "reset"]
    if force:
        args.append("-f")
    args.append(name_or_port)
    print(f"[monitor] Power-cycling via usb-device...", file=sys.stderr)
    subprocess.run(args, timeout=30)


class SerialMonitor:
    def __init__(self, port: str, baud: int = 115200, timestamps: bool = False,
                 timeout: float = 0, exit_patterns: list = None,
                 reconnect_timeout: float = 0):
        self.port = port
        self.baud = baud
        self.timestamps = timestamps
        self.timeout = timeout
        self.reconnect_timeout = reconnect_timeout
        self.running = False
        self._ser = None
        self._old_term = None
        self._send_queue = []  # list of (delay_secs, bytes_data)
        self._exit_patterns = [re.compile(p) for p in (exit_patterns or [])]

    def queue_send(self, data: bytes, delay: float = 0):
        """Queue data to send after connection opens. Delay is seconds to wait before sending."""
        self._send_queue.append((delay, data))

    def _open(self):
        import serial
        retries = 0
        rt = self.reconnect_timeout if self.reconnect_timeout else (10 if self.timeout else 0)
        max_retries = int(rt / 0.5) if rt else 0  # 0 = unlimited
        # Acquire an exclusive advisory lock on the serial port so a second
        # monitor instance can't fight over it. Unix serial TTYs allow
        # multiple readers by default, which silently splits the byte stream.
        import fcntl
        while max_retries == 0 or retries < max_retries:
            try:
                # Belt-and-suspenders exclusive access:
                # 1. pyserial `exclusive=True` → calls TIOCEXCL on the fd.
                #    Honored by other TIOCEXCL-aware openers (reliable on
                #    Linux, inconsistent on macOS).
                # 2. flock(LOCK_EX | LOCK_NB) → portable advisory lock
                #    honored by any flock-aware process on both platforms.
                ser = serial.Serial(self.port, self.baud, timeout=0.1, exclusive=True)
                try:
                    fcntl.flock(ser.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except (OSError, BlockingIOError):
                    # Another process holds the lock. Close and retry (it may
                    # exit soon) rather than silently sharing the port.
                    ser.close()
                    if retries == 0:
                        print(f"[monitor] {self.port} is in use by another process, waiting...",
                              file=sys.stderr)
                    raise serial.SerialException("port locked by another process")
                self._ser = ser
                if retries > 0:
                    print(f"[monitor] Reconnected after {retries * 0.5:.0f}s", file=sys.stderr)
                return
            except serial.SerialException:
                retries += 1
                if retries == 1:
                    print(f"[monitor] Waiting for {self.port}...", file=sys.stderr)
                time.sleep(0.5)
        print(f"[monitor] error: could not open {self.port} after {retries * 0.5:.0f}s", file=sys.stderr)
        sys.exit(1)

    def _close(self):
        if self._ser:
            try:
                self._ser.close()
            except Exception:
                pass
            self._ser = None

    def _read_loop(self):
        """Read from serial and write to stdout. Runs until self.running is False."""
        line_start = True
        line_buf = []
        # Incremental decoder buffers incomplete multi-byte UTF-8 sequences
        # across read boundaries instead of emitting replacement characters
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        while self.running:
            try:
                data = self._ser.read(self._ser.in_waiting or 1)
            except Exception:
                if not self.running:
                    break
                print(f"\n[monitor] Connection lost. Reconnecting...", file=sys.stderr)
                self._reconnect()
                decoder.reset()
                continue

            if not data:
                continue

            text = decoder.decode(data)
            for ch in text:
                if line_start and self.timestamps:
                    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
                    sys.stdout.write(f"[{ts}] ")
                    line_start = False
                sys.stdout.write(ch)
                if ch == "\n":
                    line_start = True
                    if self._exit_patterns:
                        line = "".join(line_buf)
                        line_buf.clear()
                        for pat in self._exit_patterns:
                            if pat.search(line):
                                sys.stdout.flush()
                                print(f"\n[monitor] Exit pattern matched: {pat.pattern}", file=sys.stderr)
                                self.running = False
                                return
                elif ch != "\r":
                    line_buf.append(ch)
            sys.stdout.flush()

    def _reconnect(self):
        self._close()
        time.sleep(1)
        self._open()

    def _handle_key(self, ch: bytes) -> bool:
        """Handle a keypress. Returns False to quit."""
        if ch == b"\x03":  # Ctrl-C
            return False
        elif ch == b"\x12":  # Ctrl-R — reset
            self._close()
            reset_via_baud_touch(self.port)
            self._open()
        elif ch == b"\x02":  # Ctrl-B — bootloader
            self._close()
            enter_bootloader_rts_dtr(self.port)
            self._open()
        elif ch == b"\x14":  # Ctrl-T — toggle timestamps
            self.timestamps = not self.timestamps
            state = "on" if self.timestamps else "off"
            print(f"\n[monitor] Timestamps {state}", file=sys.stderr)
        else:
            if self._ser and self._ser.is_open:
                try:
                    self._ser.write(ch)
                except Exception:
                    pass
        return True

    def stop(self, *_args):
        """Signal-safe stop."""
        self.running = False

    def run(self):
        self._open()
        self.running = True
        interactive = os.isatty(sys.stdin.fileno())

        # Install signal handlers so SIGINT/SIGTERM stop cleanly
        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGTERM, self.stop)

        if interactive:
            print(f"[monitor] Opened {self.port} at {self.baud} baud", file=sys.stderr)
            print(f"[monitor] Ctrl-R=reset  Ctrl-B=bootloader  Ctrl-T=timestamps  Ctrl-C=quit", file=sys.stderr)
            print("---", file=sys.stderr)
        else:
            if self.timeout:
                print(f"[monitor] {self.port} @ {self.baud} baud (timeout {self.timeout}s)", file=sys.stderr)
            else:
                print(f"[monitor] {self.port} @ {self.baud} baud (kill to stop)", file=sys.stderr)

        # Start reader thread
        reader = threading.Thread(target=self._read_loop, daemon=True)
        reader.start()

        if interactive:
            self._run_interactive(reader)
        else:
            self._run_noninteractive(reader)

    def send(self, data: bytes):
        """Send data to the serial port."""
        if self._ser and self._ser.is_open:
            self._ser.write(data)

    def _run_noninteractive(self, reader):
        """Non-interactive: wait for timeout or signal."""
        try:
            # Send queued data if any
            if self._send_queue:
                for delay, data in self._send_queue:
                    if not self.running:
                        break
                    if delay > 0:
                        time.sleep(delay)
                    self.send(data)
                    print(f"[monitor] Sent: {data!r}", file=sys.stderr)

            if self.timeout:
                deadline = time.monotonic() + self.timeout
                while self.running and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.running = False
            else:
                # Sleep in short intervals so signals are handled promptly
                while self.running:
                    time.sleep(0.25)
        finally:
            self.running = False
            self._close()
            print("", file=sys.stderr)
            print("[monitor] Disconnected.", file=sys.stderr)

    def _run_interactive(self, reader):
        """Interactive: raw terminal with key handling."""
        global termios, tty
        import termios as _termios
        import tty as _tty
        termios = _termios
        tty = _tty

        fd = sys.stdin.fileno()
        self._old_term = termios.tcgetattr(fd)
        # Restore default signal handling so Ctrl-C goes through _handle_key
        signal.signal(signal.SIGINT, signal.SIG_DFL)
        try:
            # Custom raw mode: like tty.setraw() but keeps OPOST so the
            # terminal still translates \n → \r\n on output.  Without this,
            # serial data containing bare \n produces staircase output.
            raw = termios.tcgetattr(fd)
            raw[0] &= ~(termios.BRKINT | termios.ICRNL | termios.INPCK |
                         termios.ISTRIP | termios.IXON)       # iflag
            # raw[1] — oflag: keep OPOST enabled (don't clear it)
            raw[2] = (raw[2] & ~(termios.CSIZE | termios.PARENB)) | termios.CS8
            raw[3] &= ~(termios.ECHO | termios.ICANON |
                         termios.IEXTEN | termios.ISIG)        # lflag
            raw[6][termios.VMIN] = 1
            raw[6][termios.VTIME] = 0
            termios.tcsetattr(fd, termios.TCSAFLUSH, raw)
            while self.running:
                ch = os.read(fd, 1)
                if not ch or not self._handle_key(ch):
                    break
        finally:
            self.running = False
            termios.tcsetattr(fd, termios.TCSADRAIN, self._old_term)
            self._close()
            print("\n[monitor] Disconnected.", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="Serial monitor with device reset and bootloader support.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Interactive keys (TTY only):
  Ctrl-R    Reset device (1200 baud touch)
  Ctrl-B    Enter bootloader (RTS/DTR sequence)
  Ctrl-T    Toggle timestamps
  Ctrl-C    Quit"""
    )
    parser.add_argument("device", nargs="?", default=None,
                        help="Device name (fuzzy match via usb-device) or /dev/cu.* path")
    parser.add_argument("-b", "--baud", type=int, default=115200,
                        help="Baud rate (default: 115200)")
    parser.add_argument("-t", "--timestamps", action="store_true",
                        help="Show timestamps on each line")
    parser.add_argument("--timeout", type=float, default=0, metavar="SECS",
                        help="Exit after SECS seconds (0 = run until killed)")
    parser.add_argument("--reconnect-timeout", type=float, default=0, metavar="SECS",
                        help="Give up reconnecting after SECS seconds (0 = wait forever in interactive mode, 10s with --timeout)")
    parser.add_argument("--reset", action="store_true",
                        help="Reset device before monitoring (1200 baud touch)")
    parser.add_argument("--bootloader", action="store_true",
                        help="Enter bootloader before monitoring (RTS/DTR sequence)")
    parser.add_argument("--boot", action="store_true",
                        help="Exit bootloader (watchdog reset via esptool) before monitoring")
    parser.add_argument("--power-reset", action="store_true",
                        help="Power-cycle device via uhubctl before monitoring")
    parser.add_argument("-f", "--force", action="store_true",
                        help="Force power reset (skip hub confirmation)")
    parser.add_argument("--send", action="append", default=[], metavar="DATA",
                        help="Send DATA to serial after connecting (can repeat). "
                             "Use \\n for newline. Prefix with @SECSx to delay, "
                             "e.g. --send '@2xT' sends 'T' after 2s delay.")
    parser.add_argument("--exit-on", action="append", default=[], metavar="PATTERN",
                        help="Exit when a line matches this regex (can repeat). "
                             "Patterns without regex metacharacters match as plain strings.")
    parser.add_argument("--device-type", default=None, metavar="TYPE",
                        help=argparse.SUPPRESS)  # set by serial-monitor wrapper
    args = parser.parse_args()

    if not args.device:
        try:
            from serial.tools.list_ports import comports
            ports = sorted(comports(), key=lambda p: p.device)
            if ports:
                print("Available serial ports:")
                for p in ports:
                    sn = f"  SER={p.serial_number}" if p.serial_number else ""
                    print(f"  {p.device}  {p.description}{sn}")
            else:
                print("No serial ports found.")
        except ImportError:
            print("error: pyserial not installed", file=sys.stderr)
        sys.exit(0)

    port = resolve_port(args.device)

    if args.boot:
        # Exit bootloader via usb-device boot (esptool watchdog reset)
        usb_device = os.path.join(os.path.dirname(os.path.abspath(__file__)), "usb-device")
        print("[monitor] Exiting bootloader via esptool watchdog reset...", file=sys.stderr)
        subprocess.run([usb_device, "boot", args.device], timeout=15)
        time.sleep(2)
        port = resolve_port(args.device)
    elif args.power_reset:
        power_reset(args.device, force=args.force)
        time.sleep(2)
        port = resolve_port(args.device)
    elif args.bootloader:
        enter_bootloader_rts_dtr(port, args.baud)
    elif args.reset:
        reset_via_baud_touch(port)

    monitor = SerialMonitor(port, args.baud, args.timestamps, args.timeout,
                            exit_patterns=args.exit_on,
                            reconnect_timeout=args.reconnect_timeout)

    # Parse --send arguments
    for item in args.send:
        delay = 0.5  # default small delay to let device settle after connect
        data = item
        if data.startswith("@") and "x" in data:
            parts = data[1:].split("x", 1)
            try:
                delay = float(parts[0])
            except ValueError:
                pass
            data = parts[1]
        data = data.replace("\\n", "\n").replace("\\r", "\r")
        monitor.queue_send(data.encode("utf-8"), delay)

    monitor.run()


if __name__ == "__main__":
    main()
