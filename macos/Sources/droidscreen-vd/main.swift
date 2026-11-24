// droidscreen-vd — command-line tool for the DroidScreen virtual display (Milestone 1).
//
//   droidscreen-vd probe                      Check that the CGVirtualDisplay API exists.
//   droidscreen-vd list                       List online displays as macOS sees them.
//   droidscreen-vd create [options]           Create a display and keep it until Ctrl-C.
//   droidscreen-vd selftest [options]         Automated acceptance test (exit code 0 = pass).
//   droidscreen-vd serve [options]            Create a display and stream it to the Android app.
//
// Options for create / selftest:
//   --preset phone|1080p|720p   Start from a preset (default: phone).
//   --size WxH                  Primary resolution in pixels.
//   --extra WxH[,WxH…]          Additional resolutions offered to macOS.
//   --hz N[,N…]                 Refresh rates (default 60,30).
//   --hidpi / --no-hidpi        Offer 2× Retina variants (default: preset value).
//   --diagonal INCHES           Physical diagonal (default: preset value).
//   --name NAME                 Name shown in System Settings.
//   --serial N                  Serial number (macOS remembers arrangement per serial).
//   --duration SECONDS          create: remove after N seconds. selftest: keep display up N seconds.
//   --window                    create/serve: also open a test window on the new display.
//
// Options for serve:
//   --port N                    TCP port (default 47800).
//   --lan                       Listen on all interfaces (default: 127.0.0.1 only). Unencrypted.
//   --adb                       Run `adb reverse` for every authorised USB device.
//   --codec h264|hevc           Preferred codec (falls back to h264 if the client lacks it).
//   --fps N                     Stream frame rate (default 60).
//   --bitrate MBPS              Maximum bitrate (default 20). --min-bitrate MBPS (default 2).
//   --stream-size WxH           Upper bound for the encoded size.
//   --no-match-client           Do not shrink the stream to the phone's screen size.
//   --stats-interval SECONDS    How often to print stats (default 1, 0 = never).
//   --no-input                  View-only: ignore touch/keyboard input.
//   --adb                       (also) start the receiver app over adb with the input token.

import AppKit
import InputKit
import StreamKit
import VirtualDisplayKit

struct CLIError: Error, CustomStringConvertible { let description: String }

struct Options {
    var command = "help"
    var configuration = VirtualDisplayConfiguration.phoneLandscape
    var duration: TimeInterval = 0
    var openWindow = false
    var stream = StreamOptions()
    var runAdbReverse = false
    var statsInterval: TimeInterval = 1

    init(_ arguments: [String]) throws {
        var args = arguments[...]
        if let first = args.first { command = first; args = args.dropFirst() }

        func value(_ flag: String) throws -> String {
            guard let v = args.popFirst() else { throw CLIError(description: "\(flag) needs a value") }
            return v
        }
        func sizes(_ text: String) throws -> [PixelSize] {
            try text.split(separator: ",").map {
                guard let s = PixelSize(parsing: String($0)) else { throw CLIError(description: "Bad size '\($0)', expected WxH") }
                return s
            }
        }

        while let flag = args.popFirst() {
            switch flag {
            case "--preset":
                switch try value(flag) {
                case "phone": configuration = .phoneLandscape
                case "1080p": configuration = .fullHD
                case "720p": configuration = .hd720
                case let other: throw CLIError(description: "Unknown preset '\(other)'")
                }
            case "--size":
                guard let s = try sizes(value(flag)).first else { throw CLIError(description: "--size needs WxH") }
                configuration.resolution = s
            case "--extra": configuration.additionalResolutions = try sizes(value(flag))
            case "--hz":
                configuration.refreshRates = try value(flag).split(separator: ",").map {
                    guard let r = Double($0) else { throw CLIError(description: "Bad refresh rate '\($0)'") }
                    return r
                }
            case "--hidpi": configuration.hiDPI = true
            case "--no-hidpi": configuration.hiDPI = false
            case "--diagonal":
                guard let d = Double(try value(flag)) else { throw CLIError(description: "Bad --diagonal") }
                configuration.diagonalInches = d
            case "--name": configuration.name = try value(flag)
            case "--serial":
                guard let s = UInt32(try value(flag)) else { throw CLIError(description: "Bad --serial") }
                configuration.serialNumber = s
            case "--duration":
                guard let d = TimeInterval(try value(flag)), d >= 0 else { throw CLIError(description: "Bad --duration") }
                duration = d
            case "--window": openWindow = true
            case "--port":
                guard let p = UInt16(try value(flag)), p > 0 else { throw CLIError(description: "Bad --port") }
                stream.port = p
            case "--lan": stream.allowLAN = true
            case "--adb": runAdbReverse = true
            case "--codec":
                guard let c = VideoCodec(rawValue: try value(flag)) else { throw CLIError(description: "--codec must be h264 or hevc") }
                stream.codec = c
            case "--fps":
                guard let f = Int(try value(flag)), (1...120).contains(f) else { throw CLIError(description: "--fps must be 1…120") }
                stream.fps = f
            case "--bitrate":
                guard let m = Double(try value(flag)), m > 0 else { throw CLIError(description: "Bad --bitrate") }
                stream.maxBitrate = Int(m * 1_000_000)
            case "--min-bitrate":
                guard let m = Double(try value(flag)), m > 0 else { throw CLIError(description: "Bad --min-bitrate") }
                stream.minBitrate = Int(m * 1_000_000)
            case "--stream-size":
                guard let s = try sizes(value(flag)).first else { throw CLIError(description: "--stream-size needs WxH") }
                stream.maxStreamSize = s
            case "--no-match-client": stream.matchClientResolution = false
            case "--no-input": stream.inputEnabled = false
            case "--stats-interval":
                guard let i = TimeInterval(try value(flag)), i >= 0 else { throw CLIError(description: "Bad --stats-interval") }
                statsInterval = i
            default: throw CLIError(description: "Unknown option '\(flag)'")
            }
        }
    }
}

