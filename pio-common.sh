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

# Resolve the default device when no device arg given. Sets PIO_DEV.
# Resolution: DEVICE_NAME env → single locked device → prompt if interactive → error.
# Returns: 0=resolved, 1=no devices, 2=ambiguous/error.
_pio_resolve_device() {
    # 1. Explicit default
    if [ -n "${DEVICE_NAME:-}" ]; then
        PIO_DEV="$DEVICE_NAME"
        return 0
    fi

    # 2-3. Check locked devices in this session
    local locked=()
    while IFS= read -r name; do
        [ -n "$name" ] && locked+=("$name")
    done < <(usb-device locks --mine 2>/dev/null)

    if [ ${#locked[@]} -eq 1 ]; then
        PIO_DEV="${locked[0]}"
        return 0
    fi

    if [ ${#locked[@]} -gt 1 ] && [ -t 0 ]; then
        echo "Multiple devices locked — select one:" >&2
        local i
        for i in "${!locked[@]}"; do
            echo "  $((i+1))) ${locked[$i]}" >&2
        done
        printf "Select [1-%d]: " "${#locked[@]}" >&2
        local choice
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#locked[@]} ]; then
            PIO_DEV="${locked[$((choice - 1))]}"
            return 0
        fi
        echo "error: invalid selection" >&2
        return 2
    fi

    if [ ${#locked[@]} -gt 1 ]; then
        echo "error: multiple devices locked — specify which one" >&2
        return 2
    fi

    # No default and no locked devices
    return 1
}

# Parse arguments: last arg is device name, rest are pass-through.
# When no device arg given, resolves via:
#   1. DEVICE_NAME env var (explicit default from piodev/piodevlock)
#   2. Single locked device in this session (auto-select)
#   3. Multiple locked devices + interactive TTY (prompt)
#   4. Otherwise error
# Sets: PIO_DEV, PIO_ARGS
pio_parse_args() {
    if [ $# -ge 1 ]; then
        PIO_DEV="${@:$#}"
        PIO_ARGS=("${@:1:$#-1}")
        return 0
    fi

    PIO_ARGS=()
    _pio_resolve_device || return $?
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
# Re-entrant: if an ancestor process holds the lock, we join without taking ownership.
# Exit codes from checkout: 0=acquired/refreshed, 2=joined (parent holds lock).
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
        # We own the lock — release it on exit
        PIO_LOCK_ACQUIRED=1
        export USB_DEVICE_LOCK_PID=$$
    elif [ "$rc" -eq 2 ]; then
        # Joined parent's lock — don't release on exit
        PIO_LOCK_ACQUIRED=0
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
