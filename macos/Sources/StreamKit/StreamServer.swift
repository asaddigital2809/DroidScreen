import Foundation
import Network

public enum StreamError: Error, LocalizedError, Equatable {
    case encoderUnavailable(OSStatus)
    case encodeFailed(OSStatus)
    case displayNotCapturable(UInt32)
    case screenRecordingDenied
    case invalidPort(UInt16)

    public var errorDescription: String? {
        switch self {
        case .encoderUnavailable(let s): return "No usable video encoder (OSStatus \(s))."
        case .encodeFailed(let s): return "Encoding failed (OSStatus \(s))."
        case .displayNotCapturable(let id): return "ScreenCaptureKit does not list display \(id)."
        case .screenRecordingDenied:
            return "Screen Recording permission is required. Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, then restart."
        case .invalidPort(let p): return "Invalid port \(p)."
        }
    }
}

/// TCP listener (Network.framework). Loopback-only unless `allowLAN` is true.
/// With `allowLAN` and a non-nil `bonjourName`, the listener is advertised as
/// `WireProtocol.bonjourServiceType` ("" = the computer name).
final class StreamServer {
    let port: UInt16
    let allowLAN: Bool
    let bonjourName: String?
    private let queue: DispatchQueue
    private var listener: NWListener?
    var onConnection: ((NWConnection) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    init(port: UInt16, allowLAN: Bool, queue: DispatchQueue, bonjourName: String? = nil) {
        self.port = port
        self.allowLAN = allowLAN
        self.bonjourName = bonjourName
        self.queue = queue
    }

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        return params
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else { throw StreamError.invalidPort(port) }
        let params = Self.tcpParameters()
        let listener: NWListener
        if allowLAN {
            listener = try NWListener(using: params, on: nwPort)
            if let bonjourName {
                listener.service = NWListener.Service(name: bonjourName.isEmpty ? nil : bonjourName, type: WireProtocol.bonjourServiceType)
            }
        } else {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            listener = try NWListener(using: params)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.onConnection?(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed(let error): self?.onFailure?(error)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// One client connection: framed reads and fire-and-forget writes, all on `queue`.
final class ClientConnection {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var parser = MessageParser()
    private var closed = false
    var onMessage: ((UInt8, Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    var endpointDescription: String { "\(connection.endpoint)" }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.parser.append(data)
                do {
                    while let message = try self.parser.next() {
                        self.onMessage?(message.type, message.payload)
                        if self.closed { return }
                    }
                } catch {
                    self.finish(error)
                    return
                }
            }
            if let error { self.finish(error); return }
            if isComplete { self.finish(nil); return }
            self.receive()
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    func close() {
        finish(nil)
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let handler = onClose
        onClose = nil
        onMessage = nil
        handler?(error)
    }
}
