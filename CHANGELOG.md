# Changelog

## 2026-11-24
### Fixed
- Auto-stream did not start after unplugging the last monitor: macOS adds a placeholder display (vendor 'unkn', model 'virt'), which `DisplayInspector.physicalDisplayIDs()` counted as physical. It is now excluded (`DisplayInspector.isSystemPlaceholder(vendor:model:)`, `DisplaySnapshot.isSystemPlaceholder`). Test `PhysicalDisplayTests`.
- Reconnecting a phone after pressing back could fail with "Mac is busy: Streaming to <other device>" when another device (here the Android emulator `emulator-5554`) connected in the gap. A connection the user starts now takes the stream back: `ClientHello.takeOver` (Mac `Wire.swift`, Android `protocol/Wire.kt`), checked in `StreamSession.promote`. Android sends it from Connect, a tapped discovered Mac, app start and return to the app (`StreamController.takeOverPending`, `StreamViewModel.userInitiated`). Automatic retries do not send it.
- Automatic USB setup no longer starts the receiver on Android emulators (`AdbBridge.isEmulator`).
### Added
- Git repository: root `.gitignore` (`.DS_Store`, `graphify-out/cache/`); graphify git hooks installed (`graphify hook install`) and merge driver for `graphify-out/graph.json` in `.gitattributes`.
- Host diagnostics events are written to the system log (subsystem `com.droidscreen.host`, category `Host`), including each auto-stream check.
- `AdbBridge.setUpReceiver(…, takeOver:)` / `setUpReceivers(…, takeOver:)` and intent extra `takeOver`. The Set up USB button and `droidscreen-vd serve --adb` use `takeOver: true`.
- Tests: `testClientHelloDecodesTakeOver`, `AdbBridge.isEmulator` cases, Android `takeOver` JSON checks.
- Mac: "Start DroidScreen at login" (`LoginItem.swift`, `SMAppService.mainApp`), `HostViewModel.setLaunchAtLogin(_:)`, `openLoginItemsSettings()`.
- Mac: auto-stream when no physical display is connected. `HostViewModel.autoStreamWhenNoDisplay` (`UserDefaults` key `autoStreamWhenNoDisplay`), `scheduleAutoStreamCheck(delay:)`, `evaluateAutoStream()`, `endAutoStream(removeDisplay:)`, `startAutoUSB()` (adb setup every 3 s for new devices), `autoStreamActive`.
- Mac: "Automation" section in `ContentView`; "New code" button (`regenerateInputToken()`).
- `DisplayInspector.physicalDisplayIDs()`.
- Bonjour advertising of the LAN listener: `WireProtocol.bonjourServiceType` (`_droidscreen._tcp`), `StreamOptions.bonjourName`, `StreamOptions.advertiseBonjour`, `StreamServer(…, bonjourName:)`.
- `AdbBridge.devices()` and `AdbBridge.setUpReceiver(adb:serial:port:inputToken:)`.
- `Info.plist`: `NSLocalNetworkUsageDescription`, `NSBonjourServices`.
- Android: `discovery/MacDiscovery.kt` (`NsdManager` discovery, `DiscoveredMac`).
- Android: "Connect automatically" (`StreamViewModel.autoConnect`, `connectAuto()`, `connectTo(address)`, `onLaunch(intent)`), `StreamController.startAuto(candidates)`, `State.Searching`, "Macs on this network" list on `ConnectScreen`.
### Changed
- Mac: the input code is stored in `UserDefaults` key `inputToken` and reused across launches (was generated per app run).
- Android: `inputToken` is saved in `SharedPreferences` (was not persisted).
- `AdbBridge.setUpReceivers` uses `setUpReceiver` per device.
- Android `MainActivity.onCreate` calls `StreamViewModel.onLaunch`; intent extra `autoConnect` connects with `connectTo(host)`.
- Documentation: README usage, DOCUMENTATION sections Permissions, USB and Wi-Fi architecture, DisplayInspector, StreamOptions, StreamServer, AdbBridge, HostViewModel, ContentView, new "Automatic start and headless streaming", Android MainActivity, StreamController, StreamViewModel, new `discovery/MacDiscovery.kt`, Screens, Acceptance test status.

