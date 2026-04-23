# DX Notes

Feedback from heavy `usb-device` use while building a long-running power
profiler consumer (`measure_longrun.py`) that needs to resolve the DUT's
USB-CDC port across wake/sleep cycles. Light compared to the embedded-trace
and ppk2-python feedback — `usb-device` is mostly solid — but there are a
few ergonomic gaps worth flagging.

## Friction

### `usb-device port DEVICE` fails hard when the device is asleep

Scenario: the DUT is in deep sleep, so its USB-CDC port has de-enumerated
from the host. The user code has power-cycled the DUT (via a PPK2 daemon)
and wants to get the new `/dev/cu.*` path as soon as the device finishes
booting.

Current behaviour: `usb-device port 'MPCB 1.10 Development'` returns
non-zero with `error: no serial port found for '…'`, no retry, no wait.

Consumers end up writing a retry-with-backoff wrapper:

```bash
for _ in $(seq 15); do
    PORT=$(usb-device port "$DEV" 2>/dev/null) && [ -n "$PORT" ] && break
    sleep 1
done
```

Or the Python equivalent. I wrote this twice across two scripts this
session.

Suggested additions:

1. **`usb-device port --wait SECS DEVICE`** — blocks up to `SECS` polling
   for the port to appear. Returns the path when it does, times out with
   a distinct non-zero exit.
2. **`usb-device wait-online DEVICE`** — no path output, just exits 0
   when the device is detected. Handy as a gate in scripts.

Both can share the existing scan cache — no new infrastructure needed.

### `usb-device scan` behaviour in scripts

`usb-device scan` is the right command to refresh caches, but its stdout
is human-formatted ("Scanning USB bus...", colored status tags) which
makes it awkward to drive from a Python script. I ended up parsing it
with regex when I wanted the port of a just-re-enumerated device.

A `--format json` flag (or a sister command `usb-device list --json`)
would make it a first-class scripting primitive.

### `usb-device checkout --any --purpose "..." --pid $PPID` is great, but …

The structured stdout (`DEVICE_NAME='…'`, `DEVICE_PORT='…'`,
`DEVICE_TYPE='…'`) works well and I used it unchanged. Two small things:

1. It prints **both to stdout (the vars) and stderr (the "Checked out"
   message)**. Piping only stdout captures the vars but loses the
   useful status; piping both interleaves. A `--quiet` flag to
   suppress the stderr message would be helpful in scripts.
2. When acquisition fails, the skip reasons go to stderr without any
   structured form. Something like `SKIP_REASON='offline'` in stdout
   would make error handling cleaner in scripts.

### The `piomonitor`/`piotest` helpers aren't on the standard PATH

This is mostly an install-docs issue — the scripts live in the repo
root but aren't obviously installable beyond `~/e/usb-device/` being on
PATH. `install.sh` exists but it's not called out prominently in the
README's "getting started" for someone who didn't clone the repo in a
specific spot.

A clearer "install to PATH" line in the README (or a `brew`-style
instruction) would help.

## Positive — things that worked well

- The `checkout`/`checkin` locking model with `--pid $PPID` is exactly
  the right design for tool composition. The `--any` flag is
  particularly nice for CI/test scripts.
- `usb-device scan` caching + refresh-on-failure is the right default.
- Device-name disambiguation via fuzzy matching ("1.10" → "MPCB 1.10
  Development") is convenient for interactive use. The explicit
  fallback to full name for scripts is the right split.
- Structured stdout for checkout output is a small thing but makes
  automation much easier than trying to parse a log line.

## Summary

The main ask is **`--wait` on `usb-device port`**. That alone would
eliminate the most common boilerplate consumers write. `--format json`
on scan/list would make the second-most-common task trivial.
