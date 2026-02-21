#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# setup.sh — install and configure usb-device tooling
#
# Run from the repo:
#   scripts/usb-devices/setup.sh           # full setup (first time)
#   scripts/usb-devices/setup.sh --quick   # update PATH/symlinks only (for hooks)
#
# What it does:
#   1. Installs uhubctl (via Homebrew) and pyserial (via pip)
#   2. Configures passwordless sudo for uhubctl
#   3. Adds scripts to PATH
#   4. Creates ~/.config/usb-devices/ for user config (devices.conf, locations.json)
#   5. Installs git hooks (post-merge)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
CONFIG_DIR="$HOME/.config/usb-devices"
QUICK=0

[ "${1:-}" = "--quick" ] && QUICK=1

echo "=== usb-device setup ==="
echo ""

# ── 1. Dependencies (skip in --quick mode) ──────────────────────

if [ "$QUICK" -eq 0 ]; then
    # uhubctl
    if command -v uhubctl &>/dev/null; then
        echo "[ok] uhubctl already installed: $(which uhubctl)"
    else
        echo "[installing] uhubctl via Homebrew..."
        brew install uhubctl
        echo "[ok] uhubctl installed: $(which uhubctl)"
    fi

    # Python venv with pyserial
    if [ ! -f "$SCRIPT_DIR/.venv/bin/python3" ]; then
        echo "[creating] Python venv..."
        python3 -m venv "$SCRIPT_DIR/.venv"
    fi
    "$SCRIPT_DIR/.venv/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"
    echo "[ok] pyserial installed in .venv"

    # jq (needed for locations.json DB)
    if command -v jq &>/dev/null; then
        echo "[ok] jq already installed: $(which jq)"
    else
        echo "[installing] jq via Homebrew..."
        brew install jq
        echo "[ok] jq installed"
    fi
fi

# ── 2. Passwordless sudo for uhubctl (skip in --quick mode) ─────

if [ "$QUICK" -eq 0 ]; then
    UHUBCTL_PATH="$(which uhubctl 2>/dev/null || true)"
    SUDOERS_FILE="/etc/sudoers.d/uhubctl"

    if [ -z "$UHUBCTL_PATH" ]; then
        echo "[skip] uhubctl not found — skipping sudoers setup"
    elif [ -f "$SUDOERS_FILE" ]; then
        echo "[ok] sudoers rule already exists: $SUDOERS_FILE"
    else
        echo "[configuring] passwordless sudo for uhubctl..."
        CURRENT_USER="$(whoami)"
        RULE="$CURRENT_USER ALL=(root) NOPASSWD: $UHUBCTL_PATH"

        echo "$RULE" | sudo tee /tmp/uhubctl_sudoers >/dev/null
        if sudo visudo -cf /tmp/uhubctl_sudoers; then
            sudo mv /tmp/uhubctl_sudoers "$SUDOERS_FILE"
            sudo chmod 0440 "$SUDOERS_FILE"
            echo "[ok] sudoers rule installed"
        else
            sudo rm -f /tmp/uhubctl_sudoers
            echo "[error] sudoers rule validation failed — skipping"
            echo "        Manually add to $SUDOERS_FILE:"
            echo "        $RULE"
        fi
    fi
fi

# ── 3. Add to PATH ──────────────────────────────────────────────

chmod +x "$SCRIPT_DIR/usb-device"
chmod +x "$SCRIPT_DIR/serial-monitor"
chmod +x "$SCRIPT_DIR/hub-agent"

SHELL_RC=""
if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [ -n "$SHELL_RC" ]; then
    # Remove old ~/.config/usb-devices PATH entry if present
    if grep -qF '/.config/usb-devices' "$SHELL_RC" 2>/dev/null; then
        # Replace with repo path
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' '/\.config\/usb-devices/d' "$SHELL_RC"
        else
            sed -i '/\.config\/usb-devices/d' "$SHELL_RC"
        fi
        echo "[updated] removed old ~/.config/usb-devices PATH entry"
    fi

    # Add repo scripts path
    PATH_COMMENT="# usb-device tools (from firmware repo)"
    if grep -qF "scripts/usb-devices" "$SHELL_RC" 2>/dev/null; then
        echo "[ok] PATH already configured in $SHELL_RC"
    else
        {
            echo ""
            echo "$PATH_COMMENT"
            echo "export PATH=\"$SCRIPT_DIR:\$PATH\""
        } >> "$SHELL_RC"
        echo "[ok] added $SCRIPT_DIR to PATH in $SHELL_RC"
        echo "     run: source $SHELL_RC"
    fi
