import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.sendZoneWidth) private var sendZone: Double = 12
    @AppStorage(Prefs.effect) private var effect: EdgeEffect = .rainbow
    @AppStorage(Prefs.showOnThisMac) private var showOnThisMac = true
    @ObservedObject private var server = PortalServer.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Send Zone") {
                    HStack {
                        Slider(value: $sendZone, in: 2...80, step: 1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("2")
                        } maximumValueLabel: {
                            Text("80")
                        }
                        Text("\(Int(sendZone)) pt")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .onChange(of: sendZone) { EdgeController.shared.flashZone() }

                Text("Drag a file into this strip at the right edge of the screen to send it to your iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Effect", selection: $effect) {
                    ForEach(EdgeEffect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Toggle("Show on This Mac", isOn: $showOnThisMac)

                Button("Preview Effect") { EdgeController.shared.preview() }
                    .disabled(!showOnThisMac)
            } footer: {
                Text("When “Show on This Mac” is off, files are saved to Downloads silently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("iPhone") {
                LabeledContent("Status", value: server.status)
                LabeledContent("Pairing code") {
                    Text(server.pairingCode)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button("Generate New Code") { server.regenerateCode() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onAppear { NSApp.activate() } // LSUIElement apps don't come forward on their own
    }
}
