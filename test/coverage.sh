#!/bin/bash
# Run tests with bashcov coverage. Requires: bashcov, bats, bash 4+
# Usage: test/coverage.sh [--open]
#
# Install deps: test/setup.sh
# Coverage report is written to coverage/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COVERAGE_DIR="$REPO_DIR/coverage"

open_report=0
[ "${1:-}" = "--open" ] && open_report=1

# Check dependencies
for cmd in bashcov bats; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "error: $cmd not found. Run: test/setup.sh" >&2
        exit 1
    fi
done

# Find bash 4+ (required by bashcov for BASH_XTRACEFD)
BASH_PATH=""
for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
    if [ -x "$candidate" ]; then
        version=$("$candidate" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)
        if [ "${version:-0}" -ge 4 ]; then
            BASH_PATH="$candidate"
            break
        fi
    fi
done

if [ -z "$BASH_PATH" ]; then
    echo "error: bash 4+ required. Install with: brew install bash" >&2
    exit 1
fi

echo "Using bash: $BASH_PATH ($($BASH_PATH --version | head -1))"

# Clean previous run
rm -rf "$COVERAGE_DIR"

echo "Running mock tests with coverage..."
bashcov --bash-path "$BASH_PATH" --root "$REPO_DIR" -- bats "$REPO_DIR/test/usb-device-mock.bats"

# Print summary
if [ -d "$COVERAGE_DIR" ]; then
    index_html=$(find "$COVERAGE_DIR" -name 'index.html' -type f 2>/dev/null | head -1)
    if [ -n "$index_html" ]; then
        echo ""
        echo "HTML report: $index_html"
        if [ "$open_report" -eq 1 ] && command -v open &>/dev/null; then
            open "$index_html"
        fi
    fi
fi
