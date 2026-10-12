#!/bin/bash
set -euo pipefail

# Run on macOS with Xcode selected and your Apple account configured in Xcode.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team identifier}"
BUNDLE_ID="${BUNDLE_ID:-net.local.camerabridge}"
EXPORT_METHOD="${EXPORT_METHOD:-development}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/build}"
mkdir -p "$OUTPUT_DIR"

# Construct a plist without shell interpolation into XML.
/usr/bin/python3 - "$OUTPUT_DIR/ExportOptions.plist" "$TEAM_ID" "$EXPORT_METHOD" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'method': sys.argv[3], 'teamID': sys.argv[2],
                  'signingStyle': 'automatic', 'destination': 'export'}, output)
PY

xcodebuild -project "$PROJECT_DIR/CameraBridge.xcodeproj" -scheme CameraBridge \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$OUTPUT_DIR/CameraBridge.xcarchive" \
    DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath "$OUTPUT_DIR/CameraBridge.xcarchive" \
    -exportPath "$OUTPUT_DIR/export" -exportOptionsPlist "$OUTPUT_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates
printf 'Export directory: %s\n' "$OUTPUT_DIR/export"
