import SwiftUI

// MARK: - Rainbow

/// An animated, heavily blurred rainbow band hugging the right screen edge.
struct RainbowBand: View {
    var intensity: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: intensity <= 0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (t / 3.5).truncatingRemainder(dividingBy: 1)
            let colors = (0...10).map { i in
                Color(hue: (Double(i) / 10 + phase).truncatingRemainder(dividingBy: 1),
                      saturation: 0.95, brightness: 1)
            }
            let gradient = LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            let breathe = 1 + 0.12 * sin(t * 2.6)
            let width = (40 + 90 * intensity) * breathe

            ZStack(alignment: .trailing) {
                // Wide soft glow, pushed partly off-screen so the brightest part sits on the edge.
                gradient
                    .frame(width: width)
                    .blur(radius: 34)
                    .offset(x: width * 0.35)
                    .opacity(0.9)
                // Secondary band drifting the other way for depth.
                LinearGradient(colors: colors.reversed(), startPoint: .top, endPoint: .bottom)
                    .frame(width: width * 0.6)
                    .blur(radius: 22)
                    .offset(x: width * 0.2, y: CGFloat(sin(t * 1.3)) * 40)
                    .opacity(0.6)
                // Bright core line on the edge.
                gradient
                    .frame(width: 5)
                    .blur(radius: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .blendMode(.plusLighter)
            .opacity(min(1, intensity))
        }
    }
}

// MARK: - Portal

/// A swirling ring half-embedded in the right edge, with particles spiralling into it.
struct PortalRing: View {
    var intensity: Double
    var particleCount = 140

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: intensity <= 0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(in: &ctx, size: size, t: t)
            }
        }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let k = min(1, max(0, intensity))
        let center = CGPoint(x: size.width - 6, y: size.height / 2)
        let radius = 170 * (0.35 + 0.65 * k)
        ctx.blendMode = .plusLighter

        // 1. Outer glow.
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 40))
            let r = radius * 1.35
            layer.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                       with: .radialGradient(Gradient(colors: [.purple.opacity(0.8 * k), .blue.opacity(0.45 * k), .clear]),
                                             center: center, startRadius: radius * 0.3, endRadius: r))
        }

        // 2. Swirling arcs, alternating direction, conic-shaded.
        let swirl = Gradient(colors: [.cyan, .blue, .purple, .pink, .orange, .cyan])
        for i in 0..<7 {
            let fi = Double(i)
            let r = radius * (0.5 + 0.08 * fi)
            let dir: Double = i.isMultiple(of: 2) ? 1 : -1
            let start = Angle.radians(dir * t * (1.4 + 0.35 * fi) + fi * 1.7)
            var arc = Path()
            arc.addArc(center: center, radius: r, startAngle: start,
                       endAngle: start + .degrees(150 + 25 * fi), clockwise: false)
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 1.5 + fi * 0.4))
                layer.opacity = 0.85 * k
                layer.stroke(arc,
                             with: .conicGradient(swirl, center: center, angle: start),
                             style: StrokeStyle(lineWidth: 7 - fi * 0.7, lineCap: .round))
            }
        }

        // 3. Dark core with a bright rim (the "hole").
        let coreR = radius * 0.42
        ctx.blendMode = .normal
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - coreR, y: center.y - coreR, width: coreR * 2, height: coreR * 2)),
                 with: .radialGradient(Gradient(colors: [.black.opacity(0.85 * k), .indigo.opacity(0.4 * k), .clear]),
                                       center: center, startRadius: 0, endRadius: coreR))
        ctx.blendMode = .plusLighter
        ctx.stroke(Path(ellipseIn: CGRect(x: center.x - coreR, y: center.y - coreR, width: coreR * 2, height: coreR * 2)),
                   with: .color(.white.opacity(0.7 * k)), lineWidth: 2)

        // 4. Particles: stateless — each one's position is a pure function of (index, time).
        for i in 0..<particleCount {
            let seed = Self.hash(Double(i))
            let seed2 = Self.hash(Double(i) + 91.7)
            let speed = 0.18 + seed * 0.35
            let life = (t * speed + seed2).truncatingRemainder(dividingBy: 1) // 0 → 1, then respawn
            let angle = seed * .pi * 2 + life * 5.0 + t * 0.6               // spiral in
            let dist = radius * (1.9 - 1.5 * life)
            let p = CGPoint(x: center.x + cos(angle) * dist, y: center.y + sin(angle) * dist)
            let s = 1.2 + 2.8 * (1 - life)
            let alpha = 4 * life * (1 - life) * k                             // fade in and out
            let hue = (0.55 + 0.35 * seed2 + life * 0.1).truncatingRemainder(dividingBy: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                     with: .color(Color(hue: hue, saturation: 0.6, brightness: 1).opacity(alpha)))
        }
    }

    private static func hash(_ x: Double) -> Double {
        let v = sin(x * 12.9898) * 43758.5453
        return v - v.rounded(.down)
    }
}