func printDisplays() {
    let displays = DisplayInspector.allDisplays()
    print("\(displays.count) online display(s):")
    for d in displays {
        var tags: [String] = []
        if d.isMain { tags.append("main") }
        if d.isBuiltin { tags.append("built-in") }
        if d.isDroidScreen { tags.append("DroidScreen") }
        tags.append(d.isInMirrorSet ? "mirrored" : "extended")
        if !d.isActive { tags.append("inactive") }
        print("  [\(d.id)] \(tags.joined(separator: ", "))")
        print("      bounds: \(d.bounds)  mode: \(d.currentMode?.description ?? "none")")
        print(String(format: "      vendor 0x%04X model 0x%04X serial %u", d.vendorNumber, d.modelNumber, d.serialNumber))
    }
}

func describe(_ c: VirtualDisplayConfiguration) -> String {
    "\(c.name): \(c.resolution) (+\(c.additionalResolutions.map(\.description).joined(separator: ", "))) @ \(c.refreshRates.map { "\(Int($0))" }.joined(separator: "/"))Hz, hiDPI \(c.hiDPI ? "on" : "off"), \(c.diagonalInches)\""
}

@MainActor
func run(_ options: Options) async -> Int32 {
    switch options.command {
    case "probe":
        print(VirtualDisplayManager.apiAvailabilityReport)
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        return VirtualDisplayManager.isAPIAvailable ? 0 : 1

    case "list":
        printDisplays()
        return 0

    case "selftest":
        print("Self-test: \(describe(options.configuration))")
        let report = await VirtualDisplaySelfTest.run(configuration: options.configuration, holdSeconds: options.duration) { check in
            print("  [\(check.passed ? "PASS" : "FAIL")] \(check.name)\n         \(check.detail)")
        }
        print(report.passed ? "RESULT: PASS (\(report.checks.count) checks)" : "RESULT: FAIL")
        return report.passed ? 0 : 1

    case "create":
        let manager = VirtualDisplayManager()
        do {
            let active = try await manager.create(options.configuration)
            print("Created virtual display \(active.displayID): \(describe(options.configuration))")
            print("Current mode: \(active.appliedMode?.description ?? "unknown")")
            active.warnings.forEach { print("Warning: \($0)") }
            printDisplays()
            if options.openWindow, let screen = await ScreenSupport.waitForScreen(active.displayID) {
                ScreenSupport.showTestWindow(on: screen)
            }
            print("Open System Settings › Displays to see it. Press Ctrl-C to remove it.")
        } catch {
            print("Error: \(error.localizedDescription)")
            return 1
        }

        manager.onUnexpectedTermination = { id in
            print("macOS removed display \(id).")
            exit(2)
        }
        // Keep the strong reference alive until a signal or the duration elapses.
        await waitForSignal(duration: options.duration)
        let removed = await manager.remove()
        print(removed ? "Virtual display removed." : "Warning: display still listed after removal timeout.")
        return removed ? 0 : 1

    case "serve":
        return await serve(options)

    default:
        print("""
        usage: droidscreen-vd probe | list | create [options] | selftest [options]
          --preset phone|1080p|720p  --size WxH  --extra WxH,WxH  --hz 60,30
          --hidpi | --no-hidpi  --diagonal IN  --name NAME  --serial N
          --duration SECONDS  --window
        serve: --port N  --lan  --adb  --codec h264|hevc  --fps N  --bitrate MBPS  --min-bitrate MBPS
               --stream-size WxH  --no-match-client  --stats-interval S  --no-input
        """)
        return options.command == "help" ? 0 : 64
    }
}

