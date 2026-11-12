import Network
import UIKit

/// Browses for Macs advertising `_portal._tcp`, pairs with one, and auto-reconnects to it.
@MainActor
final class PortalClient: ObservableObject {
    struct DiscoveredMac: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    enum State: Equatable {
        case searching
        case connecting(String)
        case connected(String)
        case needsCode(String)
        case failed(String)
    }

    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var state: State = .searching
    @Published var toast: String?

    /// Called with (filename, data) for files the Mac sends us.
    var onFile: ((String, Data) -> Void)?

    private var browser: NWBrowser?
    private var connection: PortalConnection?
    private var connectionMac: DiscoveredMac?
    private var pendingSends: [String: (Bool) -> Void] = [:]

    private let defaults = UserDefaults.standard
    private(set) var pairedMacName: String? {
        get { defaults.string(forKey: "pairedMacName") }
        set { defaults.set(newValue, forKey: "pairedMacName"); objectWillChange.send() }
    }
    private func savedCode(for mac: String) -> String? { defaults.string(forKey: "pairCode.\(mac)") }
    private func saveCode(_ code: String?, for mac: String) { defaults.set(code, forKey: "pairCode.\(mac)") }

    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    // MARK: Lifecycle

    /// Call on launch and whenever the app becomes active (iOS drops sockets in the background).
    func resume() {
        if browser == nil { startBrowsing() }
        if connection == nil { autoConnect() }
    }

    func startBrowsing() {
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Portal.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .failed(let error) = state {
                    self.state = .failed("Browsing failed: \(error.localizedDescription)")
                    self.browser = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        MainActor.assumeIsolated { self.startBrowsing() }
                    }
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// User tapped a Mac in the picker.
    func pair(with mac: DiscoveredMac) {
        pairedMacName = mac.name
        connection?.cancel()
        connection = nil
        connect(to: mac)
    }

    func submitCode(_ code: String) {
        guard case .needsCode(let name) = state else { return }
        saveCode(code.trimmingCharacters(in: .whitespaces), for: name)
        if let mac = macs.first(where: { $0.name == name }) { connect(to: mac) }
    }

    func forgetMac() {
        if let name = pairedMacName { saveCode(nil, for: name) }
        pairedMacName = nil
        connection?.cancel()
        connection = nil
        state = .searching
    }

    // MARK: Sending

    func send(name: String, data: Data, completion: @escaping (Bool) -> Void) {
        guard isConnected, let connection else { completion(false); return }
        connection.send(.file(name: name, data: data)) { error in
            if error != nil { completion(false) }
        }
        // Success is reported when the Mac acks (i.e. the file is on its disk).
        pendingSends[name] = completion
    }

    // MARK: Private

    private func update(_ results: Set<NWBrowser.Result>) {
        macs = results.compactMap { result in
            if case let .service(name, _, _, _) = result.endpoint {
                return DiscoveredMac(name: name, endpoint: result.endpoint)
            }
            return nil
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        autoConnect()
    }

    private func autoConnect() {
        guard connection == nil, let paired = pairedMacName else { return }
        if case .needsCode = state { return }
        guard let mac = macs.first(where: { $0.name == paired }) else { return }
        connect(to: mac)
    }

    private func connect(to mac: DiscoveredMac) {
        guard let code = savedCode(for: mac.name), !code.isEmpty else {
            state = .needsCode(mac.name)
            return
        }
        connection?.cancel()
        state = .connecting(mac.name)

        let conn = PortalConnection(connection: NWConnection(to: mac.endpoint, using: PortalConnection.makeParameters()))
        connection = conn
        connectionMac = mac

        conn.onReady = { [weak conn] in
            conn?.send(.hello(name: UIDevice.current.name, code: code))
        }
        conn.onMessage = { [weak self] message in
            self?.handle(message, mac: mac)
        }
        conn.onClose = { [weak self, weak conn] _ in
            guard let self, let conn, conn === self.connection else { return }
            self.connection = nil
            self.pendingSends.values.forEach { $0(false) }
            self.pendingSends.removeAll()
            if case .needsCode = self.state { return }
            self.state = .searching
            // Retry shortly; the browser will also trigger autoConnect when the Mac reappears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { self.autoConnect() }
            }
        }
        conn.start()
    }

    private func handle(_ message: PortalMessage, mac: DiscoveredMac) {
        switch message {
        case .hello:
            state = .connected(mac.name)
        case .reject:
            saveCode(nil, for: mac.name)
            state = .needsCode(mac.name)
        case let .file(name, data):
            onFile?(name, data)
            connection?.send(.ack(name: name))
        case let .ack(name):
            pendingSends.removeValue(forKey: name)?(true)
        }
    }
}
