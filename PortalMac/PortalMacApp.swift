import AppKit
import SwiftUI

@main
struct PortalMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: "rainbow")
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        let server = PortalServer.shared
        server.onFile = { name, data in
            EdgeController.shared.receive(name: name, data: data)
        }
        server.start()
        EdgeController.shared.start()
    }
}

struct MenuContent: View {
    @ObservedObject private var server = PortalServer.shared

    var body: some View {
        Text(server.status)
        Text("Pairing code: \(server.pairingCode)")

        Divider()

        Button("Send File to iPhone…") { pickAndSend() }
            .disabled(!server.isConnected)
        Button("Preview Effect") { EdgeController.shared.preview() }

        Divider()

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Portal") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func pickAndSend() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        guard panel.runModal() == .OK else { return }
        EdgeController.shared.send(panel.urls)
    }
}
