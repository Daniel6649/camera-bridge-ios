#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$PROJECT_DIR/build/wire-check"
xcrun swiftc "$PROJECT_DIR/CameraBridge/IVCamTransport.swift" \
    "$PROJECT_DIR/tests/WireFormatChecks.swift" \
    -o "$PROJECT_DIR/build/wire-check/check"
"$PROJECT_DIR/build/wire-check/check"
