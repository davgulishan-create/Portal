import SwiftUI

/// Full-screen "now playing" mode: ambient background tinted by the album art,
/// big clock, artwork + controls on the left, time-synced lyrics on the right.
@MainActor
final class NowPlayingScene: ObservableObject {
    enum Layout { case lockScreen, player }
    @Published var layout: Layout
    let wallpaper: NSImage?

    init(layout: Layout, wallpaper: NSImage?) {
        self.layout = layout
        self.wallpaper = wallpaper
    }
}

struct NowPlayingView: View {
    @ObservedObject var provider: NowPlayingProvider
    @ObservedObject var scene: NowPlayingScene
    var onClose: () -> Void

    @State private var shown = false
    @State private var hoveringClose = false

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 1100
            ZStack {
                if scene.layout == .lockScreen {
                    LockScreenLayout(provider: provider, wallpaper: scene.wallpaper) {
                        withAnimation(.spring(response: 0.8, dampingFraction: 0.9)) { scene.layout = .player }
                    }
                    .transition(.opacity)
                } else {
                    playerLayout(geo: geo, compact: compact)
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                }
            }
            .overlay(alignment: .topLeading) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .opacity(hoveringClose ? 1 : 0.35)
                .onHover { hoveringClose = $0 }
                .padding(.top, 44)
                .padding(.leading, 24)
                .help("Close (Esc)")
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { shown = true }
        }
    }

    private func playerLayout(geo: GeometryProxy, compact: Bool) -> some View {
            ZStack {
                AmbientBackground(artwork: provider.artwork, tint: provider.tint)
                    .scaleEffect(shown ? 1 : 1.08)

                HStack(alignment: .center, spacing: geo.size.width * 0.06) {
                    PlayerColumn(provider: provider, artSide: min(geo.size.height * 0.42, compact ? 300 : 400))
                        .frame(width: min(geo.size.height * 0.42, compact ? 300 : 400))

                    VStack(alignment: .leading, spacing: 0) {
                        ClockView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 12)
                        LyricsPanel(provider: provider)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, geo.size.width * 0.08)
                .padding(.top, geo.size.height * 0.08)
                .padding(.bottom, geo.size.height * 0.06)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 24)
            }
    }
}

// MARK: - Background

private struct AmbientBackground: View {
    let artwork: NSImage?
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Color.black
                tint.opacity(0.9)

                if let artwork {
                    // Two copies of the cover, hugely blurred and slowly drifting, read as a
                    // moving colour field rather than a picture.
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.6 + 0.08 * sin(t / 7))
                        .rotationEffect(.degrees(12 * sin(t / 11)))
                        .offset(x: 60 * cos(t / 9), y: 40 * sin(t / 8))
                        .blur(radius: 110)
                        .saturation(1.6)
                        .opacity(0.95)
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(x: -1.4, y: 1.4)
                        .rotationEffect(.degrees(-15 * cos(t / 13)))
                        .offset(x: -80 * sin(t / 10), y: 60 * cos(t / 12))
                        .blur(radius: 130)
                        .saturation(1.4)
                        .opacity(0.55)
                        .blendMode(.plusLighter)
                }

                // Darken toward the edges so white text always reads.
                RadialGradient(colors: [.clear, .black.opacity(0.55)],
                               center: .center, startRadius: 200, endRadius: 1400)
                Color.black.opacity(0.18)
            }
            .drawingGroup()
        }
        .animation(.easeInOut(duration: 1.0), value: artwork)
    }
}

// MARK: - Clock

private struct ClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text(context.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 110, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.82))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
    }
}

// MARK: - Player

private struct PlayerColumn: View {
    @ObservedObject var provider: NowPlayingProvider
    let artSide: CGFloat

