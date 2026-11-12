import AppKit
import SwiftUI

/// Left-edge handle + full-screen Now Playing window.
///
/// The handle is invisible and click-through until the cursor touches the left edge of the
/// left-most display; then a small white tab slides out. Click it to open Now Playing.
/// Esc / ✕ closes; Space = play/pause, ← / → = previous / next.
@MainActor
final class NowPlayingController {
    static let shared = NowPlayingController()

    private var handlePanel: EdgePanel!
    private let handle = EdgeHandleView()
    private var window: NowPlayingWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var edgeScreen: NSScreen?
    private var handleShown = false

    private let handleSize = NSSize(width: 22, height: 120)

    private init() {}

    func start() {
        handlePanel = EdgePanel(contentRect: .zero)
        handlePanel.contentView = handle
        handle.onClick = { [weak self] in self?.open() }

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
            MainActor.assumeIsolated {
                guard let self, !Prefs.nowPlayingHandle, self.handleShown else { return }
                self.setHandleShown(false)
            }
        })

        layout()
        handlePanel.orderFrontRegardless()
    }

    // MARK: Full screen

    func open() {
        setHandleShown(false)
        if let window { window.makeKeyAndOrderFront(nil); return }

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let window = NowPlayingWindow(screen: screen)
        window.onClose = { [weak self] in self?.close() }
        window.contentView = NSHostingView(rootView: NowPlayingView(provider: .shared) { [weak self] in
            self?.close()
        })
        self.window = window

        NowPlayingProvider.shared.start()
        IslandController.shared.setSuppressed(true)
        window.alphaValue = 0
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            window.animator().alphaValue = 1
        }
    }

    func close() {
        guard let window else { return }
        self.window = nil
        NowPlayingProvider.shared.stop()
        IslandController.shared.setSuppressed(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }

    // MARK: Edge handle

    private func layout() {
        guard let screen = NSScreen.screens.min(by: { $0.frame.minX < $1.frame.minX }) else { return }
        edgeScreen = screen
        let f = screen.frame
        handlePanel.setFrame(NSRect(x: f.minX, y: f.midY - handleSize.height / 2,
                                    width: handleSize.width, height: handleSize.height), display: true)
        handle.frame = NSRect(origin: .zero, size: handleSize)
    }

    private func mouseMoved() {
        guard Prefs.nowPlayingHandle, window == nil, let screen = edgeScreen else { return }
        let p = NSEvent.mouseLocation
        let f = screen.frame
        let inBand = p.y > f.minY + f.height * 0.2 && p.y < f.maxY - f.height * 0.2
        if !handleShown {
            // Touching the left edge in the middle 60% of the screen reveals the tab.
            if inBand && p.x <= f.minX + 1 && NSEvent.pressedMouseButtons == 0 { setHandleShown(true) }
        } else if p.x > f.minX + 60 || !inBand {
            setHandleShown(false)
        }
    }

    private func setHandleShown(_ shown: Bool) {
        guard shown != handleShown else { return }
        handleShown = shown
        handlePanel.ignoresMouseEvents = !shown
        handle.setExpanded(shown)
    }
}

/// The white tab on the left edge. Plain AppKit so it reacts to the first click
/// even though Portal is a background app.
final class EdgeHandleView: NSView {
    var onClick: (() -> Void)?
    private let pill = CALayer()
    private let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        pill.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        pill.cornerRadius = 7
        pill.shadowOpacity = 0.35
        pill.shadowRadius = 6
        pill.shadowOffset = .zero
        pill.opacity = 0
        layer?.addSublayer(pill)

        icon.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Now Playing")
        icon.contentTintColor = .black
        icon.alphaValue = 0
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func layout() {
        super.layout()
        if pill.opacity == 0 { pill.frame = collapsedFrame }
        icon.frame = NSRect(x: 2, y: bounds.midY - 7, width: 14, height: 14)
    }

    private var collapsedFrame: NSRect { NSRect(x: -14, y: 10, width: 14, height: bounds.height - 20) }
    private var expandedFrame: NSRect { NSRect(x: -4, y: 10, width: 22, height: bounds.height - 20) }

    func setExpanded(_ expanded: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        pill.frame = expanded ? expandedFrame : collapsedFrame
        pill.opacity = expanded ? 1 : 0
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            icon.animator().alphaValue = expanded ? 1 : 0
        }
    }
}

/// Borderless full-screen window that can take keyboard focus.
final class NowPlayingWindow: NSWindow {
    var onClose: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2) // above the menu bar
        backgroundColor = .black
        isOpaque = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        let provider = NowPlayingProvider.shared
        switch event.keyCode {
        case 53: onClose?()             // Esc
        case 49: provider.playPause()   // Space
        case 123: provider.previous()   // ←
        case 124: provider.next()       // →
        default: super.keyDown(with: event)
        }
    }
}
