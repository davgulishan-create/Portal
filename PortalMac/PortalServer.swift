import AppKit
import Network

/// Advertises `_portal._tcp` over Bonjour and keeps a single paired iPhone connection.
@MainActor
final class PortalServer: ObservableObject {
    static let shared = PortalServer()

    @Published private(set) var status = "Starting…"
    @Published private(set) var peerName: String?
    @Published private(set) var pairingCode: String

    /// (filename, data) for every file the iPhone sends.
    var onFile: ((String, Data) -> Void)?

    private var listener: NWListener?
    private var peer: PortalConnection?
    /// Connections that have not sent a valid hello yet.
    private var pending: [ObjectIdentifier: PortalConnection] = [:]

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Prefs.pairingCode), saved.count == 6 {
            pairingCode = saved
        } else {
            pairingCode = Self.makeCode()
            UserDefaults.standard.set(pairingCode, forKey: Prefs.pairingCode)
        }
    }

    var isConnected: Bool { peerName != nil }

    func start() {
        listener?.cancel()
        do {
            let listener = try NWListener(using: PortalConnection.makeParameters())
            // name: nil → Bonjour uses this Mac's computer name (System Settings ▸ General ▸ Sharing).
            listener.service = NWListener.Service(name: nil, type: Portal.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerStateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            status = "Listener error: \(error.localizedDescription)"
            retryLater()
        }
    }

    func regenerateCode() {
        pairingCode = Self.makeCode()
        UserDefaults.standard.set(pairingCode, forKey: Prefs.pairingCode)
        peer?.cancel() // force the iPhone to re-pair
    }

    /// Sends a file to the connected iPhone. Returns false if nobody is connected or the file can't be read.
    @discardableResult
    func send(fileURL: URL, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard let peer else { completion?(false); return false }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              UInt64(data.count) <= Portal.maxPayload else {
            completion?(false); return false
        }
        peer.send(.file(name: fileURL.lastPathComponent, data: data)) { error in
            completion?(error == nil)
        }
        return true
    }

    // MARK: - Private

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if peerName == nil { status = "Waiting for iPhone…" }
        case .failed(let error):
            status = "Network error: \(error.localizedDescription)"
            listener?.cancel()
            retryLater()
        case .waiting(let error):
            status = "Waiting for network: \(error.localizedDescription)"
        default:
            break
        }
    }

    private func retryLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func accept(_ nw: NWConnection) {
        let conn = PortalConnection(connection: nw)
        let id = ObjectIdentifier(conn)
        pending[id] = conn

        conn.onMessage = { [weak self, weak conn] message in
            guard let self, let conn else { return }
            self.handle(message, from: conn)
        }
        conn.onClose = { [weak self, weak conn] _ in
            guard let self else { return }
            self.pending[id] = nil
            if let conn, conn === self.peer {
                self.peer = nil
                self.peerName = nil
                self.status = "Waiting for iPhone…"
            }
        }
        conn.start()

        // Drop connections that never authenticate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak conn] in
            MainActor.assumeIsolated {
                guard let self, let conn, self.pending[ObjectIdentifier(conn)] != nil else { return }
                conn.cancel()
            }
        }
    }

    private func handle(_ message: PortalMessage, from conn: PortalConnection) {
        let isPeer = conn === peer
        switch message {
        case let .hello(name, code):
            guard code == pairingCode else {
                conn.send(.reject(reason: "Wrong pairing code")) { _ in conn.cancel() }
                return
            }
            pending[ObjectIdentifier(conn)] = nil
            if let old = peer, old !== conn { old.cancel() }
            peer = conn
            peerName = name
            status = "Connected to \(name)"
            conn.send(.hello(name: Host.current().localizedName ?? "Mac", code: ""))

        case let .file(name, data):
            guard isPeer else { conn.cancel(); return } // must say hello first
            onFile?(name, data)
            conn.send(.ack(name: name))

        case .ack, .reject:
            break
        }
    }

    private static func makeCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
