import Foundation
import Network

/// A framed, bidirectional Portal connection on top of NWConnection.
/// Runs on the main queue so every callback is already on the main actor.
@MainActor
final class PortalConnection {
    let connection: NWConnection

    var onReady: (() -> Void)?
    var onMessage: ((PortalMessage) -> Void)?
    var onClose: ((Error?) -> Void)?

    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Default parameters: TCP with keepalive, allowed over peer-to-peer Wi-Fi (AWDL) too.
    nonisolated static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.onReady?()
                    self.receiveNextMessage()
                case .failed(let error):
                    self.close(error)
                case .waiting(let error):
                    // Peer not reachable right now (e.g. Wi-Fi off). Treat as closed so callers can retry.
                    self.close(error)
                case .cancelled:
                    self.close(nil)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: PortalMessage, completion: ((Error?) -> Void)? = nil) {
        connection.send(content: PortalCodec.encode(message), completion: .contentProcessed { error in
            MainActor.assumeIsolated { completion?(error) }
        })
    }

    func cancel() {
        connection.cancel()
    }

    // MARK: - Receiving

    private func close(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(error)
    }

    private func receiveNextMessage() {
        receive(exactly: PortalCodec.headerSize) { [weak self] headerData in
            guard let self, let headerData else { return }
            let header: PortalCodec.Header
            do { header = try PortalCodec.decodeHeader(headerData) } catch {
                self.close(error)
                return
            }
            self.receive(exactly: header.nameLength) { nameData in
                guard let nameData else { return }
                let name = String(decoding: nameData, as: UTF8.self)
                self.receive(exactly: Int(header.payloadLength)) { payload in
                    guard let payload else { return }
                    self.onMessage?(PortalCodec.message(header: header, name: name, payload: payload))
                    if !self.closed { self.receiveNextMessage() }
                }
            }
        }
    }

    /// Reads exactly `count` bytes in ≤1 MiB chunks. Calls back with nil (after closing) on error/EOF.
    private func receive(exactly count: Int, completion: @escaping (Data?) -> Void) {
        guard count > 0 else { completion(Data()); return }
        let buffer = ReceiveBuffer(capacity: count)
        readChunk(into: buffer, count: count, completion: completion)
    }

    private func readChunk(into buffer: ReceiveBuffer, count: Int, completion: @escaping (Data?) -> Void) {
        let remaining = count - buffer.data.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 1 << 20)) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let content { buffer.data.append(content) }
                if buffer.data.count == count {
                    completion(buffer.data)
                } else if let error {
                    self.close(error); completion(nil)
                } else if isComplete {
                    self.close(nil); completion(nil)
                } else {
                    self.readChunk(into: buffer, count: count, completion: completion)
                }
            }
        }
    }
}

/// Reference box so the accumulating buffer can be shared across NWConnection callbacks.
private final class ReceiveBuffer: @unchecked Sendable {
    var data: Data
    init(capacity: Int) {
        data = Data()
        data.reserveCapacity(capacity)
    }
}
