# Camera Bridge iOS prototype

This independently written project captures the selected front/rear camera and uses the hardware H.264 encoder through VideoToolbox. It previews the camera, offers 720p/1080p and 15/30/60 fps when supported by the device, starts/stops capture, and offers the rear camera's torch when supported. Diagnostic frame/byte counts are inside an expandable panel. It stops when the app enters the background. No microphone is requested and no audio is implemented.

The experimental sender implements the observed control greeting, desktop settings negotiation, 444-byte camera metadata, little-endian headers, FLV AVC configuration, and complete AVCC H.264 access units. Version 0.3.1 selects USB by default: the phone listens on localhost port 5895 and the existing desktop connects through Apple USB multiplexing. PeerTalk frames use four big-endian fields and preserve the nested iVCam packet. Fragmented and coalesced frames are parsed with bounded payload lengths. After disconnecting, USB resumes listening. The app also supports WLAN via manual IP/hostname or Bonjour. Remote camera changes are reported without applying them; audio is unimplemented. **Complete device-to-desktop video operation is not yet validated.** The corrected whole-access-unit AVCC format displayed generated video through the installed desktop decoder and virtual camera; phone USB display remains to be validated. The sender reports a neutral, unpurchased license state and leaves the desktop's trial/watermark behavior in place. No proprietary binaries, purchase hooks, copied artwork, or copied application code are incorporated.

## Build on your Mac

Requirements: Xcode 16.4 or later, an iPhone/iPad with iOS 15 or later, and an Apple account configured in Xcode for direct installation. Xcode 16.4 is the verified cloud compiler. A real device is needed to verify the camera and encoder. The app uses VideoToolbox's default encoder selection and derives encoder size from the first captured buffer. Preview remains active if encoding fails.

1. Copy the entire `ios` directory to your Mac.
2. Open `ios/CameraBridge.xcodeproj` in Xcode. Select the CameraBridge target, set your development team under Signing & Capabilities, and choose a unique bundle identifier if provisioning requires it.
3. Select the connected iPhone and Run. Allow camera access. Select the desired resolution/frame rate and camera, then tap **Kamera starten**. Initially leave the desktop address empty to verify local capture/encoding. Stop capture before switching cameras.
4. Confirm the live preview, increasing encoded frame count, successful stop/restart, and stopping on app backgrounding. Check 720p/30 fps first. Unsupported combinations must produce a clear error.
   Expand **Diagnose** to see encoder and network details. Check the rear-camera **Licht** toggle on hardware with a torch; unsupported hardware leaves the light off.
5. For USB, connect a data cable, unlock the phone and trust the computer. Open iVCam on the PC and leave Camera Bridge in the foreground with USB selected; no PC address is required. The PC must have Apple's USB driver/service. For WLAN, stop capture, select WLAN and optionally enter the PC address, then start; allow local-network access. Confirm an actual moving image in the desktop preview. Connection or byte counters alone do not establish interoperability.

To compile without signing, run from a terminal:

```bash
bash ios/scripts/check-build.sh
```

To compile the actual Swift transport module and check its metadata/header/AVC bytes against independently recovered golden bytes on the Mac:

```bash
bash ios/scripts/check-wire-format.sh
```

These checks passed on the GitHub macOS runner. They do not establish a successful iPhone video connection.

To archive and export a signed development IPA with supported provisioning:

```bash
TEAM_ID=YOUR_TEAM_ID BUNDLE_ID=your.unique.identifier bash ios/scripts/build-export.sh
```

The script places the archive in `ios/build/CameraBridge.xcarchive` and the exported IPA in `ios/build/export`. Export requires an appropriate certificate/profile and registered device. Personal-team accounts may support Xcode installation without IPA export; use Xcode Run in that case. Set `EXPORT_METHOD` if your account/profile requires a different supported distribution method. Newer Xcode versions may label development export as `debugging`.

## Validation boundary

The source and project references were inspected on Windows; Info.plist XML was parsed. Xcode 16.4 device compilation, wire-format golden checks, ARM64 verification, and unsigned IPA packaging passed in GitHub Actions. The downloaded IPA ZIP integrity, bundle identifier, minimum iOS version and executable architecture were independently checked. iPhone execution, provisioning/signing and full iVCam desktop interoperability remain unvalidated.

Protocol implementation uses the independently documented static evidence in the adjacent analysis directory. An actual connection/video test against the installed desktop version is still required before describing this app as compatible.
