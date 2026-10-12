#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build"
mkdir -p "$OUTPUT_DIR/export"

# Device build, not simulator. Sideloadly will sign it later on the user's PC.
xcodebuild -project "$PROJECT_DIR/CameraBridge.xcodeproj" -scheme CameraBridge \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$OUTPUT_DIR/unsigned" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build 2>&1 | tee "$OUTPUT_DIR/unsigned-build.log"

APP_PATH="$OUTPUT_DIR/unsigned/Build/Products/Release-iphoneos/CameraBridge.app"
test -d "$APP_PATH"
test -f "$APP_PATH/Info.plist"
test -x "$APP_PATH/CameraBridge"
/usr/bin/lipo -verify_arch arm64 "$APP_PATH/CameraBridge"

# Fresh staging directory avoids stale payloads and does not erase prior builds.
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/ipa-staging.XXXXXX")"
mkdir -p "$STAGING_DIR/Payload"
ditto "$APP_PATH" "$STAGING_DIR/Payload/CameraBridge.app"
(
    cd "$STAGING_DIR"
    /usr/bin/zip -qry "$STAGING_DIR/CameraBridge-unsigned.ipa" Payload
)
mv -f "$STAGING_DIR/CameraBridge-unsigned.ipa" "$OUTPUT_DIR/export/CameraBridge-unsigned.ipa"
unzip -t "$OUTPUT_DIR/export/CameraBridge-unsigned.ipa"
printf 'Unsigned IPA ready: %s\n' "$OUTPUT_DIR/export/CameraBridge-unsigned.ipa"