/// Suspends until SIGINT/SIGTERM or until `duration` seconds pass (0 = no limit).
@MainActor
func waitForSignal(duration: TimeInterval) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        var sources: [DispatchSourceSignal] = []
        var resumed = false
        let finish = {
            guard !resumed else { return }
            resumed = true
            sources.forEach { $0.cancel() }
            continuation.resume()
        }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler(handler: finish)
            source.resume()
            sources.append(source)
        }
        if duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: finish)
        }
    }
}

/// Milestone 2: virtual display + ScreenCaptureKit + VideoToolbox + TCP server.
@MainActor
func serve(_ options: Options) async -> Int32 {
    // Explicit consent: macOS shows its Screen Recording prompt; nothing is captured without it.
    guard ScreenCapturePermission.ensure() else {
        print("Screen Recording permission is not granted to this process (or its terminal).")
        print("Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, then run again.")
        return 3
    }

    let manager = VirtualDisplayManager()
    let active: VirtualDisplayManager.ActiveDisplay
    do {
        active = try await manager.create(options.configuration)
    } catch {
        print("Error: \(error.localizedDescription)")
        return 1
    }
    print("Virtual display \(active.displayID): \(describe(options.configuration)), mode \(active.appliedMode?.description ?? "unknown")")
    if options.openWindow, let screen = await ScreenSupport.waitForScreen(active.displayID) {
        ScreenSupport.showTestWindow(on: screen)
    }

    let session = StreamSession(displayID: active.displayID, displayName: options.configuration.name, options: options.stream)
    var lastStatsPrint = Date.distantPast
    session.onEvent = { print("[event] \($0)") }
    session.onStats = { stats in
        guard options.statsInterval > 0, stats.state == .streaming,
              Date().timeIntervalSince(lastStatsPrint) >= options.statsInterval - 0.05 else { return }
        lastStatsPrint = Date()
        print("[stats] \(stats.summary)")
    }
    manager.onUnexpectedTermination = { id in
        print("macOS removed display \(id).")
        exit(2)
    }
    session.onDisplayLost = {
        print("The virtual display is no longer available; exiting. Run serve again.")
        exit(2)
    }
    do {
        try session.start()
    } catch {
        print("Error: \(error.localizedDescription)")
        await manager.remove()
        return 1
    }

    if options.stream.inputEnabled {
        if !InputPermission.isTrusted {
            InputPermission.request()
            print("[input] Accessibility permission not granted; touch input will be ignored until it is.")
        }
        print("[input] session input token: \(session.inputToken)")
    }
    if options.runAdbReverse {
        let port = options.stream.port
        let token: String? = options.stream.inputEnabled ? session.inputToken : nil
        let results = await Task.detached { AdbBridge.setUpReceivers(port: port, inputToken: token, takeOver: true) }.value
        if results.isEmpty { print("[adb] no authorised devices (or adb not found)") }
        for r in results { print("[adb] \(r.serial): \(r.succeeded ? r.output : "failed: \(r.output)")") }
    }
    print(options.stream.allowLAN
          ? "Listening on all interfaces, port \(options.stream.port) (UNENCRYPTED until Milestone 3)."
          : "Listening on 127.0.0.1:\(options.stream.port). Android: USB with --adb → 127.0.0.1, emulator → 10.0.2.2.")
    print("Press Ctrl-C to stop.")

    await waitForSignal(duration: options.duration)
    await session.stop()
    let removed = await manager.remove()
    print(removed ? "Stopped; virtual display removed." : "Stopped; warning: display still listed.")
    return 0
}

let options: Options
do {
    options = try Options(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(64)
}

// An NSApplication run loop is required so AppKit refreshes NSScreen.screens and can show windows.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    let code = await run(options)
    exit(code)
}
app.run()
