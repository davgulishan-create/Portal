import Photos
import SwiftUI
import UIKit

/// The photo currently lifted by a long-press drag.
struct DragState: Equatable {
    enum Phase { case dragging, sending }
    let asset: PHAsset
    let image: UIImage?
    var location: CGPoint?
    var armed = false
    var phase: Phase = .dragging
}

struct PhotoGridView: View {
    /// Width of the left-edge send zone, in points.
    static let edgeWidth: CGFloat = 40

    @EnvironmentObject private var library: PhotoLibrary
    @EnvironmentObject private var client: PortalClient
    @State private var drag: DragState?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(library.assets, id: \.localIdentifier) { asset in
                    PhotoCell(
                        asset: asset,
                        manager: library.imageManager,
                        isLifted: drag?.asset == asset,
                        onBegin: begin,
                        onMove: move,
                        onEnd: end,
                        onCancel: cancel
                    )
                }
            }
        }
        .scrollDisabled(drag != nil)
        .overlay {
            DragLayer(drag: drag, edgeWidth: Self.edgeWidth)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: Gesture callbacks

    private func begin(_ asset: PHAsset, _ image: UIImage?) {
        guard drag == nil else { return }
        Haptics.lift()
        drag = DragState(asset: asset, image: image)
    }

    private func move(_ location: CGPoint) {
        guard var d = drag, d.phase == .dragging else { return }
        d.location = location
        let armed = location.x <= Self.edgeWidth
        if armed != d.armed { Haptics.edgeCrossed() }
        d.armed = armed
        drag = d
    }

    private func end(_ location: CGPoint?) {
        guard var d = drag, d.phase == .dragging else { return }
        let finalX = location?.x ?? d.location?.x ?? .infinity
        guard finalX <= Self.edgeWidth else {
            drag = nil // dropped elsewhere: just put it back
            return
        }
        guard client.isConnected else {
            Haptics.result(false)
            client.toast = "Not connected to a Mac"
            drag = nil
            return
        }

        // Haptic on send + fly the thumbnail off the left edge.
        Haptics.send()
        d.phase = .sending
        drag = d
        withAnimation(.easeIn(duration: 0.28)) {
            drag?.location?.x = -140
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            if drag?.asset == d.asset { drag = nil }
        }

        let asset = d.asset
        Task {
            do {
                let (name, data) = try await library.exportOriginal(asset)
                client.send(name: name, data: data) { ok in
                    Haptics.result(ok)
                    client.toast = ok ? "Sent \(name)" : "Couldn't send \(name)"
                }
            } catch {
                Haptics.result(false)
                client.toast = error.localizedDescription
            }
        }
    }

    /// The system cancelled the gesture (incoming call, etc.).
    private func cancel() {
        if drag?.phase == .dragging { drag = nil }
    }
}

// MARK: - Haptics

@MainActor
enum Haptics {
    static func lift() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func edgeCrossed() { UISelectionFeedbackGenerator().selectionChanged() }
    static func send() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1) }
    static func result(_ ok: Bool) { UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error) }
}

// MARK: - Cell

private struct PhotoCell: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    let isLifted: Bool
    let onBegin: (PHAsset, UIImage?) -> Void
    let onMove: (CGPoint) -> Void
    let onEnd: (CGPoint?) -> Void
    let onCancel: () -> Void

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .opacity(isLifted ? 0.25 : 1)
            .animation(.easeOut(duration: 0.18), value: isLifted)
            // UIKit long-press instead of a SwiftUI gesture: it fails as soon as the finger
            // moves before 0.3 s, so the ScrollView keeps scrolling normally.
            .overlay {
                LongPressDragRecognizer(
                    onBegan: { location in
                        onBegin(asset, image)
                        onMove(location)
                    },
                    onChanged: onMove,
                    onEnded: onEnd,
                    onCancelled: onCancel
                )
            }
            .onAppear(perform: loadThumbnail)
            .onDisappear {
                if let requestID { manager.cancelImageRequest(requestID) }
            }
    }

    private func loadThumbnail() {
        guard image == nil else { return }
        let side = 200 * displayScale
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = manager.requestImage(for: asset,
                                         targetSize: CGSize(width: side, height: side),
                                         contentMode: .aspectFill,
                                         options: options) { result, _ in
            if let result { image = result }
        }
    }
}

// MARK: - UIKit long-press → drag

/// Transparent view with a UILongPressGestureRecognizer. After the press is recognised it keeps
/// reporting the finger position (window coordinates = screen, so x ≤ 40 is the left edge).
private struct LongPressDragRecognizer: UIViewRepresentable {
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint?) -> Void
    var onCancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handle(_:)))
        press.minimumPressDuration = 0.3
        press.allowableMovement = 10
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: LongPressDragRecognizer
        init(parent: LongPressDragRecognizer) { self.parent = parent }

        @objc func handle(_ gesture: UILongPressGestureRecognizer) {
            let location = gesture.location(in: nil)
            switch gesture.state {
            case .began: parent.onBegan(location)
            case .changed: parent.onChanged(location)
            case .ended: parent.onEnded(location)
            case .cancelled, .failed: parent.onCancelled()
            default: break
            }
        }
    }
}

// MARK: - Drag overlay

private struct DragLayer: View {
    let drag: DragState?
    let edgeWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .leading) {
                EdgeGlow(active: drag != nil, armed: drag?.armed == true, width: edgeWidth)

                if let drag, let loc = drag.location {
                    Group {
                        if let image = drag.image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Color.gray
                        }
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                    .scaleEffect(drag.armed ? 0.78 : 1.08)
                    .rotationEffect(.degrees(drag.armed ? -10 : 0))
                    .position(x: loc.x - origin.x, y: loc.y - origin.y)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: drag?.armed)
        .animation(.easeOut(duration: 0.2), value: drag == nil)
    }
}

/// Animated rainbow glow on the left edge; brightens when the finger is in the send zone.
private struct EdgeGlow: View {
    let active: Bool
    let armed: Bool
    let width: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !active)) { timeline in
            let phase = (timeline.date.timeIntervalSinceReferenceDate / 3).truncatingRemainder(dividingBy: 1)
            let colors = (0...8).map {
                Color(hue: (Double($0) / 8 + phase).truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 1)
            }
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                .frame(width: armed ? width * 1.6 : 10)
                .blur(radius: armed ? 22 : 8)
                .offset(x: armed ? -width * 0.3 : -4)
                .opacity(active ? (armed ? 1 : 0.55) : 0)
                .frame(maxHeight: .infinity)
        }
    }
}