## 2026-11-17
### Added
- Milestone 2: video streaming from the virtual display to Android.
- `StreamKit` target: wire protocol v1 (`Wire.swift`: `MessageType`, `HostHello`, `ClientHello`, `VideoConfig`, `MessageParser`, `InputMessage`, `InputToken`), `StreamSession`, `StreamServer`, `DisplayCapturer` (ScreenCaptureKit), `VideoEncoder` (VideoToolbox H.264/HEVC, low latency), `AnnexB`, `FlowControl` (`InFlightTracker`, `BitrateController`, `LatencyEstimator`, `StreamGeometry`), `AdbBridge`.
- `ClientHello.decoderMaxSize` (`[String: DecoderSize]`, optional), `DecoderSize`, `ClientHello.decoderLimit(for:)`. `StreamGeometry.streamSize(display:client:cap:decoder:)` caps the stream to the client's decoder limit.
- `StreamSession`: input token (`inputToken`, fixed token via `StreamOptions.inputToken`), `onDisplayLost` callback and `markDisplayLost` (new clients get `hostBusy` "The Mac's virtual display is not available"), idle refresh (`scheduleIdleRefresh`, `idleRefreshDelay` 0.15 s; the refresh frame is not tracked in flight), client replacement by `clientId`.
- `AdbBridge.setUpReceivers(port:inputToken:)` (`adb reverse` + `am start` with the input token) and `AdbBridge.uniqueDevices` (drops `adb-tls` wireless duplicates of USB serials).
- Milestone 4: `InputKit` target: `InputPermission`, `DisplayCoordinateMapper`, `InputInjector` (CGEvent mouse, scroll, keyboard), `KeyMap` (Android key codes → mac).
- `droidscreen-vd serve` command with `--port`, `--lan`, `--adb`, `--codec`, `--fps`, `--bitrate`, `--min-bitrate`, `--stream-size`, `--no-match-client`, `--stats-interval`, `--no-input`.
- `DroidScreenHost`: streaming controls, Set up USB (adb), touch input toggle, status and diagnostics panel, launch arguments `-autoServe`, `-autoUSB`, `-codec`, `-fps`, `-bitrateMbps`, `-preset`, `-touchInput`.
- `DroidScreenHost`: lost-display recovery (`recoverLostDisplay`: recreate display, restart streaming with the same input token, redo USB setup). The working display serial is stored in `UserDefaults` key `displaySerial`.
- `VirtualDisplayManager.create(_:appearanceTimeout:serialFallbacks:)`: retries with a fresh serial (`freshSerial(excluding:)`) when macOS does not bring the display online (observed on macOS 27.2). `ActiveDisplay.configuration.serialNumber` reports the serial used.
- `macos/scripts/create-local-signing-identity.sh`: creates the self-signed "DroidScreen Local Signing" identity in the login keychain.
- Android receiver app `android/` (Kotlin, Jetpack Compose, minSdk 29, targetSdk 36, versionName 0.2.0): `protocol/Wire.kt`, `decoder/NalParser.kt`, `decoder/VideoDecoder.kt`, `session/StreamController.kt`, `session/StreamViewModel.kt`, `input/TouchInputHandler.kt` (Direct/Trackpad), `ui/Screens.kt`, `MainActivity.kt`.
- `VideoDecoder`: configuration variants `FULL` / `NO_VENDOR_KEYS` / `PLAIN` tried across `decoderCandidates`, working pair remembered; `maxDecodeSize` (largest landscape size at 60 fps, hardware decoders preferred); frames not queued into the decoder are acknowledged as skipped.
- `StreamViewModel` intent extras `host`, `port`, `showStats`, `inputToken`, `touchMode`, `autoConnect`.
- Android release signing: `android/app/build.gradle.kts` reads `android/keystore.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`). `keystore.properties` and `release.keystore` are in `android/.gitignore`.
- Tests: `StreamKitTests` (incl. `AdbBridgeTests`, `DecoderLimitTests`), `InputKitTests`; Android `ProtocolTest.kt` (`WireTest`, `NalParserTest`, `InputWireTest`, `DecoderLimitWireTest`).
- `VideoEncoder.isHardware` is `true` for sessions created with `RequireHardwareAcceleratedVideoEncoder` (low-latency sessions do not answer the hardware query).
- Documentation: sections Wire protocol, StreamKit, InputKit, Android receiver app, Android build and release signing, Tests, Milestone 2 verification results.
- Milestone 1: macOS virtual display.
- `macos/` Swift package (`Package.swift`, swift-tools-version 5.10, macOS 14+).
- `CGVirtualDisplayBridge` Objective-C target: `DSVirtualDisplay`, `DSVirtualDisplayDescriptor` and `DSVirtualDisplayMode` wrap the private `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode` and `CGVirtualDisplaySettings` classes. Classes are resolved at runtime, and exceptions become `NSError`.
- `VirtualDisplayKit` Swift target: `VirtualDisplayConfiguration` (with presets `phoneLandscape`, `fullHD`, `hd720`), `VirtualDisplayManager`, `DisplayInspector`, `DisplayConfigurator`, `DisplayModeMatcher`, `ScreenSupport`, `VirtualDisplaySelfTest`, `VirtualDisplayError`.
- `droidscreen-vd` CLI with `probe`, `list`, `create` and `selftest` commands.
- `DroidScreenHost` SwiftUI app: create/remove display, status, test window, self-test.
- `scripts/build-app.sh` builds and signs `build/DroidScreen.app`. Adds `Resources/Info.plist` and `Resources/DroidScreenHost.entitlements`.
- Unit tests for configuration and mode matching (10 tests).
- `README.md`, `DOCUMENTATION.md`, `CHANGELOG.md`.

### Changed
- `StreamController`: reconnect back-off resets only after a session streamed for at least 5 s.
- `macos/scripts/build-app.sh`: signing identity order `$SIGN_IDENTITY` → "DroidScreen Local Signing" (by certificate hash) → ad-hoc. Developer ID identities get hardened runtime and a timestamp.
- Documentation: README status, requirements, build and usage for host and Android; "USB and Wi-Fi architecture" now describes the implemented TCP/adb/LAN transport and lists Milestone 3 items (AOA, Bonjour, QR pairing, TLS) as planned; permissions, project structure, CLI, host app and acceptance test status updated.

### Removed
- Documentation: outdated statements "There is no Android code yet", "Android (planned)" and "streaming arrives in Milestone 2".
