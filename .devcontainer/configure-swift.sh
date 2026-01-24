#!/bin/bash
# Script to find and configure Swift toolchain for VSCode

set -e

echo "=== Finding Swift installation ==="

# Try to find Swift
SWIFT_PATH=$(which swift 2>/dev/null || echo "")

if [ -z "$SWIFT_PATH" ]; then
    echo "Swift not found in PATH, searching..."
    SWIFT_PATH=$(find /usr -name swift -type f 2>/dev/null | head -1 || echo "")
fi

if [ -z "$SWIFT_PATH" ]; then
    echo "ERROR: Swift not found!"
    exit 1
fi

echo "Found Swift at: $SWIFT_PATH"
ls -la "$SWIFT_PATH" || true

# Verify Swift works
echo "=== Verifying Swift ==="
"$SWIFT_PATH" --version

# Find sourcekit-lsp
SOURCEKIT_LSP=$(which sourcekit-lsp 2>/dev/null || find /usr -name sourcekit-lsp -type f 2>/dev/null | head -1 || echo "")

if [ -n "$SOURCEKIT_LSP" ]; then
    echo "Found sourcekit-lsp at: $SOURCEKIT_LSP"
else
    echo "WARNING: sourcekit-lsp not found"
fi

echo "=== Swift configuration complete ==="
echo "Swift path: $SWIFT_PATH"
echo "SourceKit-LSP path: ${SOURCEKIT_LSP:-not found}"
