import AppKit
import SwiftUI

/// A Dynamic Island–style pill around the MacBook notch.
///  • Music playing → small artwork on the left of the notch, animated bars on the right.
///  • Hover → expands with title, artist, progress and controls; click the cover for full screen.
///  • File sent/received with the iPhone → a short notification drops out of the notch.
/// On displays without a notch it appears as a pill at the top centre of the screen.
@MainActor
final class IslandController {
    static let shared = IslandController()

    let model = IslandModel()
    private var panel: EdgePanel!
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var screen: NSScreen?
    private var running = false
    private var collapseWork: DispatchWorkItem?
    private var eventWork: DispatchWorkItem?

    private let panelSize = NSSize(width: 600, height: 240)

    private init() {}

    func start() {
        panel = EdgePanel(contentRect: .zero)
        let host = FirstMouseHostingView(rootView: IslandView(model: model, provider: .shared))
        host.sizingOptions = []
        panel.contentView = host

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { monitors.append(local) }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyEnabled() }
        })

        layout()
        applyEnabled()
    }

    /// Hidden while the full-screen player is open.
    func setSuppressed(_ suppressed: Bool) {
        model.suppressed = suppressed
        if suppressed { setExpanded(false) }
    }

    /// Short "sent / received" notification from the notch.
    func flash(incoming: Bool, name: String, image: NSImage?) {
        guard running else { return }
        model.event = IslandEvent(incoming: incoming, name: name, image: image)
        eventWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.model.event = nil }
        }
        eventWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
    }

    // MARK: Private

    private func applyEnabled() {
        let enabled = Prefs.dynamicIsland
        guard enabled != running else { return }
        running = enabled
        if enabled {
            NowPlayingProvider.shared.start()
            panel.orderFrontRegardless()
        } else {
            NowPlayingProvider.shared.stop()
            setExpanded(false)
            panel.orderOut(nil)
        }
    }

    private func layout() {
        let target = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { return }
        screen = target
        let f = target.frame
        if target.safeAreaInsets.top > 0 {
            let left = target.auxiliaryTopLeftArea?.width ?? 0
            let right = target.auxiliaryTopRightArea?.width ?? 0
            model.notch = CGSize(width: max(120, f.width - left - right), height: target.safeAreaInsets.top)
            model.hasNotch = true
        } else {
            model.notch = CGSize(width: 150, height: max(24, NSStatusBar.system.thickness))
            model.hasNotch = false
        }
        panel.setFrame(NSRect(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height,
                              width: panelSize.width, height: panelSize.height), display: true)
    }

    private func mouseMoved() {
        guard running, !model.suppressed, let screen else { return }
        let size = model.size(for: NowPlayingProvider.shared)
        let f = screen.frame
        let rect = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
        let inside = rect.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)

        if inside {
            collapseWork?.cancel()
            if !model.expanded, NowPlayingProvider.shared.track != nil, NSEvent.pressedMouseButtons == 0 {
                setExpanded(true)
            }
        } else if model.expanded, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.collapseWork = nil
                    self?.setExpanded(false)
                }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        collapseWork?.cancel()
        collapseWork = nil
        model.expanded = expanded
        // Only catch clicks while open; otherwise the menu bar under the panel stays usable.
        panel.ignoresMouseEvents = !expanded
    }
}

struct IslandEvent: Equatable {
    let id = UUID()
    let incoming: Bool
    let name: String
    let image: NSImage?
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var notch = CGSize(width: 180, height: 32)
    @Published var hasNotch = true
    @Published var expanded = false
    @Published var suppressed = false
    @Published var event: IslandEvent?

    static let wing: CGFloat = 46

    func size(for provider: NowPlayingProvider) -> CGSize {
        if suppressed { return hasNotch ? notch : .zero }
        if event != nil { return CGSize(width: max(notch.width + 180, 380), height: notch.height + 64) }
        if expanded { return CGSize(width: max(notch.width + 200, 460), height: notch.height + 132) }
        if provider.track != nil { return CGSize(width: notch.width + Self.wing * 2, height: notch.height) }
        return hasNotch ? notch : .zero // idle: hide inside the notch
    }
}

/// Lets SwiftUI buttons react to the first click even though Portal is never the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

/// Apple-like motion: a quick spring with a hint of bounce for the shape, and content that
/// arrives a beat later with a blur-in, so the island "grows, then fills".
private let islandSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)

private struct BlurScale: ViewModifier {
    let blur: CGFloat
    let scale: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: blur).scaleEffect(scale, anchor: .top).opacity(opacity)
    }
}

private extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurScale(blur: 10, scale: 0.9, opacity: 0),
                                 identity: BlurScale(blur: 0, scale: 1, opacity: 1))
                .animation(.easeOut(duration: 0.3).delay(0.1)),
            removal: .modifier(active: BlurScale(blur: 8, scale: 0.96, opacity: 0),
                               identity: BlurScale(blur: 0, scale: 1, opacity: 1))
                .animation(.easeIn(duration: 0.12))
        )
    }
}

