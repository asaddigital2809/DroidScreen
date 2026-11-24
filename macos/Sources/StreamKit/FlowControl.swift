import Foundation
import VirtualDisplayKit

/// Tracks frames sent but not yet reported rendered by the client.
///
/// This is application-level flow control: TCP "send complete" only means the kernel took the
/// bytes, so it cannot detect a growing queue in the network, adb, or the phone's decoder.
/// The client echoes the PTS of every rendered frame; acknowledgements are cumulative
/// (no B-frames, so frames render in order).
public struct InFlightTracker: Sendable {
    public struct Entry: Sendable, Equatable {
        public let pts: UInt64
        public let sentAt: Double
    }

    /// Skip encoding while this many frames are unacknowledged.
    public var maxFrames: Int
    /// Skip encoding while the oldest unacknowledged frame is older than this (seconds).
    public var maxAge: Double
    /// Forget unacknowledged frames older than this (lost / decoder reset) and force a keyframe.
    public var staleTimeout: Double
    public private(set) var entries: [Entry] = []

    public init(maxFrames: Int = 4, maxAge: Double = 0.15, staleTimeout: Double = 1.0) {
        self.maxFrames = maxFrames
        self.maxAge = maxAge
        self.staleTimeout = staleTimeout
    }

    public var count: Int { entries.count }

    public mutating func sent(pts: UInt64, at time: Double) {
        entries.append(Entry(pts: pts, sentAt: time))
    }

    /// Removes every entry with pts ≤ `pts`. Returns the number removed.
    @discardableResult
    public mutating func acknowledge(pts: UInt64) -> Int {
        let before = entries.count
        entries.removeAll { $0.pts <= pts }
        return before - entries.count
    }

    public func shouldThrottle(now: Double) -> Bool {
        guard let oldest = entries.first else { return false }
        return entries.count >= maxFrames || now - oldest.sentAt > maxAge
    }

    /// Returns true (and clears) when the oldest entry exceeded `staleTimeout`.
    public mutating func expireStale(now: Double) -> Bool {
        guard let oldest = entries.first, now - oldest.sentAt > staleTimeout else { return false }
        entries.removeAll()
        return true
    }

    public mutating func reset() {
        entries.removeAll()
    }
}

/// AIMD bitrate control driven by flow-control skips, evaluated once per second.
/// Congestion (any skipped frame) → ×0.75 (at most once per second).
/// 5 s without congestion → ×1.15 every 2 s, up to `maxBitrate`.
public struct BitrateController: Sendable {
    public let minBitrate: Int
    public let maxBitrate: Int
    public private(set) var current: Int
    private var congestionEvents = 0
    private var lastDecrease = -Double.infinity
    private var lastIncrease = -Double.infinity

    public init(minBitrate: Int, maxBitrate: Int) {
        self.minBitrate = min(minBitrate, maxBitrate)
        self.maxBitrate = maxBitrate
        self.current = maxBitrate
    }

    public mutating func recordCongestion() {
        congestionEvents += 1
    }

    /// Returns the new bitrate when it changed.
    public mutating func tick(now: Double) -> Int? {
        defer { congestionEvents = 0 }
        if congestionEvents > 0 {
            guard now - lastDecrease >= 1 else { return nil }
            let next = max(minBitrate, Int(Double(current) * 0.75))
            lastDecrease = now
            guard next != current else { return nil }
            current = next
            return next
        }
        guard current < maxBitrate, now - lastDecrease >= 5, now - lastIncrease >= 2 else { return nil }
        current = min(maxBitrate, Int(Double(current) * 1.15))
        lastIncrease = now
        return current
    }

    public mutating func reset() {
        current = maxBitrate
        congestionEvents = 0
        lastDecrease = -.infinity
        lastIncrease = -.infinity
    }
}

/// Rolling latency samples (milliseconds) with median and 95th percentile.
public struct LatencyEstimator: Sendable {
    public let capacity: Int
    private var samples: [Double] = []

    public init(capacity: Int = 120) {
        self.capacity = capacity
    }

    public mutating func add(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        samples.append(milliseconds)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public var median: Double? { percentile(0.5) }
    public var p95: Double? { percentile(0.95) }

    public func percentile(_ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }

    public mutating func reset() {
        samples.removeAll()
    }
}

/// Chooses the encoded stream size.
public enum StreamGeometry {
    /// Starts from the display's pixel size and shrinks it (keeping aspect ratio) to fit the
    /// client's screen (in the display's orientation), an optional cap, and the client's
    /// decoder limit (given landscape; applied in the display's orientation). Never upscales.
    /// Result dimensions are even (required by H.264/HEVC 4:2:0).
    public static func streamSize(display: PixelSize, client: PixelSize?, cap: PixelSize?, decoder: PixelSize? = nil) -> PixelSize {
        var scale = 1.0
        func limit(_ bound: PixelSize) {
            scale = min(scale, Double(bound.width) / Double(display.width), Double(bound.height) / Double(display.height))
        }
        if let client {
            let long = max(client.width, client.height), short = min(client.width, client.height)
            limit(display.width >= display.height ? PixelSize(width: long, height: short) : PixelSize(width: short, height: long))
        }
        if let cap { limit(cap) }
        if let decoder {
            let long = max(decoder.width, decoder.height), short = min(decoder.width, decoder.height)
            limit(display.width >= display.height ? PixelSize(width: long, height: short) : PixelSize(width: short, height: long))
        }
        func even(_ value: Double) -> Int { max(2, Int(value.rounded(.down)) & ~1) }
        return PixelSize(width: even(Double(display.width) * scale), height: even(Double(display.height) * scale))
    }
}
