import InputKit
import StreamKit
import SwiftUI
import VirtualDisplayKit

/// Host window: virtual display (Milestone 1) and streaming (Milestone 2).
/// Deliberately plain — the production dashboard is Milestone 5.
struct ContentView: View {
    @ObservedObject var model: HostViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.apiAvailable {
                Label("Virtual displays are not supported on this macOS version.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(model.apiReport).font(.caption.monospaced())
            }

            GroupBox("Virtual display") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Preset", selection: $model.presetIndex) {
                        ForEach(VirtualDisplayConfiguration.presets.indices, id: \.self) {
                            Text(VirtualDisplayConfiguration.presets[$0].name).tag($0)
                        }
                    }
                    .disabled(model.active != nil)
                    Toggle("HiDPI (Retina) modes", isOn: $model.configuration.hiDPI)
                        .disabled(model.active != nil)
                    HStack {
                        Button("Create virtual display", action: model.create)
                            .disabled(model.active != nil || model.busy || !model.apiAvailable)
                        Button("Remove virtual display", action: model.remove)
                            .disabled(model.active == nil || model.busy)
                        Spacer()
                        Button("Displays settings…", action: model.openDisplaySettings)
                        Button("Test window", action: model.showTestWindow).disabled(model.active == nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Streaming") {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.screenRecordingGranted {
                        HStack {
                            Label("Screen Recording permission needed to stream the virtual display.", systemImage: "lock.fill")
                                .foregroundStyle(.orange)
                            Button("Grant…", action: model.requestScreenRecording)
                        }
                    }
                    HStack(spacing: 16) {
                        Picker("Codec", selection: $model.codec) {
                            Text("H.264").tag(VideoCodec.h264)
                            Text("HEVC").tag(VideoCodec.hevc)
                        }
                        .fixedSize()
                        Picker("FPS", selection: $model.fps) {
                            ForEach([15, 30, 60], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .fixedSize()
                        Picker("Max bitrate", selection: $model.maxBitrateMbps) {
                            ForEach([5, 10, 20, 40], id: \.self) { Text("\($0) Mbps").tag($0) }
                        }
                        .fixedSize()
                    }
                    .disabled(model.isStreaming)
                    Toggle("Allow Wi-Fi/LAN connections, advertised over Bonjour (unencrypted until Milestone 3)", isOn: $model.allowLAN)
                        .disabled(model.isStreaming)
                    HStack {
                        Toggle("Touch input", isOn: $model.touchInputEnabled)
                        if model.touchInputEnabled && !model.accessibilityGranted {
                            Label("Needs Accessibility permission", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                            Button("Grant…", action: model.requestAccessibility)
                        }
                    }
                    if model.touchInputEnabled, let token = model.inputToken {
                        HStack {
                            Text("Input code for manual (Wi-Fi) connections: \(token)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("New code", action: model.regenerateInputToken).controlSize(.small)
                        }
                    }
                    HStack {
                        Button(model.isStreaming ? "Stop streaming" : "Start streaming") {
                            model.isStreaming ? model.stopStreamingClicked() : model.startStreaming()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.busy || !model.apiAvailable)
                        Button("Set up USB (adb)", action: model.setUpUSB)
                            .disabled(!model.isStreaming)
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Automation") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Start DroidScreen at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                        if model.launchAtLoginNeedsApproval {
                            Label("Needs approval", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            Button("Open Login Items…", action: model.openLoginItemsSettings)
                        }
                    }
                    Toggle("Stream to Android automatically when no physical display is connected", isOn: $model.autoStreamWhenNoDisplay)
                    Text("Uses USB (adb) and Wi-Fi/LAN. Phones on the same network find this Mac automatically when “Connect automatically” is on in the Android app.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.autoStreamActive {
                        Label("Automatic streaming is active", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Status") {
                StatusGrid(active: model.active, snapshot: model.snapshot, stats: model.streamStats)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }

            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

            DisclosureGroup("Diagnostics") {
                VStack(alignment: .leading) {
                    Button("Run virtual display self-test", action: model.runSelfTest)
                        .disabled(model.active != nil || model.busy || !model.apiAvailable)
                    ScrollView {
                        Text((model.selfTestLines + model.streamEvents).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 600)
    }
}

private struct StatusGrid: View {
    let active: VirtualDisplayManager.ActiveDisplay?
    let snapshot: DisplaySnapshot?
    let stats: StreamStats

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            row("Virtual display", active.map { "Display \($0.displayID)" } ?? "Not created")
            if let snapshot {
                row("Arrangement", snapshot.isExtendedDesktop ? "Extended desktop" : (snapshot.isInMirrorSet ? "Mirrored" : "Inactive"))
                row("Mode", snapshot.currentMode?.description ?? "—")
            }
            row("Connection", connection)
            if stats.state == .streaming {
                row("Stream", stats.video.map { "\($0.codec.rawValue.uppercased()) \($0.width)×\($0.height) @ \($0.fps) fps" } ?? "—")
                row("Encoder", "\(stats.hardwareEncoder ? "Hardware" : "Software")\(stats.lowLatencyRateControl ? ", low-latency rate control" : "")")
                row("FPS", String(format: "captured %.0f · sent %.0f · shown %.0f · skipped %.0f", stats.captureFPS, stats.sentFPS, stats.renderedFPS, stats.skippedFPS))
                row("Bitrate", String(format: "%.1f Mbps (target %.1f)", stats.sentKbps / 1000, Double(stats.targetKbps) / 1000))
                row("Round trip", stats.rttMs.map { String(format: "%.0f ms", $0) } ?? "—")
                row("Est. latency", stats.latencyMs.map { String(format: "%.0f ms (p95 %.0f ms)", $0, stats.latencyP95Ms ?? $0) } ?? "—")
                row("Touch input", stats.inputAuthorized
                    ? (stats.accessibilityTrusted ? String(format: "Active (%.0f events/s)", stats.inputEventsPerSecond) : "Authorised, waiting for Accessibility permission")
                    : "View-only (no valid input token)")
            }
        }
    }

    private var connection: String {
        switch stats.state {
        case .stopped: return "Not streaming"
        case .listening: return "Waiting for Android on port \(stats.port)"
        case .streaming: return "\(stats.clientName ?? "Android") (\(stats.clientAddress ?? "?"))"
        case .failed(let message): return "Error: \(message)"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
