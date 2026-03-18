#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Setup script for labgrid coordinator + exporter deployment.
#
# Installs dependencies into a Python venv, creates exporter.yaml from
# the template if needed, generates launchd plists with correct paths,
# and creates labgrid places for each resource group.
#
# Usage:
#   ./setup.sh              # install and configure
#   ./setup.sh start        # start services (without launchd)
#   ./setup.sh stop         # stop services
#   ./setup.sh status       # show coordinator and exporter status
#   ./setup.sh places       # create/update places from exporter.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABGRID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
USB_DEVICE_DIR="$(cd "$LABGRID_DIR/.." && pwd)"
VENV_DIR="$USB_DEVICE_DIR/.venv"
COORDINATOR_PORT="${LABGRID_PORT:-20408}"
COORDINATOR_ADDR="0.0.0.0:$COORDINATOR_PORT"
LG_COORDINATOR="localhost:$COORDINATOR_PORT"
EXPORTER_YAML="$SCRIPT_DIR/exporter.yaml"
FIXTURES_YAML="$SCRIPT_DIR/fixtures.yaml"
PLIST_DIR="$HOME/Library/LaunchAgents"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()  { echo "[setup] $*"; }
warn()  { echo "[setup] WARNING: $*" >&2; }
die()   { echo "[setup] ERROR: $*" >&2; exit 1; }

venv_python() { "$VENV_DIR/bin/python" "$@"; }
venv_pip()    { "$VENV_DIR/bin/pip" "$@"; }
labgrid_client() { "$VENV_DIR/bin/labgrid-client" -x "$LG_COORDINATOR" "$@"; }

# ── Install ──────────────────────────────────────────────────────────────────

cmd_install() {
    info "Installing labgrid deployment..."

    # Create venv if needed
    if [ ! -d "$VENV_DIR" ]; then
        info "Creating Python venv at $VENV_DIR"
        python3 -m venv "$VENV_DIR"
    fi

    # Install labgrid and the usb-device bridge
    info "Installing labgrid and usb-device bridge..."
    venv_pip install --quiet labgrid
    venv_pip install --quiet -e "$LABGRID_DIR"

    # Create exporter.yaml from template if needed
    if [ ! -f "$EXPORTER_YAML" ]; then
        if [ -f "$SCRIPT_DIR/exporter.yaml.example" ]; then
            cp "$SCRIPT_DIR/exporter.yaml.example" "$EXPORTER_YAML"
            info "Created exporter.yaml from template — edit it with your device names"
        else
            die "No exporter.yaml.example found"
        fi
    else
        info "exporter.yaml already exists"
    fi

    # Create fixtures.yaml from template if needed
    if [ ! -f "$FIXTURES_YAML" ]; then
        if [ -f "$SCRIPT_DIR/fixtures.yaml.example" ]; then
            cp "$SCRIPT_DIR/fixtures.yaml.example" "$FIXTURES_YAML"
            info "Created fixtures.yaml from template — edit it with your fixture tags"
        fi
    else
        info "fixtures.yaml already exists"
    fi

    info "Install complete."
    info ""
    info "Next steps:"
    info "  1. Edit $EXPORTER_YAML with your device names"
    info "  2. Edit $FIXTURES_YAML with fixture tags (optional)"
    info "  3. Run: $0 start"
    info "  4. Run: $0 places"
    info ""
    info "Or install as launchd services:"
    info "  $0 launchd-install"
}

# ── Start/Stop (foreground, no launchd) ──────────────────────────────────────

cmd_start() {
    # Kill existing
    cmd_stop 2>/dev/null || true

    info "Starting coordinator on port $COORDINATOR_PORT..."
    nohup "$VENV_DIR/bin/labgrid-coordinator" -l "$COORDINATOR_ADDR" \
        > /tmp/labgrid-coordinator.log 2>&1 &
    echo $! > /tmp/labgrid-coordinator.pid
    sleep 2

    if ! kill -0 "$(cat /tmp/labgrid-coordinator.pid)" 2>/dev/null; then
        die "Coordinator failed to start. Check /tmp/labgrid-coordinator.log"
    fi
    info "Coordinator started (PID $(cat /tmp/labgrid-coordinator.pid))"

    info "Starting exporter..."
    nohup "$VENV_DIR/bin/python" -m labgrid_usb_device.run_exporter \
        -c "$LG_COORDINATOR" "$EXPORTER_YAML" \
        > /tmp/labgrid-exporter.log 2>&1 &
    echo $! > /tmp/labgrid-exporter.pid
    sleep 3

    if ! kill -0 "$(cat /tmp/labgrid-exporter.pid)" 2>/dev/null; then
        die "Exporter failed to start. Check /tmp/labgrid-exporter.log"
    fi
    info "Exporter started (PID $(cat /tmp/labgrid-exporter.pid))"

    # Wait for exporter to register, then create places
    sleep 2
    cmd_places
}

cmd_stop() {
    for name in coordinator exporter; do
        local pidfile="/tmp/labgrid-$name.pid"
        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid"
                info "Stopped labgrid-$name (PID $pid)"
            fi
            rm -f "$pidfile"
        fi
    done
    # Also kill any orphaned processes
    pkill -f "labgrid-coordinator" 2>/dev/null || true
    pkill -f "labgrid_usb_device.run_exporter" 2>/dev/null || true
}

# ── Status ───────────────────────────────────────────────────────────────────

