import SwiftUI

/// Root view of the click-through edge panel.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                let intensity = model.effectiveIntensity
                if intensity > 0.001 {
                    Group {
                        switch model.effect {
                        case .rainbow: RainbowBand(intensity: intensity)
                        case .portal: PortalRing(intensity: intensity)
                        }
                    }
                    .transition(.opacity)
                }

                if model.showsZone {
                    SendZoneIndicator(width: model.zoneWidth, hot: model.dropHover)
                        .transition(.opacity)
                }

                if let image = model.flyingImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 260, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.85), lineWidth: 3))
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                        .opacity(model.imageOpacity)
                        .modifier(FlyModifier(progress: model.flyProgress, size: geo.size))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.25), value: model.showsZone)
            .animation(.easeInOut(duration: 0.2), value: model.dropHover)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Moves the image along a curved path from just beyond the right edge (0) to its resting spot (1).
/// Animatable so the spring follows the curve instead of a straight line.
struct FlyModifier: ViewModifier, Animatable {
    var progress: CGFloat
    let size: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        let startX = size.width + 140
        let endX = size.width - 200
        let x = startX + (endX - startX) * p
        let y = size.height / 2 - sin(min(max(p, 0), 1) * .pi) * 70 // arc upward mid-flight
        return content
            .scaleEffect(0.12 + 0.88 * max(p, 0))
            .rotation3DEffect(.degrees(Double(1 - p) * 55), axis: (x: 0, y: 1, z: 0))
            .rotationEffect(.degrees(Double(1 - p) * 18))
            .position(x: x, y: y)
    }
}

struct SendZoneIndicator: View {
    let width: CGFloat
    let hot: Bool

    var body: some View {
        Rectangle()
            .fill(.white.opacity(hot ? 0.45 : 0.18))
            .overlay(alignment: .leading) {
                Rectangle().fill(.white.opacity(hot ? 0.9 : 0.5)).frame(width: 1)
            }
            .frame(width: max(width, 2))
            .frame(maxHeight: .infinity)
    }
}