    var body: some View {
        VStack(spacing: 22) {
            artworkView
                .frame(width: artSide, height: artSide)
                .scaleEffect(provider.isPlaying || provider.track == nil ? 1 : 0.9)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: provider.isPlaying)

            if let track = provider.track {
                VStack(spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 22, weight: .bold))
                    Text(track.artist)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .lineLimit(1)
                .multilineTextAlignment(.center)

                ProgressRow(provider: provider, duration: track.duration)

                HStack(spacing: 40) {
                    controlButton("backward.fill", size: 22) { provider.previous() }
                    controlButton(provider.isPlaying ? "pause.fill" : "play.fill", size: 32) { provider.playPause() }
                    controlButton("forward.fill", size: 22) { provider.next() }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())
            } else if provider.automationDenied {
                VStack(spacing: 10) {
                    Text("Portal needs permission to read Music / Spotify")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Button("Open Automation Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Text("Nothing playing").font(.title2.bold())
                    Text("Play something in Music, Spotify or a browser tab")
                        .foregroundStyle(.white.opacity(0.6))
                    if let hint = provider.browserHint {
                        Text("To follow music in the browser, turn on:\n\(hint)")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.top, 8)
                    }
                    // What Portal found in each player — helps to see why nothing shows up.
                    VStack(spacing: 2) {
                        ForEach(provider.diagnostics, id: \.self) { line in
                            Text(line)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 12)
                }
                .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var artworkView: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if let art = provider.artwork {
            Image(nsImage: art)
                .resizable()
                .scaledToFill()
                .clipShape(shape)
                .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .id(provider.track?.id)
        } else {
            shape.fill(.white.opacity(0.08))
                .overlay(Image(systemName: "music.note").font(.system(size: 70)).foregroundStyle(.white.opacity(0.3)))
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}

private struct ProgressRow: View {
    @ObservedObject var provider: NowPlayingProvider
    let duration: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = provider.position(at: context.date)
            let fraction = duration > 0 ? position / duration : 0
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        provider.seek(to: Double(location.x / geo.size.width) * duration)
                    }
                }
                .frame(height: 6)
                HStack {
                    Text(format(position))
                    Spacer()
                    Text("-" + format(max(0, duration - position)))
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Lyrics

private struct LyricsPanel: View {
    @ObservedObject var provider: NowPlayingProvider

    var body: some View {
        Group {
            switch provider.lyrics {
            case .synced(let lines):
                SyncedLyrics(provider: provider, lines: lines)
            case .plain(let lines):
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 26, weight: .bold, design: .rounded))
                        }
                    }
                    .padding(.vertical, 40)
                }
                .foregroundStyle(.white.opacity(0.75))
                .mask(edgeFade())
            case .loading:
                ProgressView().controlSize(.small).tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .none:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.4), value: provider.lyrics)
    }
}

private func edgeFade() -> some View {
    LinearGradient(stops: [
        .init(color: .clear, location: 0),
        .init(color: .black, location: 0.12),
        .init(color: .black, location: 0.8),
        .init(color: .clear, location: 1),
    ], startPoint: .top, endPoint: .bottom)
}

private struct SyncedLyrics: View {
    @ObservedObject var provider: NowPlayingProvider
    let lines: [LyricLine]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            // Lead by a quarter second so the highlight lands on the beat, not after it.
            let now = provider.position(at: context.date) + 0.25
            let current = lines.lastIndex { $0.time <= now } ?? -1
            LyricsScroller(lines: lines, current: current) { provider.seek(to: $0) }
        }
    }
}

private struct LyricsScroller: View {
    let lines: [LyricLine]
    let current: Int
    let seek: (Double) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(lines) { line in
                        let distance = abs(line.id - current)
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(distance == 0 ? 1 : 0.32))
                            .blur(radius: distance == 0 ? 0 : min(Double(distance) * 0.9, 4))
                            .scaleEffect(distance == 0 ? 1 : 0.96, anchor: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { seek(line.time) }
                            .id(line.id)
                            .animation(.easeOut(duration: 0.35), value: current)
                    }
                }
                .padding(.vertical, 220)
            }
            .scrollDisabled(true)
            .mask(edgeFade())
            .onAppear { proxy.scrollTo(max(current, 0), anchor: UnitPoint(x: 0, y: 0.3)) }
            .onChange(of: current) { _, new in
                withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) {
                    proxy.scrollTo(max(new, 0), anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
        }
    }
}

// MARK: - Lock-screen look (screensaver)

/// Wallpaper, big centred clock and a small glass player widget at the bottom — the first
/// thing you see when Now Playing starts as a screensaver. Tap the widget (or touch the
/// trackpad) to morph into the full player with lyrics.
private struct LockScreenLayout: View {
    @ObservedObject var provider: NowPlayingProvider
    let wallpaper: NSImage?
    var expand: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let wallpaper {
                    Image(nsImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    AmbientBackground(artwork: provider.artwork, tint: provider.tint)
                }
                LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.45)],
                               startPoint: .top, endPoint: .bottom)

                VStack(spacing: 0) {
                    LockClock()
                        .padding(.top, geo.size.height * 0.08)
                    Spacer()
                    if provider.track != nil {
                        MiniPlayerWidget(provider: provider, onTap: expand)
                            .padding(.bottom, geo.size.height * 0.09)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: provider.track != nil)
    }
}

private struct LockClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 150, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .contentTransition(.numericText())
            }
            .shadow(color: .black.opacity(0.25), radius: 20, y: 6)
        }
    }
}

private struct MiniPlayerWidget: View {
    @ObservedObject var provider: NowPlayingProvider
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let art = provider.artwork {
                    Image(nsImage: art).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.15)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6)))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.track?.title ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(provider.track?.artist ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            HStack(spacing: 18) {
                button("backward.fill", 15) { provider.previous() }
                button(provider.isPlaying ? "pause.fill" : "play.fill", 20) { provider.playPause() }
                button("forward.fill", 15) { provider.next() }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }

    private func button(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}
