# DroidScreen — Documentation

Contents:
1. [Feasibility assessment](#feasibility-assessment)
2. [Selected virtual display implementation](#selected-virtual-display-implementation)
3. [Permissions, entitlements, signing](#permissions-entitlements-signing)
4. [USB and Wi-Fi architecture](#usb-and-wi-fi-architecture)
5. [Project folder structure](#project-folder-structure)
6. [CGVirtualDisplayBridge](#cgvirtualdisplaybridge)
7. [VirtualDisplayKit](#virtualdisplaykit)
8. [Wire protocol](#wire-protocol)
9. [StreamKit](#streamkit)
10. [InputKit](#inputkit)
11. [droidscreen-vd CLI](#droidscreen-vd-cli)
12. [DroidScreenHost app](#droidscreenhost-app)
13. [Build and packaging](#build-and-packaging)
14. [Android receiver app](#android-receiver-app)
15. [Android build and release signing](#android-build-and-release-signing)
16. [Tests](#tests)
17. [Milestone 1 verification results](#milestone-1-verification-results)
18. [Milestone 2 verification results](#milestone-2-verification-results)
19. [Acceptance test status](#acceptance-test-status)

---

## Feasibility assessment

### Options for creating a display macOS treats as a real monitor

| Option | Creates a real macOS display? | Status |
|---|---|---|
| Public CoreGraphics / AppKit API | No. No public API creates displays. | Not possible |
| DriverKit (system extension) | No. DriverKit has no display or framebuffer driver family. | Not possible |
| IOKit kernel extension (`IOFramebuffer`) | Historically yes. Kexts are deprecated. On Apple silicon they need Reduced Security and user approval in recovery mode. Apple-silicon GPUs do not use `IOFramebuffer` for external displays. | Not viable |
| Private `CGVirtualDisplay` (CoreGraphics) | **Yes.** WindowServer registers a full display: own display ID, modes, arrangement, NSScreen. | **Selected** |
| Hardware HDMI/USB-C dummy plug | Yes (physical display). It can be captured with ScreenCaptureKit like any display. | Optional hardware fallback |
| Sidecar / AirPlay receiver | Apple-proprietary protocols, not available to third-party receivers. | Not viable |

### Result

A genuine extended display can be created with `CGVirtualDisplay`. This was measured on this machine (see [verification results](#milestone-1-verification-results)):
- macOS lists "DroidScreen" in `system_profiler SPDisplaysDataType` with `Mirror: Off`, next to the physical monitor.
- The display has its own region of the global desktop (`x = 1920`, right of the main display).
- AppKit reports it as an `NSScreen` with `backingScaleFactor = 2.0` (HiDPI).
- A window placed on it reports `window.screen` = the virtual display.

### Constraints of the selected approach

- `CGVirtualDisplay` is private API. Apple can change or remove it in any macOS release.
- Apps using it are not accepted in the Mac App Store. Distribution is Developer ID + notarization.
- The App Sandbox cannot be enabled.
- The display exists only while the creating process holds the `CGVirtualDisplay` object. If the process exits or crashes, macOS removes the display and moves its windows to another screen.
- DroidScreen checks every private class and selector at runtime (`DSVirtualDisplay.isAPIAvailable`). If anything is missing, creation fails with `VirtualDisplayError.apiUnavailable` and a list of what is missing. The app does not fall back to mirroring.

---

## Selected virtual display implementation

### Private classes used

Declared in `macos/Sources/CGVirtualDisplayBridge/CGVirtualDisplayPrivate.h`:

| Class | Members used |
|---|---|
| `CGVirtualDisplayDescriptor` | `name`, `maxPixelsWide`, `maxPixelsHigh`, `sizeInMillimeters`, `vendorID`, `productID`, `serialNum`, `redPrimary`/`greenPrimary`/`bluePrimary`/`whitePoint`, `terminationHandler`, `setDispatchQueue:` (or `setQueue:`) |
| `CGVirtualDisplayMode` | `initWithWidth:height:refreshRate:` |
| `CGVirtualDisplaySettings` | `modes`, `hiDPI` |
| `CGVirtualDisplay` | `initWithDescriptor:`, `applySettings:`, `displayID` |

### Creation sequence (`VirtualDisplayManager.create`)

1. `VirtualDisplayConfiguration.validate()`.
2. Check `DSVirtualDisplay.isAPIAvailable`.
3. Build a `DSVirtualDisplayDescriptor`: name, max pixels, physical size, vendor `0x4453`, product `0x4D31`, serial number.
4. `DSVirtualDisplay(descriptor:queue:terminationHandler:)` → `CGVirtualDisplay initWithDescriptor:`.
5. `apply(_:hiDPI:)` → `CGVirtualDisplaySettings` with one `CGVirtualDisplayMode` per resolution × refresh rate.
6. Wait until the display ID is in `CGGetOnlineDisplayList`.
7. If the display does not come online within `appearanceTimeout`, release it and register it again with a new serial number from `freshSerial(excluding:)`. This repeats up to `serialFallbacks` times (default 2). Each retry adds a warning to `ActiveDisplay.warnings`.
8. Wait until `CGDisplayCopyDisplayMode` and `CGDisplayCopyAllDisplayModes` return data. (The display goes online before its mode list is published.)
9. `DisplayConfigurator.ensureExtended` removes mirroring if present.
10. `DisplayConfigurator.applyMode` selects the requested pixel size (HiDPI variant if `hiDPI` is true).

### Serial number fallback

On macOS 27.2 the following was observed: after a session in which the display was removed unexpectedly, WindowServer registered the same vendor/product/serial identity again but did not bring it online. New identities worked. `create` therefore retries with a fresh serial (random value in `1000…0xFFFFFF`, different from the previous one). `ActiveDisplay.configuration.serialNumber` reports the serial that was used.

### Mode behaviour observed on macOS 27.2

- Each mode `W×H` in pixels is offered at 1×. With `hiDPI = true`, macOS also offers `W/2 × H/2` points backed by `W×H` pixels.
- macOS adds further modes derived from `maxPixelsWide`/`maxPixelsHigh`, e.g. `1600×1200`, `1024×768`, `1920×864` for the phone preset.
- With the phone preset, the selected mode is `1200×540 pt (HiDPI, 2400×1080 px) @ 60 Hz`.

---

## Permissions, entitlements, signing

### macOS

| Feature | Requirement | Purpose |
|---|---|---|
| Virtual display | None | Creating a `CGVirtualDisplay` triggered no TCC prompt in testing. |
| Streaming | Screen Recording (TCC) | ScreenCaptureKit capture of the virtual display. Checked with `ScreenCapturePermission.isGranted` (`CGPreflightScreenCaptureAccess`); `ScreenCapturePermission.ensure()` shows the system prompt the first time. |
| Touch and keyboard input | Accessibility (TCC, `AXIsProcessTrusted`) | Posting mouse and keyboard events with `CGEvent`. `InputPermission.request()` shows the system prompt. |
| Bonjour / LAN | Local Network (macOS 15+); `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_droidscreen._tcp`) in `Info.plist` | Advertising the LAN listener so Android finds the Mac. macOS asks for Local Network access the first time. |
| Start at login | Login Items (`SMAppService.mainApp`) | "Start DroidScreen at login". macOS may require approval in System Settings › General › Login Items. |

Entitlements file: `macos/Resources/DroidScreenHost.entitlements` sets `com.apple.security.app-sandbox` to `false`.

### Signing (macOS)

TCC permissions are tied to the code signature. An ad-hoc signature changes on every build, so macOS stops applying the Screen Recording and Accessibility grants after a rebuild. A stable signing identity keeps them.

- `macos/scripts/create-local-signing-identity.sh` creates a self-signed code-signing identity named "DroidScreen Local Signing" in the login keychain (RSA 2048, 10 years, extended key usage `codeSigning`). It imports the key with `-T /usr/bin/codesign`, so `codesign` can use it without a keychain prompt. If the identity already exists, the script exits without changes. Remove it with `security delete-identity -c "DroidScreen Local Signing"`. It is for local development only.
- `macos/scripts/build-app.sh` picks the signing identity in this order:
  1. `$SIGN_IDENTITY` if set (`-` forces ad-hoc).
  2. "DroidScreen Local Signing", looked up by its certificate hash with `security find-identity -p codesigning`.
  3. Ad-hoc (`-`).
- An identity starting with `Developer ID` also gets `--options runtime --timestamp` (hardened runtime and secure timestamp). Then notarize with `xcrun notarytool submit` and staple with `xcrun stapler staple`.

### Android

`AndroidManifest.xml` declares `android.permission.INTERNET` (TCP connection to the Mac host). No other permissions are declared. DNS-SD discovery uses `NsdManager`, which needs no extra permission. Permissions for Milestone 3 (planned): `CAMERA` (QR scan), `uses-feature android.hardware.usb.accessory` (AOA, optional).

---

## USB and Wi-Fi architecture

### Implemented

- **Transport:** one TCP connection per client, framed with the [wire protocol](#wire-protocol). Default port `47800` (`WireProtocol.defaultPort`).
- **Listener:** `StreamServer` (Network.framework `NWListener`). TCP no-delay, keepalive (idle 2 s, interval 1 s, count 3), service class `.interactiveVideo`.
  - Default: bound to `127.0.0.1` only.
  - `allowLAN` / `--lan`: listens on all interfaces. This mode is unencrypted.
- **USB — ADB reverse:** `AdbBridge.setUpReceivers(port:inputToken:)` runs `adb -s <serial> reverse tcp:<port> tcp:<port>` for every authorised device, then starts the Android app with `am start` and the extras `host=127.0.0.1`, `port`, `autoConnect=true` and `inputToken`. The Android app connects to `127.0.0.1:<port>`, which adb forwards to the Mac's loopback listener.
- **Emulator:** the Android emulator reaches the Mac's loopback at `10.0.2.2`.
- **Wi-Fi / LAN:** the user enables LAN connections on the Mac. While LAN connections are allowed, the listener is advertised over Bonjour as `_droidscreen._tcp` (`WireProtocol.bonjourServiceType`) with the computer name. The Android app discovers it with `NsdManager` (`MacDiscovery`) and lists it on the connect screen. Manual IP entry is still available.
- **Input code:** the Mac keeps the same input code across launches (`UserDefaults` key `inputToken`). The Android app saves the code it received over USB or that was typed, so later Wi-Fi connections keep touch input.
- **Automatic mode:** see [Automatic start and headless streaming](#automatic-start-and-headless-streaming).
- **Reconnect:** the Android `StreamController` reconnects automatically with back-off. The host replaces a client when the same device (`clientId`) reconnects, when the current client has not answered pings for 3 s, or when the newcomer sends `takeOver: true` (a connection the user started on the device).

### Planned for Milestone 3

- **USB — Android Open Accessory (AOA).** The Mac host finds the phone with IOKit, sends the AOA control requests, and the phone re-enumerates as an accessory. No developer mode is needed.
- **Device detection.** USB attach/detach notifications (IOKit). Auto-stream mode currently polls `adb devices` every 3 s instead.
- **Pairing and security.**
  - The host shows a QR code: host address, port, SHA-256 fingerprint of its self-signed TLS certificate, one-time pairing secret.
  - The Android app connects over TLS 1.3, pins the fingerprint, and proves the pairing secret.
  - The host issues a long-term device credential, stored in the macOS Keychain and the Android Keystore.

---

## Project folder structure

```
DuetDisplay/
├── README.md
├── DOCUMENTATION.md
├── CHANGELOG.md
├── graphify-out/
├── macos/
│   ├── Package.swift
│   ├── .gitignore
│   ├── Sources/
│   │   ├── CGVirtualDisplayBridge/
│   │   │   ├── include/DSVirtualDisplay.h
│   │   │   ├── CGVirtualDisplayPrivate.h
│   │   │   └── DSVirtualDisplay.m
│   │   ├── VirtualDisplayKit/
│   │   │   ├── VirtualDisplayConfiguration.swift
│   │   │   ├── VirtualDisplayError.swift
│   │   │   ├── VirtualDisplayManager.swift
│   │   │   ├── DisplayInspector.swift
│   │   │   ├── DisplayConfigurator.swift
│   │   │   ├── ScreenSupport.swift
│   │   │   └── VirtualDisplaySelfTest.swift
│   │   ├── StreamKit/
│   │   │   ├── Wire.swift
│   │   │   ├── StreamSession.swift
│   │   │   ├── StreamServer.swift
│   │   │   ├── DisplayCapturer.swift
│   │   │   ├── VideoEncoder.swift
│   │   │   ├── AnnexB.swift
│   │   │   ├── FlowControl.swift
│   │   │   └── AdbBridge.swift
│   │   ├── InputKit/
│   │   │   ├── InputInjector.swift
│   │   │   └── KeyMap.swift
│   │   ├── droidscreen-vd/main.swift
│   │   └── DroidScreenHost/
│   │       ├── DroidScreenHostApp.swift
│   │       ├── HostViewModel.swift
│   │       ├── LoginItem.swift
│   │       └── ContentView.swift
│   ├── Tests/
│   │   ├── VirtualDisplayKitTests/VirtualDisplayKitTests.swift
│   │   ├── StreamKitTests/StreamKitTests.swift
│   │   └── InputKitTests/InputKitTests.swift
│   ├── Resources/
│   │   ├── Info.plist
│   │   └── DroidScreenHost.entitlements
│   └── scripts/
│       ├── build-app.sh
│       └── create-local-signing-identity.sh
└── android/
    ├── settings.gradle.kts           rootProject "DroidScreenReceiver", module :app
    ├── build.gradle.kts              AGP 9.2.1, Kotlin Compose plugin 2.3.20
    ├── gradle.properties
    ├── .gitignore                    also ignores release.keystore, keystore.properties
    ├── keystore.properties           (local only, not in git)
    ├── release.keystore              (local only, not in git)
    └── app/
        ├── build.gradle.kts
        └── src/
            ├── main/AndroidManifest.xml
            ├── main/java/com/droidscreen/receiver/
            │   ├── MainActivity.kt
            │   ├── protocol/Wire.kt
            │   ├── discovery/MacDiscovery.kt
            │   ├── decoder/NalParser.kt
            │   ├── decoder/VideoDecoder.kt
            │   ├── session/StreamController.kt
            │   ├── session/StreamViewModel.kt
            │   ├── input/TouchInputHandler.kt
            │   └── ui/Screens.kt
            └── test/java/com/droidscreen/receiver/ProtocolTest.kt
```

Planned for Milestone 3: AOA transport, QR pairing and TLS.

---

## CGVirtualDisplayBridge

Objective-C target. Path: `macos/Sources/CGVirtualDisplayBridge/`. Compiled with ARC (enforced with `#error`).

### `DSVirtualDisplay`

| Member | Description |
|---|---|
| `+isAPIAvailable` | `YES` when all required private classes and selectors exist. |
| `+apiAvailabilityReport` | Text listing each class as present/MISSING and any missing selectors. |
| `-initWithDescriptor:queue:terminationHandler:error:` | Creates the display. Swift: `try DSVirtualDisplay(descriptor:queue:terminationHandler:)`. |
| `-applyModes:hiDPI:error:` | Publishes modes. Swift: `try display.apply(_:hiDPI:)`. |
| `displayID` | `CGDirectDisplayID`; `0` after invalidation. |
| `invalidated` | `YES` after `-invalidate`. |
| `-invalidate` | Releases the `CGVirtualDisplay`; macOS removes the display. |

### Errors (`DSVirtualDisplayErrorDomain`)

`APIUnavailable` (1), `CreationFailed` (2), `ApplySettingsFailed` (3), `InvalidArgument` (4), `Exception` (5), `Invalidated` (6).

### Runtime lookup

Private classes are instantiated with `NSClassFromString`. The binary has no link-time reference to private symbols. Calls are wrapped in `@try/@catch`.

---

## VirtualDisplayKit

Swift target. Path: `macos/Sources/VirtualDisplayKit/`.

### `VirtualDisplayConfiguration`

| Property | Type | Default | Meaning |
|---|---|---|---|
| `name` | `String` | `"DroidScreen"` | Name in System Settings |
| `resolution` | `PixelSize` | — | Primary resolution in pixels |
| `additionalResolutions` | `[PixelSize]` | `[]` | Extra resolutions offered |
| `refreshRates` | `[Double]` | `[60, 30]` | Refresh rates offered |
| `hiDPI` | `Bool` | `true` | Offer 2× variants and prefer them |
| `diagonalInches` | `Double` | `6.5` | Used for `physicalSizeMillimeters` |
| `serialNumber` | `UInt32` | `1` | macOS stores arrangement per vendor/product/serial |

Derived: `allResolutions`, `modes` (`[ModeSpec]`, primary first, highest rate first), `maxPixels`, `physicalSizeMillimeters`.

`validate()` throws `VirtualDisplayError.invalidConfiguration` when: name is empty; a size is outside `640×360…7680×4320`; a size is odd (H.264 needs even sizes); no refresh rates; a rate is outside `1…240`; diagonal is outside `1…100`.

Presets (`VirtualDisplayConfiguration.presets`):

| Index | Preset | Resolution | Extra | hiDPI | Diagonal |
|---|---|---|---|---|---|
| 0 | `phoneLandscape` | 2400×1080 | 1920×1080, 1280×720 | on | 6.5" |
| 1 | `fullHD` | 1920×1080 | 1280×720 | on | 10" |
| 2 | `hd720` | 1280×720 | — | off | 10" |

### `VirtualDisplayManager` (`@MainActor`)

```swift
let manager = VirtualDisplayManager()
let active = try await manager.create(.phoneLandscape)   // ActiveDisplay
print(active.displayID, active.configuration.serialNumber, active.appliedMode ?? "-", active.warnings)
await manager.remove()                                    // true when macOS reports it offline
```

- `create(_:appearanceTimeout:serialFallbacks:)` — defaults `appearanceTimeout: 5`, `serialFallbacks: 2`. See [creation sequence](#creation-sequence-virtualdisplaymanagercreate) and [serial number fallback](#serial-number-fallback). Throws `VirtualDisplayError`. Only one display per manager (`alreadyActive`).
- `remove(disappearanceTimeout:)` — default 5 s. Invalidates the display and waits until it is offline.
- `active` — `ActiveDisplay` (`displayID`, `configuration`, `createdAt`, `appliedMode`, `warnings`) or `nil`. `configuration.serialNumber` is the serial actually used.
- `onUnexpectedTermination` — called when WindowServer removes the display on its own.
- `freshSerial(excluding:)` — random serial in `1000…0xFFFFFF`, different from the argument.
- `isAPIAvailable`, `apiAvailabilityReport` — static diagnostics.
- Logs to `os.Logger` subsystem `com.droidscreen.host`, category `VirtualDisplay`. View with `log stream --predicate 'subsystem == "com.droidscreen.host"'`.

### `VirtualDisplayError`

`apiUnavailable`, `invalidConfiguration`, `alreadyActive`, `creationFailed`, `applySettingsFailed`, `displayDidNotAppear`, `displayConfigurationFailed(operation:code:)`, `noMatchingMode`. All conform to `LocalizedError`.

### `DisplayInspector`

Public CoreGraphics queries only.
- `onlineDisplayIDs()`, `isOnline(_:)`
- `snapshot(_:) -> DisplaySnapshot` — `isOnline`, `isActive`, `isMain`, `isBuiltin`, `isInMirrorSet`, `mirrorsDisplay`, `bounds`, `currentMode`, vendor/model/serial. Computed: `isDroidScreen`, `isExtendedDesktop`.
- `allDisplays()`, `availableModes(_:) -> [DisplayModeInfo]` (includes HiDPI duplicates).
- `physicalDisplayIDs()` — online displays where `isDroidScreen` and `isSystemPlaceholder` are false. Used by the host's auto-stream mode. An empty list means no physical display is connected. A sleeping display is still online and is counted. Virtual displays from other apps are counted as physical.
- `isSystemPlaceholder(vendor:model:)` / `DisplaySnapshot.isSystemPlaceholder` — `true` for vendor `0x756E6B6E` ('unkn') and model `0x76697274` ('virt'). macOS adds this 1920×1080 display as the main display when the last monitor is unplugged (observed on macOS 27.2, Apple M4).

### `DisplayConfigurator` and `DisplayModeMatcher`

- `DisplayConfigurator.ensureExtended(_:)` — un-mirrors via `CGConfigureDisplayMirrorOfDisplay(…, kCGNullDirectDisplay)`. Returns `true` if it changed something.
- `DisplayConfigurator.applyMode(_:pixelSize:preferHiDPI:refreshRate:)` — `CGConfigureDisplayWithDisplayMode`.
- Both commit with `CGCompleteDisplayConfiguration(…, .forSession)`. The user's saved preferences are not changed.
- `DisplayModeMatcher.bestMatch(in:pixelSize:preferHiDPI:refreshRate:)` — exact pixel size required; ranks by HiDPI match, then GUI-usable, then closest refresh rate (highest if `nil`).

### `ScreenSupport` (`@MainActor`)

- `displayID(of:)`, `screen(for:)` — map between `NSScreen` and `CGDirectDisplayID` (`NSScreenNumber`).
- `waitForScreen(_:timeout:)` — waits until AppKit lists the screen.
- `showTestWindow(on:title:)` — opens a movable, titled window centred on the screen.

### `VirtualDisplaySelfTest` (`@MainActor`)

`run(configuration:holdSeconds:progress:) async -> Report`. Checks, in order:

1. CGVirtualDisplay API present
2. Virtual display created
3. New display ID in online display list
4. Display is active (drawable)
5. Identity is DroidScreen (vendor/model)
6. Extended, not mirrored
7. Own region of the global desktop (no overlap with other active displays)
8. Requested resolution offered
9. AppKit lists it as an NSScreen
10. Window can be placed on it
11. Display removed cleanly

---

## Wire protocol

Version 1 (`WireProtocol.version`). Swift: `macos/Sources/StreamKit/Wire.swift`. Kotlin mirror: `android/app/src/main/java/com/droidscreen/receiver/protocol/Wire.kt`.

### Framing

Every message:

```
[type: u8][length: u32 big-endian][payload: length bytes]
```

- Header size 5 bytes (`WireProtocol.headerSize`, `Wire.HEADER_SIZE`).
- Maximum payload 16 MiB (`WireProtocol.maxPayload`). Larger lengths throw `WireError.payloadTooLarge` (Swift) or `ProtocolException` (Kotlin).
- `MessageParser` (Swift) parses the stream incrementally: `append(_:)`, then `next()` until it returns `nil`. Unknown types are returned too, so callers can skip them.

### Message types

| Code | Name | Direction | Payload |
|---|---|---|---|
| `0x01` | `hostHello` | host → client | JSON `HostHello` |
| `0x02` | `videoConfig` | host → client | JSON `VideoConfig` (stream size/codec changed; a keyframe follows) |
| `0x03` | `videoFrame` | host → client | `[flags u8, bit0 = keyframe][ptsMicros u64 BE][Annex-B access unit]` |
| `0x04` | `ping` | host → client | `[hostTimeMicros u64 BE]` |
| `0x05` | `hostBusy` | host → client | UTF-8 reason; the host then closes the connection |
| `0x81` | `clientHello` | client → host | JSON `ClientHello` (must be the first client message) |
| `0x82` | `pong` | client → host | `[hostTimeMicros u64 BE]` echoed from `ping` |
| `0x83` | `frameRendered` | client → host | `[ptsMicros u64 BE]` echoed from `videoFrame` after it was rendered or skipped |
| `0x84` | `keyframeRequest` | client → host | empty |
| `0x85` | `pointer` | client → host | `[action u8: 0 move, 1 down, 2 up][button u8: 0 left, 1 right][clickCount u8][flags u8: bit0 relative, bit1 at current cursor][x f32 BE][y f32 BE]` |
| `0x86` | `scroll` | client → host | `[dx f32 BE][dy f32 BE]`; positive `dy` = content moves down |
| `0x87` | `key` | client → host | `[down u8][androidKeyCode u16 BE][androidMetaState u32 BE][unicode u32 BE]` |

Pointer and scroll coordinates are normalised to the video image (0…1, origin top-left). Input messages (`0x85`–`0x87`) are ignored unless the client hello carried the session's input token.

### JSON payloads

`HostHello`:

```json
{"protocolVersion":1,"displayName":"DroidScreen","video":{"codec":"h264","width":1914,"height":862,"fps":60},"inputEnabled":true}
```

`VideoConfig`: `codec` (`"h264"` or `"hevc"`, enum `VideoCodec`), `width`, `height`, `fps`.

`ClientHello`:

```json
{
  "protocolVersion": 1,
  "deviceName": "Xiaomi 23129RAA4G",
  "screenWidth": 2400, "screenHeight": 1080, "densityDpi": 440,
  "codecs": ["h264", "hevc"],
  "inputToken": "…",
  "clientId": "…",
  "decoderMaxSize": {"h264": {"width": 1914, "height": 862}, "hevc": {"width": 1914, "height": 862}}
}
```

| Field | Meaning |
|---|---|
| `screenWidth`, `screenHeight` | Physical screen size in pixels (any orientation). |
| `codecs` | Codecs the device can decode. |
| `inputToken` | Optional. Session input token. Missing or wrong → view-only. |
| `clientId` | Optional. Random ID persisted on the device; identifies reconnects of the same device. |
| `takeOver` | Optional, default `false`. `true` when the user started the connection on the device (Connect button, tapping a discovered Mac, opening or returning to the app, intent extra `takeOver`). The host then switches to this device even if another device is streaming. Automatic retries send `false` after one streaming session. |
| `decoderMaxSize` | Optional. Per codec, the largest landscape size (width ≥ height) the device can decode at the host's frame rate. Type `[String: DecoderSize]`. A missing codec means no limit is known. Older clients without this field still decode. |

`ClientHello.decoderLimit(for:)` returns the limit for a `VideoCodec` as a landscape `PixelSize` (long side as width), or `nil`.

### Input token

`InputToken.generate()` returns 16 random bytes (`SecRandomCopyBytes`) as 32 hex characters. `InputToken.matches(_:_:)` compares in constant time.

---

## StreamKit

Swift target. Path: `macos/Sources/StreamKit/`. Depends on `VirtualDisplayKit` and `InputKit`. Links ScreenCaptureKit, VideoToolbox, CoreMedia and Network.

Pipeline:

```
virtual display ─▶ DisplayCapturer (ScreenCaptureKit, NV12)
                ─▶ VideoEncoder (VideoToolbox H.264/HEVC, no B-frames)
                ─▶ AnnexB (length-prefixed → start codes, parameter sets on keyframes)
                ─▶ ClientConnection (TCP, wire protocol)
```

### `StreamOptions`

| Property | Default | Meaning |
|---|---|---|
| `port` | `47800` | TCP port |
| `allowLAN` | `false` | `false`: listen on `127.0.0.1` only. `true`: all interfaces, unencrypted. |
| `codec` | `.h264` | Preferred codec. Falls back to H.264 when the client does not list it. |
| `fps` | `60` | Capture and encode frame rate |
| `maxBitrate` | `20_000_000` | Upper bitrate (bit/s) |
| `minBitrate` | `2_000_000` | Lower bitrate (bit/s) |
| `maxStreamSize` | `nil` | Upper bound for the encoded size (aspect ratio kept) |
| `matchClientResolution` | `true` | Shrink the stream to the client's screen size |
| `inputEnabled` | `true` | Accept input from clients with a valid token |
| `inputToken` | `nil` | Fixed input token. `nil` = generate a new one per session. |
| `bonjourName` | `nil` | Bonjour service name. `nil` = the computer name. |
| `advertiseBonjour` | `true` | Advertise `_droidscreen._tcp` when `allowLAN` is `true` |

### `StreamSession`

Streams one display to one Android client. All state lives on one serial queue.

```swift
var options = StreamOptions()
options.codec = .hevc
let session = StreamSession(displayID: active.displayID, displayName: "DroidScreen", options: options)
session.onStats = { stats in print(stats.summary) }
session.onEvent = { print($0) }
session.onDisplayLost = { /* recreate display, start a new session */ }
try session.start()
print(session.inputToken)
// …
await session.stop()
```

Public members:
- `init(displayID:displayName:options:)`
- `start()` / `stop() async`
- `setInputEnabled(_:)` — enables or disables input for the current and future clients.
- `inputToken` — `options.inputToken` if set, otherwise `InputToken.generate()`.
- `onStats` (`StreamStats`), `onEvent` (`String`), `onDisplayLost` — all called on the main queue.

Connection handling:
- A new connection stays pending until its `clientHello` arrives. No hello within 5 s → closed.
- A hello with a different `protocolVersion` or invalid JSON → closed.
- If another client is streaming, the newcomer replaces it only when it has the same `clientId`, the current client has not answered pings for 3 s, or the newcomer's hello has `takeOver: true` (event "<new> took over the stream from <old>"). Otherwise the newcomer gets `hostBusy` ("Streaming to <device>") and is closed after 0.5 s.
- `beginStreaming` picks the codec, computes the stream size, creates the encoder, checks the input token, sends `hostHello`, and starts capture.
- The host pings every second. A client without a pong for 5 s is dropped.

Display loss:
- A CoreGraphics display reconfiguration callback (`displayReconfigured`) reports removal of the streamed display. Capture start also checks `DisplayInspector.isOnline` and `StreamError.displayNotCapturable`.
- `markDisplayLost()` runs once: it tears down the client, sets state `failed("Virtual display <id> is no longer available")`, and calls `onDisplayLost`.
- New clients then receive `hostBusy` with "The Mac's virtual display is not available".

Display reconfiguration:
- Other reconfiguration callbacks are debounced by 0.3 s. When the computed stream size changes, the encoder is recreated, `videoConfig` is sent, a keyframe is forced and capture is updated with the new size.

Idle refresh:
- ScreenCaptureKit delivers frames only when the screen changes. After each capture, `scheduleIdleRefresh` waits `idleRefreshDelay` (0.15 s). If no newer capture arrived, the latest image is encoded once more.
- The refresh frame is sent but not added to the in-flight tracker, so a decoder that holds it back is not treated as a stall.

Keyframes and errors:
- `keyframeRequest` forces a keyframe and re-encodes the last captured image.
- An encoder error recreates the encoder and forces a keyframe.
- If capture stops, it restarts after 1 s.

### `StreamStats`

`state` (`stopped`, `listening`, `streaming`, `failed(String)`), `port`, `clientName`, `clientAddress`, `video`, `hardwareEncoder`, `lowLatencyRateControl`, `captureFPS`, `sentFPS`, `skippedFPS`, `renderedFPS`, `sentKbps`, `targetKbps`, `inFlight`, `rttMs`, `latencyMs`, `latencyP95Ms`, `totalFramesSent`, `totalKeyframes`, `clientSessions`, `inputAuthorized`, `accessibilityTrusted`, `inputEventsPerSecond`.

`summary` formats one line, e.g.:

```
h264 1914×862 | cap 57 sent 57 shown 56 skip 0 fps | 6.3 Mbps (target 20.0) | rtt 6 ms | latency 52 ms (p95 70)
```

Latency = (host time at `frameRendered`) − (capture timestamp) − RTT/2. Median and 95th percentile over the last 120 samples.

### `StreamGeometry`

`StreamGeometry.streamSize(display:client:cap:decoder:)` starts from the display's pixel size and shrinks it (aspect ratio kept) to fit:
- the client screen (`client`), turned to the display's orientation,
- the optional `cap` (`StreamOptions.maxStreamSize`),
- the client decoder limit (`decoder`, from `ClientHello.decoderLimit(for:)`), turned to the display's orientation.

It never upscales. Both dimensions are rounded down to even numbers.

Example: display 2400×1080, client 2400×1080, decoder limit 1914×862 → stream 1914×862.

### `VideoEncoder`

VideoToolbox compression session.
- Creation attempts, in order: H.264 only — hardware required + low-latency rate control; then hardware required; then hardware enabled (any encoder).
- `isHardware` is `true` when the session was created with `RequireHardwareAcceleratedVideoEncoder`, or when `UsingHardwareAcceleratedVideoEncoder` reports it. `isLowLatency` is `true` for the low-latency attempt.
- Properties: `RealTime`, no frame reordering (no B-frames), H.264 Constrained High / HEVC Main (auto level), keyframe interval `fps × 2` frames or 2 s, `MaximizePowerEfficiency` off, BT.709 colour tags.
- Bitrate: `AverageBitRate`. Without low-latency rate control, `DataRateLimits` allows 1.5× the average per second. `setBitrate(_:)` changes it while running.

### `AnnexB`

Converts VideoToolbox output (length-prefixed NAL units) into a `videoFrame` message with 4-byte start codes in one allocation. Keyframes are prefixed with the parameter sets (H.264: SPS, PPS; HEVC: VPS, SPS, PPS).

### `DisplayCapturer`

ScreenCaptureKit `SCStream` for one display. NV12 (`420YpCbCr8BiPlanarVideoRange`), BT.709, queue depth 4, cursor shown, no audio, `scalesToFit`. Only frames with status `.complete` are delivered. `update(size:fps:)` changes the configuration while running.

`ScreenCapturePermission.isGranted` (never prompts) and `ScreenCapturePermission.ensure()` (prompts the first time).

### Flow control (`FlowControl.swift`)

- `InFlightTracker(maxFrames: 4, maxAge: 0.15, staleTimeout: 1.0)` — frames sent but not acknowledged by `frameRendered`. Acknowledgements are cumulative. While 4 frames are unacknowledged, or the oldest is older than 0.15 s, new captures are skipped. Entries older than 1 s are dropped and a keyframe is forced.
- `BitrateController(minBitrate:maxBitrate:)` — AIMD. Any skipped frame → ×0.75 (at most once per second, not below `minBitrate`). 5 s without congestion → ×1.15 every 2 s, up to `maxBitrate`. Starts at `maxBitrate`.
- `LatencyEstimator(capacity: 120)` — rolling samples; `median`, `p95`.

### `StreamServer` and `ClientConnection`

- `StreamServer(port:allowLAN:queue:bonjourName:)` — `NWListener`, loopback-only unless `allowLAN`. With `allowLAN` and a non-nil `bonjourName`, sets `listener.service` to `NWListener.Service(name:type: "_droidscreen._tcp")` (`""` → computer name). See [USB and Wi-Fi architecture](#usb-and-wi-fi-architecture) for TCP options.
- `ClientConnection` — framed reads with `MessageParser`, fire-and-forget writes, all on the session queue.

### `StreamError`

`encoderUnavailable(OSStatus)`, `encodeFailed(OSStatus)`, `displayNotCapturable(UInt32)`, `screenRecordingDenied`, `invalidPort(UInt16)`.

### `AdbBridge`

- `locateADB()` — search order: `$ANDROID_HOME/platform-tools/adb`, `$ANDROID_SDK_ROOT/platform-tools/adb`, `~/Library/Android/sdk/platform-tools/adb`, `/opt/homebrew/bin/adb`, `/usr/local/bin/adb`, then `PATH`.
- `devices(adb:)` — serials in state `device` (authorised), passed through `uniqueDevices`.
- `uniqueDevices(_:)` — drops wireless-debugging entries (`adb-<serial>-<id>._adb-tls-connect._tcp`) whose `<serial>` is also attached over USB. A phone connected both ways is listed once.
- `reverseAll(port:)` — `adb -s <serial> reverse tcp:<port> tcp:<port>` for every device.
- `devices()` — `devices(adb:)` with `locateADB()`, or `[]` when adb is not installed.
- `isEmulator(_:)` — `true` for serials starting with `emulator-`.
- `setUpReceiver(adb:serial:port:inputToken:takeOver:)` — the setup below for one device. Used by the host's auto-stream mode (with `takeOver: false`). `takeOver: true` adds `--ez takeOver true`.
- `setUpReceivers(port:inputToken:takeOver:)` — `setUpReceiver` for every authorised device (`takeOver` default `false`; the host's Set up USB button and `droidscreen-vd serve --adb` pass `true`): `adb reverse`, then:

  ```bash
  adb -s <serial> shell am start -n com.droidscreen.receiver/.MainActivity \
      --es host 127.0.0.1 --ei port 47800 --ez autoConnect true --es inputToken <token>
  ```

  Returns one `Result` (`serial`, `succeeded`, `output`) per device. The token travels over adb, which talks only to devices the user has authorised.

---

## InputKit

Swift target. Path: `macos/Sources/InputKit/`. Links ApplicationServices.

### `InputPermission`

- `isTrusted` — `AXIsProcessTrusted()`.
- `request()` — shows the system prompt that leads to Privacy & Security › Accessibility. Returns the current state.

### `DisplayCoordinateMapper`

Maps normalised image positions (0…1, origin top-left) to global display coordinates of one display.
- `point(normalizedX:y:)` — clamps to 0…1 and keeps the point strictly inside the display bounds.
- `clamp(_:)`, `delta(normalizedX:y:)` (normalised delta → points).

### `InputInjector`

Posts mouse, scroll and keyboard events onto one display with `CGEvent`. Used from one serial queue.

| Method | Use |
|---|---|
| `move(toNormalizedX:y:)` | Absolute move (direct touch) |
| `move(byNormalizedX:y:)` | Relative move (trackpad mode) |
| `down(_:normalizedX:y:clickCount:)`, `up(…)` | Button press/release; position `nil` = current cursor. Moves while a button is held become drag events. |
| `releaseAll()` | Releases a held button (connection lost mid-drag) |
| `scroll(normalizedX:y:)` | Pixel scroll-wheel event; fractional remainders are carried over |
| `key(down:keyCode:unicode:flags:)` | Key event; `keyCode == nil` types the Unicode character instead |

`eventsPosted` counts posted events.

### `KeyMap`

- `androidToMac` — Android `KeyEvent` codes → macOS virtual key codes (ANSI layout, Carbon `kVK_*`). Keys not listed are typed by their Unicode character.
- `modifierKeyCodes` — Android modifier keys (shift, ctrl, alt, meta, caps lock, fn). They only change `metaState` on other keys and are not sent as separate key events.
- `flags(androidMetaState:)` — `META_SHIFT_ON` → Shift, `META_ALT_ON` → Option, `META_CTRL_ON` → Control, `META_META_ON` → Command, `META_CAPS_LOCK_ON` → Caps Lock.

---

## droidscreen-vd CLI

Path: `macos/Sources/droidscreen-vd/main.swift`. Runs an `NSApplication` run loop with `.accessory` policy (no Dock icon) so AppKit screens and windows work.

| Command | Description | Exit code |
|---|---|---|
| `probe` | Prints API availability and macOS version | 0 available, 1 not |
| `list` | Lists online displays with tags (main, built-in, DroidScreen, extended/mirrored) | 0 |
| `create [opts]` | Creates a display; keeps it until Ctrl-C, SIGTERM or `--duration` | 0 ok, 1 error, 2 removed by macOS |
| `selftest [opts]` | Runs `VirtualDisplaySelfTest` | 0 pass, 1 fail |
| `serve [opts]` | Creates a display and streams it to the Android app | 0 ok, 1 error, 2 display lost, 3 no Screen Recording permission |

Invalid arguments exit with 64.

Display options (`create`, `selftest`, `serve`): `--preset phone|1080p|720p`, `--size WxH`, `--extra WxH,WxH`, `--hz 60,30`, `--hidpi`, `--no-hidpi`, `--diagonal IN`, `--name NAME`, `--serial N`, `--duration SECONDS`, `--window` (`create`/`serve`).

`serve` options:

| Flag | Default | Meaning |
|---|---|---|
| `--port N` | 47800 | TCP port |
| `--lan` | off | Listen on all interfaces (unencrypted) |
| `--adb` | off | Run `AdbBridge.setUpReceivers`: `adb reverse` and start the Android app with the input token |
| `--codec h264\|hevc` | h264 | Preferred codec |
| `--fps N` | 60 | Frame rate, 1…120 |
| `--bitrate MBPS` | 20 | Maximum bitrate |
| `--min-bitrate MBPS` | 2 | Minimum bitrate |
| `--stream-size WxH` | — | Upper bound for the encoded size |
| `--no-match-client` | off | Do not shrink the stream to the phone's screen |
| `--stats-interval SECONDS` | 1 | Stats print interval, 0 = never |
| `--no-input` | off | View-only |

`serve` flow: checks Screen Recording permission (`ScreenCapturePermission.ensure()`), creates the display, starts a `StreamSession`, requests Accessibility permission if input is enabled, prints the input token, optionally runs the adb setup, then waits for Ctrl-C. Output lines are prefixed `[event]`, `[stats]`, `[input]`, `[adb]`. If the display is lost, `serve` exits with code 2.

Examples:

```bash
droidscreen-vd create --size 2340x1080 --hz 60 --diagonal 6.1 --window
droidscreen-vd selftest --preset 720p
droidscreen-vd selftest --duration 30     # keep it up 30 s to inspect System Settings
droidscreen-vd serve --adb                # USB
droidscreen-vd serve --lan --codec hevc --fps 30 --bitrate 10
```

---

## DroidScreenHost app

Path: `macos/Sources/DroidScreenHost/`. SwiftUI, single `Window("DroidScreen")`.

### `DroidScreenHostApp` / `AppDelegate`

- Sets `.regular` activation policy and calls `HostViewModel.applyLaunchArguments()` at launch.
- On quit (`applicationShouldTerminate`) it calls `HostViewModel.shutdown()`, which closes test windows, stops streaming and removes the display, then replies `true`.
- Quits when the last window closes.

### `HostViewModel`

Virtual display:
- `create()`, `remove()`, `refresh()`, `showTestWindow()`, `openDisplaySettings()` (opens `x-apple.systempreferences:com.apple.Displays-Settings.extension`), `runSelfTest()`.
- `createDisplay()` reads the serial from `UserDefaults` key `"displaySerial"` (if > 0), creates the display, and stores `result.configuration.serialNumber` back under `"displaySerial"`. macOS keeps the arrangement per serial, so the working serial is reused on the next launch.
- `refresh()` runs on `NSApplication.didChangeScreenParametersNotification`. If the active display is offline, it checks again after 1 s and then calls `recoverLostDisplay()`.

Streaming:
- `startStreaming()` — requires Screen Recording permission, creates the display if needed, builds `StreamOptions` from the UI (`codec`, `fps`, `maxBitrateMbps`, `minBitrate = min(2, maxBitrateMbps)` Mbps, `allowLAN`, `touchInputEnabled`), `inputToken = inputTokenForRun` and `bonjourName = Host.current().localizedName`, then starts a `StreamSession`.
- `inputTokenForRun` — read from `UserDefaults` key `"inputToken"` (32 hex characters); generated and stored when missing. Reused across launches.
- `received(event:)` — adds the event to `streamEvents` (Diagnostics) and writes it to the system log, subsystem `com.droidscreen.host`, category `Host`, level notice. `evaluateAutoStream()` also logs "Auto-stream check: N physical display(s), active …, streaming …" while the setting is on.

  ```bash
  log show --predicate 'subsystem == "com.droidscreen.host"' --info --last 1h
  ```

- `regenerateInputToken()` — stores a new code. Used from the next start of streaming.
- `stopStreaming()`, `stopStreamingClicked()`. Stopping an auto-started stream by hand ends auto-stream until a physical display is connected again.
- `setUpUSB()` — runs `AdbBridge.setUpReceivers` with the session port, token (only when touch input is on) and `takeOver: true`. Sets `usbWasSetUp`.
- `requestScreenRecording()`, `requestAccessibility()` — open the matching System Settings pane if not granted.
- `touchInputEnabled` calls `session.setInputEnabled(_:)` when changed.
- Stats are logged to category `Stats` every 5 s while streaming. The last 50 events are kept in `streamEvents`.

Display recovery (`recoverLostDisplay()`):
1. Triggered by `StreamSession.onDisplayLost` or by `refresh()`.
2. Stops streaming and removes the old display (`disappearanceTimeout: 1`).
3. Creates the display again (with the serial fallback in `VirtualDisplayManager.create`).
4. If it was streaming: starts streaming again with the same input token. If USB had been set up, runs `setUpUSB()` again after 1 s.

Start at login and auto-stream: see [Automatic start and headless streaming](#automatic-start-and-headless-streaming).

Launch arguments (`applyLaunchArguments()`, read from `UserDefaults`). After applying them, it schedules the auto-stream check (1 s).

| Argument | Effect |
|---|---|
| `-autoServe YES` | Start streaming at launch |
| `-autoUSB YES` | With `-autoServe`: run `setUpUSB()` 1.5 s later |
| `-codec h264\|hevc` | Codec |
| `-fps N` | Frame rate |
| `-bitrateMbps N` | Maximum bitrate |
| `-preset N` | Preset index (0 phone, 1 1080p, 2 720p) |
| `-touchInput YES\|NO` | Touch input on/off |

```bash
open build/DroidScreen.app --args -autoServe YES -autoUSB YES
open build/DroidScreen.app --args -autoServe YES -codec hevc -fps 30 -bitrateMbps 10 -preset 1 -touchInput NO
```

### `ContentView`

- **Virtual display:** preset picker, HiDPI toggle, Create/Remove, Displays settings…, Test window.
- **Streaming:** Screen Recording notice with Grant…, codec (H.264/HEVC), FPS (15/30/60), max bitrate (5/10/20/40 Mbps), "Allow Wi-Fi/LAN connections, advertised over Bonjour", Touch input toggle with Accessibility notice, input code for manual (Wi-Fi) connections with a "New code" button, Start/Stop streaming, Set up USB (adb).
- **Automation:** "Start DroidScreen at login" (with "Needs approval" and Open Login Items… when macOS requires approval), "Stream to Android automatically when no physical display is connected", and an "Automatic streaming is active" label.
- **Status:** virtual display ID, arrangement, mode, connection, stream, encoder (hardware / low-latency rate control), FPS (captured/sent/shown/skipped), bitrate, round trip, estimated latency, touch input state.
- **Diagnostics:** self-test button and the self-test/event log.

### Automatic start and headless streaming

Goal: the Mac app starts by itself, and when no physical display is connected it streams to an Android device over Wi-Fi/LAN or USB.

**Start at login** (`LoginItem.swift`)
- `LoginItem.setEnabled(_:)` calls `SMAppService.mainApp.register()` / `unregister()`.
- `LoginItem.isEnabled` / `needsApproval` read `SMAppService.mainApp.status` (`.enabled` / `.requiresApproval`).
- `HostViewModel.setLaunchAtLogin(_:)` updates `launchAtLogin` and `launchAtLoginNeedsApproval`. When approval is needed, it opens System Settings › General › Login Items (`SMAppService.openSystemSettingsLoginItems()`).
- Login items run after a user logs in. On a Mac without a display, enable automatic login (System Settings › Users & Groups) so the app starts after a reboot.

**Auto-stream** (`HostViewModel`)
- Setting `autoStreamWhenNoDisplay`, stored in `UserDefaults` key `"autoStreamWhenNoDisplay"`.
- `scheduleAutoStreamCheck(delay:)` runs `evaluateAutoStream()` after the delay (default 2 s). It runs on every `didChangeScreenParametersNotification`, when the setting changes, and 1 s after launch.
- `evaluateAutoStream()`:
  - `DisplayInspector.physicalDisplayIDs()` is empty, the setting is on, and streaming is not running → saves `allowLAN`, sets `allowLAN = true`, calls `startStreaming()` (creates the virtual display; it becomes the main display), sets `autoStreamActive = true` and starts the automatic USB setup.
  - A physical display is online and `autoStreamActive` is true → `endAutoStream(removeDisplay: true)`: stops the USB loop, restores `allowLAN`, stops streaming and removes the virtual display.
- Automatic USB setup (`startAutoUSB()`): every 3 s, `AdbBridge.devices()` without emulators (`AdbBridge.isEmulator`); each new serial gets `AdbBridge.setUpReceiver(serial:port:inputToken:)` (no `takeOver`). A serial that disappears and returns is set up again. Results go to the Diagnostics log.
- If the auto-started stream is no longer running (display creation failed, display removed), the loop ends auto-stream and checks again after 10 s.
- Clicking Stop streaming during auto-stream sets `autoStreamSuppressed`. Auto-stream stays off until a physical display is connected again or the setting is turned off.

Requirements for unattended use:
- Screen Recording permission must already be granted (it cannot be granted without a screen). Grant Accessibility for touch input.
- USB: adb installed (see `AdbBridge.locateADB()`), USB debugging enabled and the Mac authorised on the phone.
- Wi-Fi: the phone is on the same network, the DroidScreen app is open on the phone, and "Connect automatically" is on. The phone uses the saved input code for touch input.

Setup:
1. In the Mac app, turn on **Start DroidScreen at login** and **Stream to Android automatically when no physical display is connected**.
2. Connect the phone once over USB (Set up USB) so it saves the input code, or type the code on the phone.
3. On the phone, turn on **Connect automatically**.

---

## Build and packaging

```bash
cd macos
scripts/create-local-signing-identity.sh   # once per Mac
swift build                                # debug build of all targets
swift test                                 # VirtualDisplayKitTests, StreamKitTests, InputKitTests
scripts/build-app.sh                       # → build/DroidScreen.app (release)
CONFIG=debug scripts/build-app.sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh
SIGN_IDENTITY=- scripts/build-app.sh       # force ad-hoc
```

`build-app.sh` builds the `DroidScreenHost` product, copies the binary and `Resources/Info.plist` (bundle ID `com.droidscreen.host`, version 0.1.0, minimum macOS 14.0) into the bundle, signs it with `Resources/DroidScreenHost.entitlements` (identity order in [Signing (macOS)](#signing-macos)), runs `codesign --verify --strict`, and prints the identity used.

---

## Android receiver app

Gradle project in `android/`, module `:app`. Kotlin, Jetpack Compose (Material 3). Package `com.droidscreen.receiver`. `minSdk 29`, `targetSdk 36`, `compileSdk 36`, `versionCode 2`, `versionName "0.2.0"`. Java 17.

### `MainActivity`

- Single activity, `launchMode="singleTask"`. Rotation and resize changes are handled in-process (`configChanges`), so the decoder and its `Surface` are not torn down.
- `onCreate` passes the intent to `StreamViewModel.onLaunch` (first creation only). `onNewIntent` passes it to `StreamViewModel.applyIntent`.
- `dispatchKeyEvent` forwards keys to `StreamViewModel.onKeyEvent`.
- `onStart` → `onForeground()`, `onStop` → `onBackground()`. The stream runs only while the activity is visible.

### `protocol/Wire.kt`

Kotlin mirror of the [wire protocol](#wire-protocol).
- `Wire` — constants (`VERSION`, `DEFAULT_PORT = 47800`, message codes), `message`, `u64Message`, `readU64`, `clientHello`.
- `VideoConfig`, `HostHello` — parsed from JSON.
- `ClientHello` — `protocolVersion`, `deviceName`, `screenWidth`, `screenHeight`, `densityDpi`, `codecs`, `inputToken` (omitted when blank), `clientId`, `decoderMaxSize` (`Map<String, Pair<Int, Int>>`, written as `{"codec": {"width", "height"}}`).
- `InputWire` — builders for `pointer` (`move`, `moveBy`, `down`, `up`, `downAtCursor`, `upAtCursor`), `scroll`, `key`.
- `MessageReader` — blocking reader; `BufferPool` reuses large frame buffers.

### `decoder/NalParser.kt`

- `units(buffer, offset, length)` — splits an Annex-B access unit at 3- and 4-byte start codes.
- `codecSpecificData(codec, …)` — H.264: `csd-0` = SPS, `csd-1` = PPS. HEVC: `csd-0` = VPS + SPS + PPS. Returns `null` if a parameter set is missing.

### `decoder/VideoDecoder.kt`

MediaCodec decoder that renders to a `Surface`.
- Own thread with a 4-frame input queue. `submit` blocks when the queue is full, which stops socket reads (TCP back-pressure).
- The codec is (re)created from the parameter sets of the next keyframe after a configuration change or error. Non-keyframes before that are dropped and a keyframe is requested.
- When several decoded frames are ready, only the newest is rendered. Older ones are released without rendering.
- Every frame is reported through `Listener.onFrameDone(ptsUs, rendered)`. Frames that are not queued into the decoder are also reported (as skipped), so the host's in-flight count stays correct. `StreamController` sends `frameRendered` for each.
- `createCodec` tries each candidate decoder (the remembered working one first, then `decoderCandidates`: hardware first, then low-latency capable) with each configuration variant:
  - `FULL` — `KEY_PRIORITY 0`, `KEY_MAX_INPUT_SIZE`, `KEY_LOW_LATENCY` (API 30+, if `FEATURE_LowLatency`), and `vendor.qti-ext-dec-low-latency.enable` on Qualcomm decoders (`c2.qti*`, `OMX.qcom*`).
  - `NO_VENDOR_KEYS` — the same without the Qualcomm vendor key.
  - `PLAIN` — only size and codec-specific data.
  
  The first decoder/variant pair that configures and starts is remembered (`workingDecoder`, `workingVariant`) for the rest of the app run. Reason: some vendor decoders (seen on `c2.qti.avc.decoder`) reject optional keys with `BAD_VALUE`.
- `maxDecodeSize(codec, screenLong, screenShort, fps = 60.0)` — largest landscape size with the screen's aspect ratio that a decoder supports at `fps`. Hardware decoders are searched first; software decoders only if no hardware decoder qualifies. Sizes are even. Returns `null` if nothing qualifies.
- `supportedCodecs()` — `"h264"` and/or `"hevc"`, depending on the installed decoders.

### `session/StreamController.kt`

Owns the TCP connection and the decoder.
- `start(host, port, takeOver = false)`, `startAuto(takeOver = false, candidates)`, `stop()`, `close()`, `attachSurface(surface)`, `detachSurface()`, `sendInput(bytes)` (only while streaming).
- `startAuto(candidates: () -> List<Pair<String, Int>>)` — the list is read before every attempt. A failed attempt moves to the next candidate. A candidate that streamed for 5 s or more is tried first again. With an empty list the state is `Searching` and the list is checked every second. `start` and `startAuto` are idempotent for the same target ("host:port" or "auto").
- `takeOverPending` — set by `start`/`startAuto` with `takeOver = true`; every hello carries it until a session receives `hostHello`, then it is cleared. If the loop for the same target is already running and not streaming (e.g. rejected as busy), a `takeOver` request closes the current attempt so the next one carries the flag.
- `helloProvider: (takeOver: Boolean) -> ClientHello`.
- `state: StateFlow<State>` — `Idle`, `Connecting(host, port, attempt, lastError)`, `Searching(attempt, lastError)`, `Streaming(displayName, video, inputEnabled)`.
- `stats: StateFlow<Stats>` — `renderedFps`, `skippedFps`, `receivedKbps`, `decoderName`, `hardwareDecoder`, `keyframeRequests`, `sessions`.
- Connects with a 3 s timeout, `tcpNoDelay`, and a 5 s read timeout (the host pings every second), sends `clientHello`, then reads messages.
- Handles `videoFrame`, `ping` (answers `pong`), `hostHello` (checks protocol version), `hostBusy` (ends the session with "Mac is busy: <reason>"), `videoConfig`.
- Reconnect back-off: delay `min(3000, 300 × attempt)` ms. The attempt counter resets to 1 only after a session that streamed for at least 5 s. A session that ends sooner keeps increasing the back-off.
- The decoder exists only while a `Surface` is attached. Frames without one are dropped.

### `session/StreamViewModel.kt`

UI state (`AndroidViewModel`). Persists `host`, `port`, `showStats`, `touchMode`, `inputToken`, `autoConnect` and a random `clientId` in `SharedPreferences` `"droidscreen"`.
- `connect()` — `connectAuto()` when `autoConnect` is on, otherwise `connectTo(host)`.
- `connectTo(address, takeOver = true)` — connects to one fixed address.
- `connectAuto(takeOver = true)` — `StreamController.startAuto` with the candidates: every Mac in `discovery.hosts`, then `127.0.0.1:<port>` (USB through `adb reverse`). `autoMode` is true while connected this way.
- `onLaunch(intent)` — `applyIntent(intent)`; if that did not connect and `autoConnect` is on, `connectAuto()`.
- `disconnect()`, `onForeground()` (starts `discovery`, resumes the connection; a return to the app, not the first start, is sent with `takeOver`), `onBackground()` (stops `discovery` and the connection).
- `discovery: MacDiscovery`.
- `applyIntent(intent)` — intent extras:

  | Extra | Type | Effect |
  |---|---|---|
  | `host` | String | Host address |
  | `port` | int | Port |
  | `showStats` | boolean | Stats overlay |
  | `inputToken` | String | Session input token |
  | `touchMode` | String | `direct` or `trackpad` |
  | `autoConnect` | boolean | Connect immediately to `host` (`connectTo`) |
  | `takeOver` | boolean | With `autoConnect`: ask the Mac to switch to this device. Default `false`. |

  ```bash
  adb shell am start -n com.droidscreen.receiver/.MainActivity \
      --es host 10.0.2.2 --ei port 47800 --ez autoConnect true
  ```

- `onKeyEvent(event)` — forwards hardware-keyboard events as `key` messages. System keys (back, home, volume, power) stay with Android. The Unicode character is computed without Ctrl/Meta.
- `clientHello(context, inputToken, clientId, takeOver = false)` — screen size from `maximumWindowMetrics` (API 30+) or display metrics, codecs from `VideoDecoder.supportedCodecs()`, `decoderMaxSize` from `VideoDecoder.maxDecodeSize` per codec.

### `discovery/MacDiscovery.kt`

DNS-SD discovery of Mac hosts with `NsdManager`.
- `SERVICE_TYPE = "_droidscreen._tcp"` (matches `WireProtocol.bonjourServiceType`).
- `start()`, `stop()`, `isRunning`. `stop()` clears the list.
- `hosts: StateFlow<List<DiscoveredMac>>` — `DiscoveredMac(name, host, port)`. Found services are resolved one at a time; an IPv4 address is preferred (`hostAddresses` on API 34+, `host` before). Lost services are removed by name.
- Runs while the activity is in the foreground.

### `input/TouchInputHandler.kt`

Turns touches on the video view into `pointer` and `scroll` messages. Positions are normalised to the view, which has the video's aspect ratio. Mode `TouchMode`:

| Gesture | `DIRECT` | `TRACKPAD` |
|---|---|---|
| Tap | Left click at the finger | Left click at the cursor |
| Second tap | Double click | Double click |
| Long press (450 ms) | Right click | Right click |
| One-finger drag | Left-button drag | Moves the cursor (sensitivity 1.5) |
| Two-finger drag | Scroll | Scroll |

### `ui/Screens.kt`

- `ConnectScreen` — "Connect automatically (find the Mac on Wi-Fi or USB)" switch, "Macs on this network" buttons (tap to connect to that Mac), Mac address (disabled while Connect automatically is on), port, touch input code, touch mode chips (Direct/Trackpad), "Show stream statistics" switch, Connect button, short help text.
- `StreamScreen` — `SurfaceView` with the video's aspect ratio, immersive full screen, screen kept on, landscape. Back disconnects. Status text while connecting/reconnecting, and "Searching for your Mac on Wi-Fi and USB…" while no Mac is found. Optional stats overlay: codec and size, rendered fps (skipped), Mbps, decoder name with "(HW)", touch mode or "view-only".

---

## Android build and release signing

```bash
cd android
./gradlew :app:assembleDebug          # → app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:assembleRelease        # → app/build/outputs/apk/release/app-release.apk
./gradlew :app:testDebugUnitTest      # unit tests
```

Release signing:
- `android/app/build.gradle.kts` reads `android/keystore.properties` if it exists. Keys: `storeFile` (path relative to `android/`), `storePassword`, `keyAlias`, `keyPassword`.
- With the file, a `release` signing config is created and used by the `release` build type. Without it, `assembleRelease` produces an unsigned APK.
- `keystore.properties` and `release.keystore` are listed in `android/.gitignore`.

```properties
# android/keystore.properties (format; values are local)
storeFile=release.keystore
storePassword=…
keyAlias=…
keyPassword=…
```

Notes:
- Release and debug builds are signed with different keys. Android does not install one over the other. To switch between them on a device, uninstall the app first (`adb uninstall com.droidscreen.receiver`).
- Updates to an installed release build must be signed with the same key. Keep a backup of `release.keystore` and `keystore.properties`.

---

## Tests

| Suite | Path | Tests |
|---|---|---|
| `VirtualDisplayKitTests` | `macos/Tests/VirtualDisplayKitTests/` | 10: configuration, presets, validation, `PixelSize` parsing, `DisplayModeMatcher` |
| `StreamKitTests` | `macos/Tests/StreamKitTests/` | 22: `WireTests`, `AnnexBTests`, `FlowControlTests`, `StreamGeometryTests`, `InputMessageTests` (incl. input token), `AdbBridgeTests` (`uniqueDevices`), `DecoderLimitTests` (`decoderMaxSize`, stream capping, old hello without the field) |
| `InputKitTests` | `macos/Tests/InputKitTests/` | 5: `DisplayCoordinateMapper`, `KeyMap` |
| Android unit tests | `android/app/src/test/java/com/droidscreen/receiver/ProtocolTest.kt` | 13: `WireTest`, `NalParserTest`, `InputWireTest`, `DecoderLimitWireTest` (`decoderMaxSize` in the client hello JSON) |

Run:

```bash
cd macos && swift test
cd android && ./gradlew :app:testDebugUnitTest
```

Latest results: all three Swift test suites pass (37 tests). Android unit tests: 13 passed (WireTest 5, NalParserTest 4, InputWireTest 3, DecoderLimitWireTest 1).

---

## Milestone 1 verification results

Machine: Apple M4, macOS 27.2 (26B123), one external DELL P2314H (1920×1080) as main display.

`droidscreen-vd selftest` (phone preset): **11/11 checks passed.**

```
[PASS] New display ID in online display list   online IDs: [3, 5]
[PASS] Identity is DroidScreen                 vendor=0x4453 model=0x4D31 serial=1
[PASS] Extended, not mirrored                  inMirrorSet=false mirrors=0
[PASS] Own region of the global desktop        bounds=(1920.0, 0.0, 1200.0, 540.0)
[PASS] Requested resolution offered            current=1200×540 pt (HiDPI, 2400×1080 px)@60Hz
[PASS] AppKit lists it as an NSScreen          frame=(1920.0, 540.0, 1200.0, 540.0) scale=2.0
[PASS] Window can be placed on it              window.screen=5
[PASS] Display removed cleanly                 online IDs after removal: [3]
```

`--preset 720p` (current `1280×720@60Hz`) and `--preset 1080p` (current `960×540 pt (HiDPI, 1920×1080 px)@60Hz`): 11/11 passed.

`system_profiler SPDisplaysDataType` while the display was up:

```
DroidScreen:
  Resolution: 2400 x 1080
  UI Looks like: 2400 x 1080 @ 60.00Hz
  Mirror: Off
  Online: Yes
```

(That sample was taken during a run before mode selection was added, so it shows the 1× mode.)

---

## Milestone 2 verification results

Host: Apple M4, macOS 27.2. Device: Xiaomi Redmi 23129RAA4G (Qualcomm Snapdragon "khaje"). Hardware decoders on this device support at most 1920×1088 at 60 fps for H.264 and HEVC. Connection: USB via `adb reverse`.

| Measurement | Value |
|---|---|
| Stream | H.264 1914×862 (display 2400×1080 capped by `decoderMaxSize`) |
| Decoder | `c2.qti.avc.decoder.low_latency` (hardware) |
| Frame rate shown during motion | 54–57 fps |
| Latency (median) | ~52 ms |
| Latency (p95) | 66–78 ms |
| Round trip | 4–9 ms |

Touch input end-to-end was not yet confirmed on the device.

---

## Acceptance test status

| # | Test | Status |
|---|---|---|
| 1 | macOS detects the virtual display as a separate monitor | Verified (self-test checks 3–5, `system_profiler`) |
| 2 | User can extend the desktop onto it | Verified (checks 6–7: not mirrored, own desktop region) |
| 3 | A window can be dragged from the Mac screen to Android | Window placement on the display verified (check 10). Dragging past the main screen's edge moves a window onto the display, which is streamed to Android. |
| 4 | Android shows the extended desktop | Verified (Xiaomi Redmi 23129RAA4G over USB) |
| 5 | Android display updates continuously | Verified (54–57 fps shown during motion) |
| 6 | Touch input controls the Mac | Implemented (`TouchInputHandler`, `InputInjector`, input token over adb). End-to-end on device pending. |
| 7 | USB disconnection does not crash the host | Implemented: the host drops a client after 5 s without pong; the Android app detects a dead link with a 5 s read timeout and reconnects with back-off. Not yet verified on device. |
| 8 | Wi-Fi reconnection works | Partly implemented: LAN listening (`--lan` / "Allow Wi-Fi/LAN connections", unencrypted), Bonjour advertising and `NsdManager` discovery, manual IP entry and automatic reconnect. QR pairing and TLS are planned for Milestone 3. Not yet verified. |
| 11 | Mac starts at login and streams to Android when no physical display is connected | Implemented (`LoginItem`, `evaluateAutoStream`, `startAutoUSB`, Android `connectAuto`). Builds and unit tests pass. Not yet verified on device. |
| 9 | Resolution changes are handled | Implemented: display reconfiguration recreates the encoder and sends `videoConfig`; the Android app reconfigures the decoder. Not yet verified on device. |
| 10 | Latency and FPS are measurable | Verified (host `StreamStats` / Status panel and Android stats overlay; ~52 ms median latency, 54–57 fps) |
