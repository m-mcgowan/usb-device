#!/bin/bash
# Shared helpers for pioupload, piotest, piomonitor, piorun.
# Source this file — do not execute directly.

# Return 0 if any argument is --help or -h.
pio_check_help() {
    for arg in "$@"; do
        case "$arg" in
            --help|-h) return 0 ;;
        esac
    done
    return 1
}

# Parse arguments: last arg is device name, rest are pass-through.
# Falls back to DEVICE_NAME env var (set by piodevlock) when no device arg given.
# Sets: PIO_DEV, PIO_ARGS
pio_parse_args() {
    if [ $# -lt 1 ]; then
        if [ -n "${DEVICE_NAME:-}" ]; then
            PIO_DEV="$DEVICE_NAME"
            PIO_ARGS=()
            return 0
        fi
        return 1
    fi
    PIO_DEV="${@:$#}"
    PIO_ARGS=("${@:1:$#-1}")
}

# Set up logging to logs/<prefix>-<datetime>.log
# Sets: PIO_LOGFILE, appends to PIO_LOGFILES
PIO_LOGFILES=()
pio_log_setup() {
    local prefix="$1"
    mkdir -p logs
    PIO_LOGFILE="logs/${prefix}-$(date +%Y%m%d-%H%M%S).log"
    PIO_LOGFILES+=("$PIO_LOGFILE")
    echo "Logging to $PIO_LOGFILE"
}

# Run a command with tee to the logfile, preserving exit code.
pio_exec() {
    "$@" 2>&1 | tee -a "$PIO_LOGFILE"
    return "${PIPESTATUS[0]}"
}

# Acquire device lock if not already held. Sets PIO_LOCK_ACQUIRED=1 if we took it.
# Re-entrant: if an ancestor process holds the lock, checkout refreshes it.
# Unsets PIO_LABGRID_DEVICE to prevent pio-labgrid from attempting its own lock —
# these scripts handle port resolution and locking themselves.
pio_lock() {
    PIO_LOCK_ACQUIRED=0
    unset PIO_LABGRID_DEVICE
    local dev="$1"
    local purpose="${2:-pio}"
    usb-device checkout --pid $$ --purpose "$purpose" --ttl 3600 "$dev" 2>/dev/null
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        PIO_LOCK_ACQUIRED=1
        export USB_DEVICE_LOCK_PID=$$
    else
        echo "error: could not acquire lock on '$dev'" >&2
        return 1
    fi
    return 0
}

# Release device lock only if we acquired it.
pio_unlock() {
    if [ "${PIO_LOCK_ACQUIRED:-0}" -eq 1 ]; then
        usb-device checkin "$PIO_DEV" 2>/dev/null || true
        PIO_LOCK_ACQUIRED=0
    fi
}

# Trap handler for clean exit.
pio_cleanup() {
    pio_unlock
    for lf in ${PIO_LOGFILES[@]+"${PIO_LOGFILES[@]}"}; do
        [ -f "$lf" ] && echo "Log saved to $lf"
    done
}
