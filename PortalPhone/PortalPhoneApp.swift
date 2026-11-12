import SwiftUI

@main
struct PortalPhoneApp: App {
    @StateObject private var library = PhotoLibrary()
    @StateObject private var client = PortalClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(client)
                .onAppear {
                    client.onFile = { [weak client] name, data in
                        Task { @MainActor in
                            do {
                                let dest = try await IncomingSaver.save(name: name, data: data)
                                Haptics.result(true)
                                client?.toast = dest == .photos ? "Saved \(name) to Photos" : "Saved \(name) to Files"
                            } catch {
                                Haptics.result(false)
                                client?.toast = "Couldn't save \(name)"
                            }
                        }
                    }
                    client.resume()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { client.resume() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var library: PhotoLibrary
    @EnvironmentObject private var client: PortalClient
    @State private var showPicker = false
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Group {
                if library.hasAccess {
                    PhotoGridView()
                } else if library.status == .notDetermined {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("Photos Access Needed", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Allow access in Settings to send photos to your Mac.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Portal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { ConnectionBadge(state: client.state) }
                }
            }
            .sheet(isPresented: $showPicker) { MacPickerView() }
            .alert("Enter Pairing Code", isPresented: needsCode) {
                TextField("6-digit code", text: $code).keyboardType(.numberPad)
                Button("Pair") { client.submitCode(code); code = "" }
                Button("Cancel", role: .cancel) { client.forgetMac() }
            } message: {
                if case .needsCode(let mac) = client.state {
                    Text("Find it in the Portal menu-bar icon on “\(mac)”.")
                }
            }
        }
        .overlay(alignment: .top) { Toast(text: client.toast) }
        .task(id: client.toast) {
            guard client.toast != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            client.toast = nil
        }
        .task { await library.requestAccess() }
    }

    private var needsCode: Binding<Bool> {
        Binding(
            get: { if case .needsCode = client.state { return !showPicker } else { return false } },
            set: { _ in }
        )
    }
}

private struct ConnectionBadge: View {
    let state: PortalClient.State

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.subheadline).lineLimit(1)
        }
    }

    private var label: String {
        switch state {
        case .searching: return "Pair Mac"
        case .connecting(let n): return "Connecting \(n)…"
        case .connected(let n): return n
        case .needsCode: return "Pairing…"
        case .failed: return "Offline"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting, .needsCode: return .orange
        case .searching, .failed: return .secondary
        }
    }
}

private struct MacPickerView: View {
    @EnvironmentObject private var client: PortalClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if client.macs.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking for Macs running Portal…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(client.macs) { mac in
                        Button {
                            client.pair(with: mac)
                            dismiss()
                        } label: {
                            HStack {
                                Label(mac.name, systemImage: "laptopcomputer")
                                Spacer()
                                if client.pairedMacName == mac.name {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Both devices must be on the same Wi-Fi network.")
                }

                if client.pairedMacName != nil {
                    Button("Forget Paired Mac", role: .destructive) { client.forgetMac() }
                }
            }
            .navigationTitle("Macs Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct Toast: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring, value: text)
        }
    }
}
