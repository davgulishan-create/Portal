import AppKit
import QuartzCore

/// Detects system-wide file drags (from Finder or any app) without Accessibility permission.
///
/// Mouse events are NOT reliably delivered to global monitors once a drag session has started,
/// so instead we poll: while the left button is held, we watch the drag pasteboard's changeCount.
/// When it changes and carries file URLs, a file drag is in progress. A global mouse-down monitor
/// only records the baseline changeCount at the exact moment the button goes down.
@MainActor
final class DragMonitor {
    var onActiveChanged: ((Bool) -> Void)?
    var onMove: ((NSPoint) -> Void)?

    private(set) var isActive = false
    private var monitors: [Any] = []
    private var baselineChangeCount = 0
    private var buttonWasDown = false
    private var timer: Timer?
    private var fastPolling = false
    private let dragPasteboard = NSPasteboard(name: .drag)

    func start() {
        baselineChangeCount = dragPasteboard.changeCount
        let recordBaseline: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.baselineChangeCount = self.dragPasteboard.changeCount
                self.buttonWasDown = true
                self.setFastPolling(true)
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: recordBaseline) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in
            recordBaseline(event)
            return event
        }) {
            monitors.append(local)
        }
        setFastPolling(false)
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        timer?.invalidate()
        timer = nil
        if isActive { isActive = false; onActiveChanged?(false) }
    }

    /// 60 Hz while the button is down (smooth haptics), 10 Hz otherwise (cheap safety net
    /// in case a mouse-down was missed).
    private func setFastPolling(_ fast: Bool) {
        guard timer == nil || fast != fastPolling else { return }
        fastPolling = fast
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 60.0 : 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common) // keep firing during event tracking / drag loops
        timer = t
    }

    private func poll() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0

        if buttonDown {
            if !buttonWasDown {
                // Missed the mouse-down event: take the baseline now.
                buttonWasDown = true
                baselineChangeCount = dragPasteboard.changeCount
                setFastPolling(true)
                return
            }
            if !isActive,
               dragPasteboard.changeCount != baselineChangeCount,
               dragPasteboard.canReadObject(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) {
                isActive = true
                onActiveChanged?(true)
            }
            if isActive { onMove?(NSEvent.mouseLocation) }
            return
        }

        // Button is up.
        guard buttonWasDown else { return }
        buttonWasDown = false
        baselineChangeCount = dragPasteboard.changeCount
        setFastPolling(false)
        if isActive {
            // Keep the drop target alive a moment so performDragOperation can run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isActive, !self.buttonWasDown else { return }
                    self.isActive = false
                    self.onActiveChanged?(false)
                }
            }
        }
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
