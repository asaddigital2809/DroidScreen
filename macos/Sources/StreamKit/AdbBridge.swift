import Foundation

/// Minimal adb integration for USB streaming: finds adb and runs `adb reverse`, so the Android
/// app can reach the host's loopback listener at 127.0.0.1:<port> over the USB cable.
/// Requires USB debugging to be enabled and authorised on the phone. Milestone 3 adds
/// device detection, AOA and automatic re-setup on reconnect.
public enum AdbBridge {
    public struct Result: Sendable {
        public let serial: String
        public let succeeded: Bool
        public let output: String
    }

    /// Search order: $ANDROID_HOME, $ANDROID_SDK_ROOT, ~/Library/Android/sdk, Homebrew, PATH.
    public static func locateADB() -> URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = env[key] { candidates.append("\(root)/platform-tools/adb") }
        }
        candidates.append(NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        candidates += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        for dir in (env["PATH"] ?? "").split(separator: ":") { candidates.append("\(dir)/adb") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Serials of devices in the "device" (authorised) state. A phone connected over USB and
    /// wireless debugging at the same time is listed once (USB preferred).
    public static func devices(adb: URL) -> [String] {
        let (ok, output) = run(adb, ["devices"])
        guard ok else { return [] }
        let serials = output.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            return parts.count >= 2 && parts[1] == "device" ? String(parts[0]) : nil
        }
        return uniqueDevices(serials)
    }

    /// Android emulators ("emulator-5554"). Automatic USB setup skips them.
    public static func isEmulator(_ serial: String) -> Bool {
        serial.hasPrefix("emulator-")
    }

    /// Drops wireless entries ("adb-<serial>-<id>._adb-tls-connect._tcp") whose serial is also attached by USB.
    static func uniqueDevices(_ serials: [String]) -> [String] {
        let usb = Set(serials.filter { !$0.hasPrefix("adb-") && !$0.contains(":") })
        return serials.filter { serial in
            guard serial.hasPrefix("adb-"), serial.contains("._adb-tls-connect") else { return true }
            let base = serial.dropFirst(4).split(separator: "-").first.map(String.init) ?? ""
            return !usb.contains(base)
        }
    }

    /// Runs `adb -s <serial> reverse tcp:<port> tcp:<port>` for every authorised device.
    public static func reverseAll(port: UInt16) -> [Result] {
        guard let adb = locateADB() else { return [] }
        return devices(adb: adb).map { serial in
            let (ok, output) = run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
            return Result(serial: serial, succeeded: ok, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Full USB setup for every authorised device: `adb reverse`, then start the receiver app
    /// pointed at 127.0.0.1 with the session's input token. The token travels over adb, which
    /// only talks to devices the user has authorised (RSA key prompt on the phone).
    public static func setUpReceivers(port: UInt16, inputToken: String?, takeOver: Bool = false) -> [Result] {
        guard let adb = locateADB() else { return [] }
        return devices(adb: adb).map { serial in
            setUpReceiver(adb: adb, serial: serial, port: port, inputToken: inputToken, takeOver: takeOver)
        }
    }

    /// Serials of authorised devices, or an empty list when adb is not installed.
    public static func devices() -> [String] {
        locateADB().map { devices(adb: $0) } ?? []
    }

    /// `adb reverse` + start the receiver app on one device. Used by the host's automatic
    /// USB setup, which runs this once for every newly attached device.
    /// `takeOver`: the receiver asks the host to switch to it even if another device is streaming
    /// (used for the user's "Set up USB" click, not for automatic setup).
    public static func setUpReceiver(adb: URL? = nil, serial: String, port: UInt16, inputToken: String?, takeOver: Bool = false) -> Result {
        guard let adb = adb ?? locateADB() else { return Result(serial: serial, succeeded: false, output: "adb not found") }
        let (reverseOK, reverseOutput) = run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
        guard reverseOK else {
            return Result(serial: serial, succeeded: false, output: reverseOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var args = ["-s", serial, "shell", "am", "start", "-n", "com.droidscreen.receiver/.MainActivity",
                    "--es", "host", "127.0.0.1", "--ei", "port", "\(port)", "--ez", "autoConnect", "true"]
        if let inputToken { args += ["--es", "inputToken", inputToken] }
        if takeOver { args += ["--ez", "takeOver", "true"] }
        let (startOK, startOutput) = run(adb, args)
        let ok = startOK && !startOutput.contains("Error")
        return Result(serial: serial, succeeded: ok,
                      output: ok ? "reverse tcp:\(port) ok; receiver started" : startOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func run(_ executable: URL, _ arguments: [String]) -> (Bool, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}
