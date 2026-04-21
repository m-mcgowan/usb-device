#!/bin/bash
# Install test and coverage dependencies.
# Usage: test/setup.sh
#
# Installs:
#   - bats-core (test runner)
#   - bash 5.x (macOS only — system bash 3.2 is too old for bashcov)
#   - jq (JSON processing, also a runtime dependency)
#   - bashcov (coverage via Ruby gem)

set -euo pipefail

echo "=== Test dependency setup ==="
echo ""

if [ "$(uname)" = "Darwin" ]; then
    for pkg in bats-core bash jq ruby; do
        if brew list "$pkg" &>/dev/null; then
            echo "[ok] $pkg already installed"
        else
            echo "[installing] $pkg..."
            brew install "$pkg"
        fi
    done

    brew_bash="$(brew --prefix)/bin/bash"
    if [ -x "$brew_bash" ]; then
        echo "[ok] brew bash: $brew_bash ($($brew_bash --version | head -1))"
    fi

    # Use brew ruby for gem installs (macOS system ruby 2.6 is too old)
    brew_ruby_bin="$(brew --prefix ruby)/bin"
    if [ -d "$brew_ruby_bin" ]; then
        export PATH="$brew_ruby_bin:$PATH"
        echo "[ok] brew ruby: $(ruby --version)"
    fi
else
    # Linux (Ubuntu/Debian)
    if ! command -v bats &>/dev/null; then
        if command -v npm &>/dev/null; then
            sudo npm install -g bats
        elif command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y bats jq
        fi
    fi
    echo "[ok] bats: $(bats --version)"
fi

# bashcov (Ruby gem — works on both macOS and Linux)
if command -v bashcov &>/dev/null; then
    echo "[ok] bashcov already installed ($(bashcov --version))"
else
    echo "[installing] bashcov..."
    gem install --user-install bashcov
    # Ensure user gem bin is on PATH
    gem_bin="$(ruby -e 'puts Gem.user_dir')/bin"
    if ! echo "$PATH" | tr ':' '\n' | grep -qF "$gem_bin"; then
        export PATH="$gem_bin:$PATH"
        echo "[note] added $gem_bin to PATH for this session"
        echo "       add to your shell profile: export PATH=\"$gem_bin:\$PATH\""
    fi
    echo "[ok] bashcov installed ($(bashcov --version))"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Run tests:    bats test/usb-device-mock.bats"
echo "Coverage:     test/coverage.sh [--open]"
