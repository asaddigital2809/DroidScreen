# DroidScreen

DroidScreen turns an Android phone into an extended display for macOS. The Mac host creates a virtual monitor that macOS treats as a separate display. The host captures that display, encodes it with VideoToolbox and streams it over TCP to an Android receiver app. The Android app decodes the stream with MediaCodec and sends touch and keyboard input back to the Mac.

Detailed documentation: [DOCUMENTATION.md](DOCUMENTATION.md) · Changes: [CHANGELOG.md](CHANGELOG.md) · Code graph: [graphify-out/GRAPH_REPORT.md](graphify-out/GRAPH_REPORT.md)

## Status

| Milestone | Scope | State |
|---|---|---|
| 1 — Virtual display | Create a real macOS virtual monitor, verify extend mode, place windows on it | **Done** (self-test passes on macOS 27.2, Apple M4) |
| 2 — Video streaming | ScreenCaptureKit → VideoToolbox → TCP → MediaCodec | **Done** (verified on a Xiaomi Redmi over USB, see [verification results](DOCUMENTATION.md#milestone-2-verification-results)) |
| 3 — Connectivity | USB via `adb reverse`, unencrypted LAN listening, Bonjour discovery, start at login and auto-stream when no physical display is connected exist. AOA, QR pairing and TLS are planned. | Partly implemented |
| 4 — Input | Touch → mouse/scroll/click, hardware keyboard → key events | Implemented; touch input end-to-end not yet confirmed on a device |
| 5 — Production UI | Dashboard, diagnostics, error handling | Not started |

## Requirements

Mac host:
- macOS 14 or later (tested on macOS 27.2, Apple silicon).
- Xcode 15+ command-line tools (Swift 5.10+). Tested with Xcode 27.2 / Swift 6.4.2.
- Android platform-tools (`adb`) for USB streaming.

Android receiver:
- Android 10 (API 29) or later.
- Android SDK and JDK 17 to build. The Gradle wrapper is included.
- USB debugging enabled and authorised for USB streaming.

## Build

### Mac host

```bash
cd macos
scripts/create-local-signing-identity.sh   # once: stable local signing identity
swift build                                # libraries, CLI, app executable
swift test                                 # unit tests
scripts/build-app.sh                       # macos/build/DroidScreen.app
```

`build-app.sh` signs with `$SIGN_IDENTITY` if set, otherwise with the "DroidScreen Local Signing" identity, otherwise ad-hoc. A stable identity keeps the Screen Recording and Accessibility permissions across rebuilds.

### Android receiver

```bash
cd android
./gradlew :app:assembleDebug          # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:assembleRelease        # app/build/outputs/apk/release/app-release.apk
./gradlew :app:testDebugUnitTest      # unit tests
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Release builds are signed only when `android/keystore.properties` exists (see [DOCUMENTATION.md › Android build and release signing](DOCUMENTATION.md#android-build-and-release-signing)). Release and debug builds use different keys. To switch between them on a device, uninstall the app first.

## Use

### Stream over USB with the app

1. Enable USB debugging on the phone, connect the cable, accept the authorisation prompt.
2. Install the Android app.
3. Open `macos/build/DroidScreen.app`.
4. Click **Start streaming**. The app creates the virtual display if needed and asks for Screen Recording permission the first time.
5. Click **Set up USB (adb)**. The host runs `adb reverse` and starts the Android app with the host address, port and input token.
6. The phone shows the extended desktop. Drag windows past the right edge of the Mac screen onto it.
7. For touch input, grant Accessibility permission (the **Grant…** button next to "Touch input").

### Start automatically and stream when no display is connected

1. In the Mac app, turn on **Start DroidScreen at login** and **Stream to Android automatically when no physical display is connected** (section "Automation").
2. Grant Screen Recording (and Accessibility for touch) while a display is still connected.
3. Connect the phone once over USB with **Set up USB**, so the phone saves the input code.
4. On the phone, turn on **Connect automatically**.

When no physical display is connected, the Mac creates the virtual display and streams over USB (adb, set up automatically for every attached phone) and Wi-Fi (advertised over Bonjour as `_droidscreen._tcp`). The phone app finds the Mac on the same network or uses USB. When a physical display is connected again, the automatic stream stops and the virtual display is removed. On a Mac without a display, enable automatic login so the app starts after a reboot. Details: [DOCUMENTATION.md › Automatic start and headless streaming](DOCUMENTATION.md#automatic-start-and-headless-streaming).

Unattended start:

```bash
open macos/build/DroidScreen.app --args -autoServe YES -autoUSB YES
open macos/build/DroidScreen.app --args -autoServe YES -codec hevc -fps 30 -bitrateMbps 10 -preset 1 -touchInput NO
```

### Stream with the command-line tool

```bash
cd macos
.build/debug/droidscreen-vd serve --adb                 # USB: adb reverse + start the Android app
.build/debug/droidscreen-vd serve --lan --codec hevc    # listen on all interfaces (unencrypted)
```

On the phone, the app connects to `127.0.0.1` for USB, `10.0.2.2` for the emulator, or the Mac's IP address for LAN. Macs that allow LAN connections are listed on the phone's connect screen.

### Other CLI commands

```bash
.build/debug/droidscreen-vd probe                 # is the virtual display API present?
.build/debug/droidscreen-vd selftest              # automated Milestone 1 acceptance test
.build/debug/droidscreen-vd create --window       # create a display + test window; Ctrl-C removes it
.build/debug/droidscreen-vd list                  # list online displays
```

## Repository layout

```
DuetDisplay/
├── README.md, DOCUMENTATION.md, CHANGELOG.md
├── graphify-out/                    knowledge graph of the code
├── macos/                           Swift package (host)
│   ├── Package.swift
│   ├── Sources/
│   │   ├── CGVirtualDisplayBridge/  Objective-C shim for the private CGVirtualDisplay API
│   │   ├── VirtualDisplayKit/       virtual display config, lifecycle, inspection, self-test
│   │   ├── StreamKit/               wire protocol, capture, encode, TCP server, flow control, adb
│   │   ├── InputKit/                CGEvent injection, Android → mac key map
│   │   ├── droidscreen-vd/          CLI
│   │   └── DroidScreenHost/         SwiftUI app
│   ├── Tests/                       VirtualDisplayKitTests, StreamKitTests, InputKitTests
│   ├── Resources/                   Info.plist, entitlements
│   └── scripts/                     build-app.sh, create-local-signing-identity.sh
└── android/                         Gradle project (receiver app, module :app)
    └── app/src/main/java/com/droidscreen/receiver/
        ├── protocol/  decoder/  session/  input/  ui/
        └── MainActivity.kt
```

## Platform note

macOS has no public API for creating virtual displays. DroidScreen uses CoreGraphics' private `CGVirtualDisplay` classes, as DeskPad, BetterDisplay and Chromium's test tools do. For this reason the app cannot ship in the Mac App Store. It is distributed with Developer ID signing and notarization instead. See [DOCUMENTATION.md › Feasibility assessment](DOCUMENTATION.md#feasibility-assessment).
