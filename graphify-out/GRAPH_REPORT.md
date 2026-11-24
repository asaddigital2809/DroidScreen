# Graph Report - DuetDisplay  (2026-11-24)

## Corpus Check
- 48 files · ~40,244 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 12 file(s) not represented in the graph (top: (none) 5, .properties 2, .xml 1)

## Summary
- 1084 nodes · 2426 edges · 79 communities (36 shown, 43 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 373 edges (avg confidence: 0.91)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- DroidScreen
- HostViewModel
- CGVirtualDisplayDescriptor
- serve
- VirtualDisplayError
- DisplayModeInfo
- VirtualDisplayManager
- VideoEncoder
- BufferPool
- DSVirtualDisplay
- Package.swift
- build-app.sh
- StreamSession
- ClientConnection
- StreamController
- InputInjector
- TouchInputHandler
- .waitForScreen
- ProtocolTest.kt
- InFlightTracker
- VideoDecoder
- Added
- DisplayCapturer
- Sendable
- InputMessage
- MainActivity.kt
- DSVirtualDisplay
- MessageType
- CGVirtualDisplayMode
- .append
- StreamScreen
- MacDiscovery.kt
- State
- -applyModeshiDPIerror
- StreamViewModel
- MessageParser
- CGVirtualDisplay
- Android receiver app
- .generate
- .codecSpecificData
- create-local-signing-identity.sh
- Wire.kt
- DSVirtualDisplay
- StatusGrid
- Callback
- Check

## God Nodes (most connected - your core abstractions)
1. `StreamSession` - 63 edges
2. `HostViewModel` - 50 edges
3. `Added` - 45 edges
4. `PixelSize` - 41 edges
5. `VirtualDisplayConfiguration` - 32 edges
6. `VideoDecoder` - 31 edges
7. `StreamController` - 27 edges
8. `DisplayCapturer` - 25 edges
9. `StreamViewModel` - 25 edges
10. `VirtualDisplayManager` - 25 edges

## Surprising Connections (you probably didn't know these)
- `Changed` --references--> `StreamController`  [INFERRED]
  CHANGELOG.md → android/app/src/main/java/com/droidscreen/receiver/session/StreamController.kt
- ``ScreenSupport` (`@MainActor`)` --references--> `ScreenSupport`  [INFERRED]
  DOCUMENTATION.md → macos/Sources/VirtualDisplayKit/ScreenSupport.swift
- ``VirtualDisplaySelfTest` (`@MainActor`)` --references--> `VirtualDisplaySelfTest`  [INFERRED]
  DOCUMENTATION.md → macos/Sources/VirtualDisplayKit/VirtualDisplaySelfTest.swift
- `Framing` --references--> `MessageParser`  [INFERRED]
  DOCUMENTATION.md → macos/Sources/StreamKit/Wire.swift
- ``StreamStats`` --references--> `StreamStats`  [INFERRED]
  DOCUMENTATION.md → macos/Sources/StreamKit/StreamSession.swift

## Import Cycles
- None detected.

## Communities (79 total, 43 thin omitted)

### Community 0 - "DroidScreen"
Cohesion: 0.10
Nodes (17): 2026-11-17, Changed, Changelog, Removed, Android receiver, Build, DroidScreen, Mac host (+9 more)

### Community 1 - "HostViewModel"
Cohesion: 0.06
Nodes (27): Stats, 2026-11-24, Added, Changed, Fixed, Acceptance test status, `AdbBridge`, Automatic start and headless streaming (+19 more)

### Community 2 - "CGVirtualDisplayDescriptor"
Cohesion: 0.47
Nodes (4): CGVirtualDisplayDescriptor, -setDispatchQueue, -setQueue, -initWithDescriptorqueueterminationHandlererror

### Community 3 - "serve"
Cohesion: 0.32
Nodes (7): CLIError, describe(), Options, printDisplays(), run(), serve(), waitForSignal()

### Community 4 - "VirtualDisplayError"
Cohesion: 0.12
Nodes (15): `ScreenSupport` (`@MainActor`), `VirtualDisplayError`, VirtualDisplayKit, `VirtualDisplayManager` (`@MainActor`), `VirtualDisplaySelfTest` (`@MainActor`), VirtualDisplayError, alreadyActive, apiUnavailable (+7 more)

### Community 5 - "DisplayModeInfo"
Cohesion: 0.16
Nodes (9): `DisplayInspector`, DisplayInspector, DisplayModeInfo, .description, .isHiDPI, DisplaySnapshot, .isDroidScreen, .isExtendedDesktop (+1 more)

### Community 6 - "VirtualDisplayManager"
Cohesion: 0.23
Nodes (4): ActiveDisplay, VirtualDisplayManager, .apiAvailabilityReport, .isAPIAvailable

### Community 7 - "VideoEncoder"
Cohesion: 0.05
Nodes (21): AppKit, CGVirtualDisplayBridge, Combine, CoreGraphics, CoreMedia, CoreVideo, `AnnexB`, Foundation (+13 more)

### Community 8 - "BufferPool"
Cohesion: 0.19
Nodes (3): BufferPool, MessageReader, Wire

### Community 9 - "DSVirtualDisplay"
Cohesion: 0.25
Nodes (4): DSVirtualDisplayDescriptor, DSVirtualDisplayMode, -init, -initWithWidthheightrefreshRate

### Community 14 - "StreamSession"
Cohesion: 0.09
Nodes (8): `StreamOptions`, `StreamSession`, Counters, displayReconfigured(), StreamOptions, StreamSession, StreamStats, .summary

### Community 15 - "ClientConnection"
Cohesion: 0.09
Nodes (11): ClientConnection, .endpointDescription, StreamError, displayNotCapturable, encodeFailed, encoderUnavailable, .errorDescription, invalidPort (+3 more)

### Community 17 - "StreamController"
Cohesion: 0.18
Nodes (8): Connecting, Connection, Idle, Searching, State, StreamController, Streaming, `session/StreamController.kt`

### Community 18 - "InputInjector"
Cohesion: 0.07
Nodes (15): ApplicationServices, `DisplayCoordinateMapper`, `InputInjector`, InputKit, `InputPermission`, `KeyMap`, DisplayCoordinateMapper, InputInjector (+7 more)

### Community 19 - "TouchInputHandler"
Cohesion: 0.11
Nodes (14): State, DRAGGING, IDLE, LONG_PRESSED, MOVING, PENDING, SCROLLING, TouchInputHandler (+6 more)

### Community 21 - "ProtocolTest.kt"
Cohesion: 0.14
Nodes (5): ClientHello, DecoderLimitWireTest, InputWireTest, WireTest, Tests

### Community 23 - "InFlightTracker"
Cohesion: 0.14
Nodes (10): `StreamGeometry`, BitrateController, Entry, InFlightTracker, .count, LatencyEstimator, .median, .p95 (+2 more)

### Community 24 - "VideoDecoder"
Cohesion: 0.10
Nodes (8): Frame, Listener, Variant, FULL, NO_VENDOR_KEYS, PLAIN, VideoDecoder, VideoConfig

### Community 25 - "Added"
Cohesion: 0.05
Nodes (24): Added, `DisplayConfigurator` and `DisplayModeMatcher`, `VirtualDisplayConfiguration`, .presetIndex, DisplayConfigurator, DisplayModeMatcher, ModeSpec, .description (+16 more)

### Community 26 - "DisplayCapturer"
Cohesion: 0.06
Nodes (21): Android, Android build and release signing, Build and packaging, `DisplayCapturer`, DroidScreen — Documentation, droidscreen-vd CLI, Flow control (`FlowControl.swift`), macOS (+13 more)

### Community 28 - "Sendable"
Cohesion: 0.21
Nodes (9): ClientHello, DecoderSize, HostHello, VideoCodec, h264, hevc, VideoConfig, WireProtocol (+1 more)

### Community 29 - "InputMessage"
Cohesion: 0.16
Nodes (9): InputMessage, key, pointer, scroll, PointerAction, down, move, up (+1 more)

### Community 31 - "DSVirtualDisplay"
Cohesion: 0.25
Nodes (7): DSVirtualDisplay, +apiAvailabilityReport, -applyModeshiDPIerror, -init, -initWithDescriptorqueueterminationHandlererror, -invalidate, +isAPIAvailable

### Community 32 - "MessageType"
Cohesion: 0.15
Nodes (13): MessageType, clientHello, frameRendered, hostBusy, hostHello, key, keyframeRequest, ping (+5 more)

### Community 33 - "CGVirtualDisplayMode"
Cohesion: 0.25
Nodes (8): Creation sequence (`VirtualDisplayManager.create`), Mode behaviour observed on macOS 27.2, Private classes used, Selected virtual display implementation, Serial number fallback, CGVirtualDisplayMode, -initWithWidthheightrefreshRate, CGVirtualDisplaySettings

### Community 35 - "StreamScreen"
Cohesion: 0.60
Nodes (5): ConnectScreen(), DroidScreenApp(), ImmersiveMode(), StreamScreen(), `ui/Screens.kt`

### Community 36 - "MacDiscovery.kt"
Cohesion: 0.10
Nodes (7): DiscoveredMac, MacDiscovery, ResolveListener, DiscoveryListener, Implemented, Planned for Milestone 3, USB and Wi-Fi architecture

### Community 37 - "State"
Cohesion: 0.40
Nodes (5): State, failed, listening, stopped, streaming

### Community 38 - "-applyModeshiDPIerror"
Cohesion: 0.24
Nodes (7): -applySettings, -applyModeshiDPIerror, DSVirtualDisplayDescriptor, -init, DSVirtualDisplayMode, -description, -initWithWidthheightrefreshRate

### Community 40 - "MessageParser"
Cohesion: 0.21
Nodes (6): `StreamServer` and `ClientConnection`, MessageParser, WireError, malformed, payloadTooLarge, WireTests

### Community 41 - "CGVirtualDisplay"
Cohesion: 0.22
Nodes (10): CGVirtualDisplayBridge, Constraints of the selected approach, `DSVirtualDisplay`, Errors (`DSVirtualDisplayErrorDomain`), Feasibility assessment, Options for creating a display macOS treats as a real monitor, Result, Runtime lookup (+2 more)

### Community 42 - "Android receiver app"
Cohesion: 0.29
Nodes (4): Android receiver app, `decoder/NalParser.kt`, `decoder/VideoDecoder.kt`, `discovery/MacDiscovery.kt`

### Community 43 - ".generate"
Cohesion: 0.22
Nodes (6): Framing, Input token, JSON payloads, Message types, Wire protocol, InputToken

### Community 51 - "DSVirtualDisplay"
Cohesion: 0.47
Nodes (6): DSVirtualDisplay, +apiAvailabilityReport, -invalidate, +isAPIAvailable, -isInvalidated, +missingRequirements

### Community 52 - "StatusGrid"
Cohesion: 0.53
Nodes (3): StatusGrid, .body, .connection

### Community 74 - "Check"
Cohesion: 0.53
Nodes (4): Check, Report, .passed, VirtualDisplaySelfTest

## Knowledge Gaps
- **94 isolated node(s):** `Combine`, `.isStreaming`, `.inputToken`, `.isHiDPI`, `.description` (+89 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 339 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **43 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Added` connect `Added` to `DroidScreen`, `HostViewModel`, `CGVirtualDisplayDescriptor`, `VirtualDisplayError`, `DisplayModeInfo`, `VirtualDisplayManager`, `VideoEncoder`, `StreamSession`, `ClientConnection`, `InputInjector`, `.waitForScreen`, `ProtocolTest.kt`, `InFlightTracker`, `VideoDecoder`, `DisplayCapturer`, `Sendable`, `InputMessage`, `MessageType`, `CGVirtualDisplayMode`, `StreamViewModel`, `MessageParser`, `CGVirtualDisplay`, `.generate`, `.codecSpecificData`, `Check`?**
  _High betweenness centrality (0.438) - this node is a cross-community bridge._
- **Are the 7 inferred relationships involving `StreamSession` (e.g. with `Added` and `droidscreen-vd CLI`) actually correct?**
  _`StreamSession` has 7 INFERRED edges - model-reasoned connections that need verification._
- **What connects `Combine`, `.isStreaming`, `.inputToken` to the rest of the system?**
  _94 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `DroidScreen` be split into smaller, more focused modules?**
  _Cohesion score 0.1 - nodes in this community are weakly interconnected._
- **Why does `StreamViewModel` connect `StreamViewModel` to `StreamScreen`, `MacDiscovery.kt`, `Android receiver app`, `Screens.kt`, `StreamController`, `Added`, `StreamViewModel.kt`, `MainActivity.kt`?**
  _High betweenness centrality (0.162) - this node is a cross-community bridge._
- **Are the 3 inferred relationships involving `HostViewModel` (e.g. with `Automatic start and headless streaming` and ``HostViewModel``) actually correct?**
  _`HostViewModel` has 3 INFERRED edges - model-reasoned connections that need verification._
- **Should `HostViewModel` be split into smaller, more focused modules?**
  _Cohesion score 0.05690834473324213 - nodes in this community are weakly interconnected._