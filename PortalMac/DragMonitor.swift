import AppKit
import QuartzCore

/// Detects system-wide file drags (from Finder or any app) without Accessibility permission:
/// a global mouse monitor notices a drag starting, and the drag pasteboard tells us it carries files.
/// While a drag is active we poll the cursor at 60 Hz (global monitors aren't reliable mid-drag).
@MainActor
final class DragMonitor {
    var onActiveChanged: ((Bool) -> Void)?
    var onMove: ((NSPoint) -> Void)?

    private(set) var isActive = false
    private var monitors: [Any] = []
    private var mouseDownChangeCount = 0
    private var pollTimer: Timer?
    private let dragPasteboard = NSPasteboard(name: .drag)

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        setActive(false)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownChangeCount = dragPasteboard.changeCount
        case .leftMouseDragged:
            guard !isActive,
                  dragPasteboard.changeCount != mouseDownChangeCount,
                  dragPasteboard.canReadObject(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true])
            else { return }
            setActive(true)
        default:
            break
        }
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        onActiveChanged?(active)
        pollTimer?.invalidate()
        pollTimer = nil
        guard active else { return }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(pollTimer!, forMode: .common) // keep firing during event tracking
    }

    private func poll() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            // Mouse released: keep the drop target alive a moment so performDragOperation can run.
            mouseDownChangeCount = dragPasteboard.changeCount
            pollTimer?.invalidate()
            pollTimer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isActive, self.pollTimer == nil else { return }
                    self.isActive = false
                    self.onActiveChanged?(false)
                }
            }
            return
        }
        onMove?(NSEvent.mouseLocation)
    }
}

/// Force Touch trackpad "ticks" that speed up as the cursor approaches the edge.
@MainActor
final class EdgeHaptics {
    /// Distance from the edge (pt) at which ticking begins.
    var rampDistance: CGFloat = 320
    private var lastTick: CFTimeInterval = 0
    private var wasInZone = false
    private let performer = NSHapticFeedbackManager.defaultPerformer

    func reset() {
        lastTick = 0
        wasInZone = false
    }

    /// - Parameters:
    ///   - distance: points between cursor and the right screen edge.
    ///   - zoneWidth: width of the send zone.
    func update(distance: CGFloat, zoneWidth: CGFloat) {
        let inZone = distance <= zoneWidth
        if inZone && !wasInZone {
            performer.perform(.levelChange, performanceTime: .now) // distinct "clunk" on entering
        }
        wasInZone = inZone
        guard distance < rampDistance else { return }

        // 0 at the zone boundary … 1 at the far end of the ramp.
        let t = max(0, min(1, (distance - zoneWidth) / max(1, rampDistance - zoneWidth)))
        // Quadratic so it accelerates noticeably near the edge: ~330 ms → 40 ms; 30 ms inside the zone.
        let interval: CFTimeInterval = inZone ? 0.03 : 0.04 + 0.29 * Double(t * t)

        let now = CACurrentMediaTime()
        if now - lastTick >= interval {
            performer.perform(.alignment, performanceTime: .now)
            lastTick = now
        }
    }
}