cmd_status() {
    echo "=== Coordinator ==="
    if pgrep -f "labgrid-coordinator" > /dev/null 2>&1; then
        echo "Running (PID $(pgrep -f labgrid-coordinator))"
    else
        echo "Not running"
    fi

    echo ""
    echo "=== Exporter ==="
    if pgrep -f "labgrid_usb_device.run_exporter" > /dev/null 2>&1; then
        echo "Running (PID $(pgrep -f labgrid_usb_device.run_exporter))"
    else
        echo "Not running"
    fi

    echo ""
    echo "=== Resources ==="
    labgrid_client resources 2>/dev/null || echo "(coordinator not reachable)"

    echo ""
    echo "=== Places ==="
    labgrid_client places 2>/dev/null || echo "(coordinator not reachable)"
}

# ── Places ───────────────────────────────────────────────────────────────────

cmd_places() {
    # Parse group names from exporter.yaml and create matching places
    if [ ! -f "$EXPORTER_YAML" ]; then
        die "No exporter.yaml found. Run: $0 install"
    fi

    info "Creating places from exporter.yaml..."

    # Extract top-level YAML keys (group names) — simple parser for flat YAML
    local groups
    groups=$(venv_python -c "
import yaml, sys
with open('$EXPORTER_YAML') as f:
    data = yaml.safe_load(f)
if data:
    for name in data:
        print(name)
")

    if [ -z "$groups" ]; then
        warn "No resource groups found in exporter.yaml"
        return
    fi

    local existing
    existing=$(labgrid_client places 2>/dev/null || true)

    while IFS= read -r group; do
        if echo "$existing" | grep -q "^${group}"; then
            info "Place '$group' already exists"
        else
            labgrid_client -p "$group" create 2>/dev/null
            labgrid_client -p "$group" add-match "*/$group/*" 2>/dev/null
            info "Created place '$group' with match '*/$group/*'"
        fi
    done <<< "$groups"

    # Apply fixture tags from fixtures.yaml
    _apply_tags

    echo ""
    labgrid_client places
}

_apply_tags() {
    if [ ! -f "$FIXTURES_YAML" ]; then
        return
    fi

    info "Applying fixture tags from fixtures.yaml..."

    # Read fixtures.yaml and apply tags to each place
    venv_python -c "
import yaml, subprocess, sys, os

coordinator = '$LG_COORDINATOR'
lgclient = '$VENV_DIR/bin/labgrid-client'
fixtures_path = '$FIXTURES_YAML'

with open(fixtures_path) as f:
    fixtures = yaml.safe_load(f)

if not fixtures:
    sys.exit(0)

for place_name, tags in fixtures.items():
    if not isinstance(tags, dict) or not tags:
        continue
    # Build tag args: key=value key=value ...
    tag_args = [f'{k}={v}' for k, v in tags.items()]
    cmd = [lgclient, '-x', coordinator, '-p', place_name, 'set-tags'] + tag_args
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        print(f'[setup] Tags set for {place_name}: {\" \".join(tag_args)}')
    else:
        err = result.stderr.strip() or result.stdout.strip()
        print(f'[setup] WARNING: Failed to set tags for {place_name}: {err}', file=sys.stderr)
"
}

# ── launchd ──────────────────────────────────────────────────────────────────

cmd_launchd_install() {
    local python_bin="$VENV_DIR/bin/python"
    [ -x "$python_bin" ] || die "Venv not found. Run: $0 install"

    mkdir -p "$PLIST_DIR"

    # Generate coordinator plist
    local coord_plist="$PLIST_DIR/com.usb-device.labgrid-coordinator.plist"
    info "Installing coordinator service: $coord_plist"
    sed \
        -e "s|/usr/local/bin/labgrid-coordinator|$VENV_DIR/bin/labgrid-coordinator|" \
        "$SCRIPT_DIR/coordinator.plist" > "$coord_plist"

    # Generate exporter plist with correct paths
    local exp_plist="$PLIST_DIR/com.usb-device.labgrid-exporter.plist"
    info "Installing exporter service: $exp_plist"
    sed \
        -e "s|/path/to/venv/bin/python|$python_bin|" \
        -e "s|/path/to/deploy/exporter.yaml|$EXPORTER_YAML|" \
        -e "s|/path/to/deploy|$SCRIPT_DIR|" \
        "$SCRIPT_DIR/exporter.plist" > "$exp_plist"

    # Load services
    launchctl unload "$coord_plist" 2>/dev/null || true
    launchctl load "$coord_plist"
    info "Coordinator service loaded"

    sleep 2

    launchctl unload "$exp_plist" 2>/dev/null || true
    launchctl load "$exp_plist"
    info "Exporter service loaded"

    sleep 3

    # Create places
    cmd_places

    info ""
    info "Services installed. They will start automatically on login."
    info "Logs: /tmp/labgrid-coordinator.log, /tmp/labgrid-exporter.log"
}

cmd_launchd_uninstall() {
    for label in coordinator exporter; do
        local plist="$PLIST_DIR/com.usb-device.labgrid-$label.plist"
        if [ -f "$plist" ]; then
            launchctl unload "$plist" 2>/dev/null || true
            rm "$plist"
            info "Removed $label service"
        fi
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-install}" in
    install)          cmd_install ;;
    start)            cmd_start ;;
    stop)             cmd_stop ;;
    status)           cmd_status ;;
    places)           cmd_places ;;
    launchd-install)  cmd_launchd_install ;;
    launchd-uninstall) cmd_launchd_uninstall ;;
    *)
        echo "Usage: $0 {install|start|stop|status|places|launchd-install|launchd-uninstall}"
        exit 1
        ;;
esac
