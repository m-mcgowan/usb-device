#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mat McGowan
# install.sh — download and install usb-device from GitHub Releases
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/m-mcgowan/usb-device/main/install.sh | bash
#   USB_DEVICE_VERSION=0.1.0 bash install.sh   # pin a specific version
set -euo pipefail

REPO="m-mcgowan/usb-device"
INSTALL_DIR="${USB_DEVICE_DIR:-$HOME/.local/share/usb-device}"
BIN_DIR="${USB_DEVICE_BIN:-$HOME/.local/bin}"

# Determine version
if [ -n "${USB_DEVICE_VERSION:-}" ]; then
    VERSION="$USB_DEVICE_VERSION"
else
    echo "Fetching latest release..."
    VERSION=$(curl -sSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    if [ -z "$VERSION" ]; then
        echo "error: could not determine latest version" >&2
        echo "Set USB_DEVICE_VERSION explicitly or check https://github.com/$REPO/releases" >&2
        exit 1
    fi
fi

echo "Installing usb-device v${VERSION}..."

# Download and extract to temp dir
TARBALL_URL="https://github.com/$REPO/archive/refs/tags/v${VERSION}.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! curl -sSL "$TARBALL_URL" | tar xz -C "$TMP" --strip-components=1; then
    echo "error: failed to download v${VERSION}" >&2
    echo "Check that the version exists at https://github.com/$REPO/releases" >&2
    exit 1
fi

# Install to INSTALL_DIR
mkdir -p "$INSTALL_DIR"
cp "$TMP"/usb-device "$TMP"/serial-monitor "$TMP"/hub-agent "$INSTALL_DIR/"
cp "$TMP"/hub_agent.py "$TMP"/serial_monitor.py "$TMP"/iokit_usb.py "$INSTALL_DIR/"
cp "$TMP"/VERSION "$TMP"/devices.conf.example "$INSTALL_DIR/"
mkdir -p "$INSTALL_DIR/types.d"
cp "$TMP"/types.d/*.sh "$INSTALL_DIR/types.d/"
chmod +x "$INSTALL_DIR"/{usb-device,serial-monitor,hub-agent}

# Create user config directory
CONFIG_DIR="$HOME/.config/usb-devices"
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/devices.conf" ]; then
    cp "$INSTALL_DIR/devices.conf.example" "$CONFIG_DIR/devices.conf"
    echo "Created $CONFIG_DIR/devices.conf — edit this to register your devices."
fi

# Symlink into BIN_DIR
mkdir -p "$BIN_DIR"
for cmd in usb-device serial-monitor hub-agent; do
    ln -sf "$INSTALL_DIR/$cmd" "$BIN_DIR/$cmd"
done

# Check if BIN_DIR is on PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    echo ""
    echo "Add to your shell profile (~/.zshrc or ~/.bashrc):"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi

# Check dependencies
echo ""
missing=0
for dep in uhubctl jq; do
    if command -v "$dep" &>/dev/null; then
        echo "  [ok] $dep"
    else
        echo "  [missing] $dep — run: brew install $dep"
        missing=$((missing + 1))
    fi
done
if python3 -c "import serial" &>/dev/null 2>&1; then
    echo "  [ok] pyserial"
else
    echo "  [missing] pyserial — run: pip3 install pyserial"
    missing=$((missing + 1))
fi

echo ""
echo "Installed usb-device v${VERSION} to $INSTALL_DIR"
[ "$missing" -eq 0 ] || echo "Install missing dependencies above, then run: usb-device check"
