#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
xcodebuild -project "$PROJECT_DIR/CameraBridge.xcodeproj" -scheme CameraBridge \
    -configuration Debug -destination 'generic/platform=iOS' \
    -derivedDataPath "$PROJECT_DIR/build/check" CODE_SIGNING_ALLOWED=NO build
