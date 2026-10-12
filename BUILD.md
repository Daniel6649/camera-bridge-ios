# Camera Bridge iOS prototype

This independently written project captures the selected front/rear camera and uses the hardware H.264 encoder through VideoToolbox. It previews the camera, offers 720p/1080p and 15/30/60 fps when supported by the device, starts/stops capture, and offers the rear camera's torch when supported. Diagnostic frame/byte counts are inside an expandable panel. It stops when the app enters the background. No microphone is requested and no audio is implemented.

The experimental TCP sender implements the observed control greeting, desktop settings negotiation, 444-byte camera metadata, little-endian headers, FLV AVC configuration, and individual H.264 NAL packets on the same connection. It consumes known desktop control packet lengths and replies to status requests with the camera's own exposure, white balance, focus, ISO, zoom, torch state, and battery level sampled when capture starts. Remote changes are reported in diagnostics without applying them. The UI accepts a manual desktop IP/hostname (port 5895). **Complete device-to-desktop operation is not yet validated.** Bonjour discovery, USB transport, audio, remote camera controls, and automatic reconnect remain unimplemented. Leave the desktop address empty for local-only encoding. The sender reports a neutral, unpurchased license state and leaves the desktop's trial/watermark behavior in place. No proprietary binaries, purchase hooks, copied artwork, or copied application code are incorporated.

## Build on your Mac

Requirements: Xcode 15 or later, an iPhone/iPad with iOS 15 or later, and an Apple account configured in Xcode. A real device is needed to verify the rear camera and hardware encoder.

1. Copy the entire `ios` directory to your Mac.
2. Open `ios/CameraBridge.xcodeproj` in Xcode. Select the CameraBridge target, set your development team under Signing & Capabilities, and choose a unique bundle identifier if provisioning requires it.
3. Select the connected iPhone and Run. Allow camera access. Select the desired resolution/frame rate and camera, then tap **Kamera starten**. Initially leave the desktop address empty to verify local capture/encoding. Stop capture before switching cameras.
4. Confirm the live preview, increasing encoded frame count, successful stop/restart, and stopping on app backgrounding. Check 720p/30 fps first. Unsupported combinations must produce a clear error.
   Expand **Diagnose** to see encoder and network details. Check the rear-camera **Licht** toggle on hardware with a torch; unsupported hardware leaves the light off.
5. For an experimental desktop test, stop capture, open the iVCam desktop receiver, disconnect other camera clients, enter the desktop's local IP address, then start capture. Allow local-network access if iOS asks. Confirm an actual moving camera image in the desktop preview; a TCP connection status alone is insufficient. Remote camera-control commands are surfaced as diagnostics but are not applied.

To compile without signing, run from a terminal:

```bash
bash ios/scripts/check-build.sh
```

To compile the actual Swift transport module and check its metadata/header/AVC bytes against independently recovered golden bytes on the Mac:

```bash
bash ios/scripts/check-wire-format.sh
```

These checks do not establish a successful video connection; they have not been executed on this Windows host.

To archive and export a signed development IPA with supported provisioning:

```bash
TEAM_ID=YOUR_TEAM_ID BUNDLE_ID=your.unique.identifier bash ios/scripts/build-export.sh
```

The script places the archive in `ios/build/CameraBridge.xcarchive` and the exported IPA in `ios/build/export`. Export requires an appropriate certificate/profile and registered device. Personal-team accounts may support Xcode installation without IPA export; use Xcode Run in that case. Set `EXPORT_METHOD` if your account/profile requires a different supported distribution method. Newer Xcode versions may label development export as `debugging`.

## Validation boundary

The source and project references were inspected on Windows; Info.plist XML was parsed. Xcode compilation, hardware encoding, provisioning, IPA export, and iVCam desktop interoperability have not been validated. This directory contains source only, not a built IPA.

Protocol implementation uses the independently documented static evidence in the adjacent analysis directory. An actual connection/video test against the installed desktop version is still required before describing this app as compatible.