else
    echo "[note] could not find .zshrc or .bashrc"
    echo "       manually add to your shell profile:"
    echo "       export PATH=\"$SCRIPT_DIR:\$PATH\""
fi

# ── 4. User config directory ────────────────────────────────────

mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/devices.conf" ]; then
    cp "$SCRIPT_DIR/devices.conf.example" "$CONFIG_DIR/devices.conf"
    echo "[ok] created $CONFIG_DIR/devices.conf from example — add your devices"
else
    echo "[ok] $CONFIG_DIR/devices.conf already exists"
fi

if [ ! -f "$CONFIG_DIR/locations.json" ]; then
    echo '{}' > "$CONFIG_DIR/locations.json"
    echo "[ok] created $CONFIG_DIR/locations.json"
else
    echo "[ok] $CONFIG_DIR/locations.json already exists"
fi

mkdir -p "$CONFIG_DIR/types.d"
echo "[ok] $CONFIG_DIR/types.d/ exists (for custom type plugins)"

# ── 5. Git hooks ────────────────────────────────────────────────

HOOKS_DIR="$REPO_ROOT/.git/hooks"
HOOK_LINE="$SCRIPT_DIR/setup.sh --quick"

if [ -d "$HOOKS_DIR" ]; then
    for hook_name in post-merge post-checkout post-rewrite; do
        HOOK_FILE="$HOOKS_DIR/$hook_name"
        if [ -f "$HOOK_FILE" ] && grep -qF "setup.sh --quick" "$HOOK_FILE" 2>/dev/null; then
            echo "[ok] $hook_name hook already installed"
        else
            if [ -f "$HOOK_FILE" ]; then
                echo "" >> "$HOOK_FILE"
                echo "$HOOK_LINE" >> "$HOOK_FILE"
            else
                cat > "$HOOK_FILE" << HOOK
#!/bin/bash
$HOOK_LINE
HOOK
            fi
            chmod +x "$HOOK_FILE"
            echo "[ok] installed $hook_name git hook"
        fi
    done
else
    echo "[skip] not in a git repo — skipping hook installation"
fi

# ── 6. Hub agent LaunchAgent ────────────────────────────────────

if [ "$QUICK" -eq 0 ] && [ "$(uname)" = "Darwin" ]; then
    LAUNCHD_LABEL="com.usb-devices.hub-agent"
    LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

    if [ -f "$LAUNCHD_PLIST" ]; then
        echo "[ok] hub-agent LaunchAgent already installed"
        echo "     To reinstall: usb-device hub install"
    else
        echo ""
        echo "Install the Insight Hub display agent as a background service?"
        echo "  This keeps hub displays updated automatically on login."
        echo ""
        read -r -p "Install hub-agent LaunchAgent? [y/N] " response
        if [[ "$response" =~ ^[Yy] ]]; then
            "$SCRIPT_DIR/.venv/bin/python3" -u "$SCRIPT_DIR/hub_agent.py" --install
        else
            echo "[skip] hub-agent LaunchAgent (install later: usb-device hub install)"
        fi
    fi
fi

# ── Done ─────────────────────────────────────────────────────────

echo ""
echo "=== Setup complete ==="
echo ""
echo "Quick start:"
echo "  usb-device list                          # show all registered devices"
echo "  usb-device scan                          # scan bus, update last-known locations"
echo "  usb-device find \"<name>\"                  # show hub/port/dev info"
echo "  usb-device reset \"<name>\"                 # power-cycle a device"
echo "  usb-device port \"<name>\"                  # print /dev/cu.* path"
echo "  serial-monitor \"<name>\"                   # serial monitor with reset/bootloader"
echo "  usb-device hub install                   # install hub display agent (auto-start)"
echo ""
echo "Device registry: $CONFIG_DIR/devices.conf"
