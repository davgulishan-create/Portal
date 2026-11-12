import AppKit
import SwiftUI

/// State for the right-edge overlay. Plays are queued so back-to-back transfers don't overlap.
@MainActor
final class OverlayModel: ObservableObject {
    enum Direction { case incoming, outgoing }

    // Effect
    @Published var effect: EdgeEffect = Prefs.currentEffect
    @Published var playIntensity: Double = 0

    // Flying image
    @Published var flyingImage: NSImage?
    @Published var flyProgress: CGFloat = 0 // 0 = at/behind the edge, 1 = landed on screen
    @Published var imageOpacity: Double = 0

    // Reverse-direction drag feedback
    @Published var dragActive = false
    @Published var dragProximity: Double = 0 // 0 far … 1 at edge
    @Published var dropHover = false
    @Published var zoneWidth: CGFloat = Prefs.sendZone
    @Published var zoneFlash = false

    private var queue: Task<Void, Never>?

    /// What the effect layer should render at right now.
    var effectiveIntensity: Double {
        max(playIntensity, dropHover ? 1 : 0, dragActive ? dragProximity * 0.6 : 0)
    }

    var showsZone: Bool { dragActive || zoneFlash }

    /// Queue an effect. `onLanded` runs when the image has arrived (incoming) or left (outgoing);
    /// it runs immediately when "Show on This Mac" is off.
    func play(_ direction: Direction, image: NSImage?, onLanded: (() -> Void)? = nil) {
        guard Prefs.showEffects else { onLanded?(); return }
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.run(direction, image: image)
            onLanded?()
            await self?.fadeOut()
        }
    }

    func flashZone() {
        zoneFlash = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            zoneFlash = false
        }
    }

    // MARK: - Sequencing

    private func run(_ direction: Direction, image: NSImage?) async {
        effect = Prefs.currentEffect
        withAnimation(.easeOut(duration: 0.4)) { playIntensity = 1 }

        flyingImage = image
        switch direction {
        case .incoming:
            flyProgress = 0
            imageOpacity = 1
            try? await Task.sleep(for: .milliseconds(350)) // let the effect bloom first
            withAnimation(.spring(response: 0.75, dampingFraction: 0.72)) { flyProgress = 1 }
            try? await Task.sleep(for: .milliseconds(1300))
        case .outgoing:
            flyProgress = 1
            withAnimation(.easeOut(duration: 0.15)) { imageOpacity = 1 }
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.easeIn(duration: 0.55)) { flyProgress = 0 }
            try? await Task.sleep(for: .milliseconds(550))
        }
    }

    private func fadeOut() async {
        withAnimation(.easeIn(duration: 0.35)) { imageOpacity = 0 }
        withAnimation(.easeInOut(duration: 0.8)) { playIntensity = 0 }
        try? await Task.sleep(for: .milliseconds(800))
        if imageOpacity == 0 { flyingImage = nil }
    }
}