/// The island outline: straight top flush with the screen edge, small concave "ears" that
/// melt into the menu bar (like the hardware notch), and continuous rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = max(0, min(bottomRadius, rect.height - t, (rect.width - 2 * t) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var provider: NowPlayingProvider

    var body: some View {
        let size = model.size(for: provider)
        let open = model.expanded || model.event != nil
        let ear: CGFloat = open ? 12 : 7
        let bottom: CGFloat = open ? 28 : max(9, model.notch.height * 0.42)
        let shape = NotchShape(topRadius: ear, bottomRadius: bottom)

        shape
            .fill(.black)
            .frame(width: size.width + ear * 2, height: size.height)
            .overlay(alignment: .top) {
                content
                    .frame(width: size.width, height: size.height, alignment: .top)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(open ? 0.45 : 0), radius: open ? 24 : 0, y: open ? 12 : 0)
            .opacity(size == .zero ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(islandSpring, value: size)
            .animation(islandSpring, value: open)
            .animation(islandSpring, value: provider.track?.id)
            .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        if let event = model.event {
            EventContent(event: event, notch: model.notch)
                .id(event.id)
                .transition(.islandContent)
        } else if model.expanded, let track = provider.track {
            ExpandedContent(provider: provider, track: track, notchHeight: model.notch.height)
                .transition(.islandContent)
        } else if provider.track != nil {
            CollapsedContent(provider: provider, notch: model.notch)
                .transition(.islandContent)
        }
    }
}

private struct CollapsedContent: View {
    @ObservedObject var provider: NowPlayingProvider
    let notch: CGSize

    var body: some View {
        HStack(spacing: 0) {
            CoverView(image: provider.artwork, side: notch.height - 12, radius: 6)
                .frame(width: IslandModel.wing)
            Spacer(minLength: notch.width)
            EqualizerBars(playing: provider.isPlaying, height: notch.height * 0.42, color: provider.accent)
                .frame(width: IslandModel.wing)
        }
        .frame(height: notch.height)
    }
}

private struct ExpandedContent: View {
    @ObservedObject var provider: NowPlayingProvider
    let track: NowPlayingTrack
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button { NowPlayingController.shared.open() } label: {
                    CoverView(image: provider.artwork, side: 62, radius: 13)
                        .shadow(color: provider.accent.opacity(0.35), radius: 12)
                }
                .buttonStyle(PressableStyle())
                .help("Open full screen")

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text(track.artist.isEmpty ? track.source.displayName : track.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 8)
                EqualizerBars(playing: provider.isPlaying, height: 18, color: provider.accent)
            }

            if track.duration > 0 {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let fraction = provider.position(at: context.date) / track.duration
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.16))
                            Capsule().fill(.white.opacity(0.9))
                                .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
                                .animation(.linear(duration: 0.25), value: fraction)
                        }
                    }
                    .frame(height: 4)
                }
            }

            HStack(spacing: 34) {
                control("backward.fill", 17) { provider.previous() }
                control(provider.isPlaying ? "pause.fill" : "play.fill", 24) { provider.playPause() }
                control("forward.fill", 17) { provider.next() }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, notchHeight + 8)
    }

    private func control(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Buttons shrink slightly and dim while pressed, like system controls.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct EventContent: View {
    let event: IslandEvent
    let notch: CGSize

    var body: some View {
        HStack(spacing: 12) {
            CoverView(image: event.image, side: 40, radius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.incoming ? "Received from iPhone" : "Sent to iPhone")
                    .font(.system(size: 13, weight: .semibold))
                Text(event.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Image(systemName: event.incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: event.id)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, notch.height + 10)
    }
}

private struct CoverView: View {
    let image: NSImage?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            Color.white.opacity(0.12)
                .overlay(Image(systemName: "music.note")
                    .font(.system(size: side * 0.45))
                    .foregroundStyle(.white.opacity(0.5)))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                    .id(ObjectIdentifier(image)) // crossfade when the cover changes
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Four bars in the cover's colour. They move with smooth, layered waves while playing and
/// glide down to rest (then stop redrawing) when playback pauses.
private struct EqualizerBars: View {
    let playing: Bool
    let height: CGFloat
    var color: Color = .white

    @State private var changedAt = Date.distantPast
    @State private var ticking = true

    private static let fade: Double = 0.5
    private static let speeds: [(Double, Double)] = [(5.3, 8.9), (7.1, 4.3), (4.7, 9.7), (6.2, 5.6)]

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !ticking)) { timeline in
            let date = timeline.date
            let t = date.timeIntervalSinceReferenceDate
            let amp = amplitude(at: date)
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let speed = Self.speeds[i]
                    let wave = 0.5 + 0.3 * sin(t * speed.0 + Double(i) * 1.7) + 0.2 * sin(t * speed.1 + Double(i) * 0.6)
                    let level = 0.2 + 0.8 * amp * min(max(wave, 0), 1)
                    Capsule()
                        .frame(width: 3, height: max(3, height * level))
                }
            }
            .frame(height: height)
            .foregroundStyle(color)
        }
        .onAppear { ticking = playing }
        .onChange(of: playing) { _, isPlaying in
            changedAt = Date()
            ticking = true
            if !isPlaying {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade + 0.1) {
                    if !playing { ticking = false }
                }
            }
        }
    }

    /// 0 = resting, 1 = fully moving; eased over `fade` seconds after play/pause.
    private func amplitude(at date: Date) -> Double {
        let p = min(1, max(0, date.timeIntervalSince(changedAt) / Self.fade))
        let eased = p * p * (3 - 2 * p)
        return playing ? eased : 1 - eased
    }
}
