import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.sendZoneWidth) private var sendZone: Double = 12
    @AppStorage(Prefs.effect) private var effect: EdgeEffect = .rainbow
    @AppStorage(Prefs.showOnThisMac) private var showOnThisMac = true
    @AppStorage(Prefs.nowPlayingHandleKey) private var nowPlayingHandle = true
    @AppStorage(Prefs.fetchLyricsKey) private var fetchLyrics = true
    @AppStorage(Prefs.dynamicIslandKey) private var dynamicIsland = true
    @AppStorage(Prefs.screensaverKey) private var screensaver = true
    @AppStorage(Prefs.screensaverMinutesKey) private var screensaverMinutes = 2.0
    @ObservedObject private var nowPlaying = NowPlayingProvider.shared
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

            Section {
                Toggle("Dynamic Island around the notch", isOn: $dynamicIsland)
                Toggle("Left-edge handle", isOn: $nowPlayingHandle)
                Toggle("Show as screensaver while music plays", isOn: $screensaver)
                Picker("Start after", selection: $screensaverMinutes) {
                    Text("1 minute idle").tag(1.0)
                    Text("2 minutes idle").tag(2.0)
                    Text("5 minutes idle").tag(5.0)
                    Text("10 minutes idle").tag(10.0)
                }
                .disabled(!screensaver)
                Toggle("Synced lyrics", isOn: $fetchLyrics)
                HStack {
                    Button("Open Now Playing") { NowPlayingController.shared.open() }
                    Button("Preview Screensaver") { NowPlayingController.shared.open(screensaver: true) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("What Portal sees right now:").font(.caption.bold())
                    ForEach(nowPlaying.diagnostics, id: \.self) { line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .foregroundStyle(.secondary)
            } header: {
                Text("Now Playing")
            } footer: {
                Text("Works with Music, Spotify and browser tabs (YouTube, SoundCloud, Yandex Music, VK…). For browsers, turn on “Allow JavaScript from Apple Events” in the browser's Develop menu. Lyrics are looked up on lrclib.net using the song title and artist.")
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
