import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the two edge panels:
///  • overlayPanel — wide, click-through, renders effects + flying images.
///  • zonePanel    — `sendZoneWidth` wide, click-through until a file drag is in progress,
///                   then it becomes the drop target that sends to the iPhone.
@MainActor
final class EdgeController {
    static let shared = EdgeController()

    let model = OverlayModel()
    private let overlayWidth: CGFloat = 460
    private var overlayPanel: EdgePanel!
    private var zonePanel: EdgePanel!
    private let dropView = DropZoneView(frame: .zero)
    private let dragMonitor = DragMonitor()
    private let haptics = EdgeHaptics()
    private var observers: [NSObjectProtocol] = []
    private var currentScreen: NSScreen?
    /// Set when DropZoneView receives the drop, so the release fallback doesn't send twice.
    private var dropHandled = false

    private init() {}

    func start() {
        overlayPanel = EdgePanel(contentRect: .zero)
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = [] // the panel decides the size, not SwiftUI
        overlayPanel.contentView = host

        zonePanel = EdgePanel(contentRect: .zero)
        zonePanel.contentView = dropView
        dropView.onHover = { [weak self] hovering in self?.model.dropHover = hovering }
        dropView.onDrop = { [weak self] urls in
            self?.dropHandled = true
            self?.send(urls)
        }

        dragMonitor.onActiveChanged = { [weak self] active in self?.dragStateChanged(active) }
        dragMonitor.onMove = { [weak self] point in self?.dragMoved(to: point) }
        dragMonitor.onRelease = { [weak self] point in self?.dragReleased(at: point) }
        dragMonitor.start()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        })

        layout()
        overlayPanel.orderFrontRegardless()
        zonePanel.orderFrontRegardless()
    }

    /// Plays the current effect with a sample image (menu + Settings "Preview").
    func preview() {
        let image = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)
            .flatMap { $0.withSymbolConfiguration(.init(pointSize: 120, weight: .regular)) }
        model.play(.incoming, image: image)
    }

    func flashZone() { model.flashZone() }

    // MARK: Incoming (iPhone → Mac)

    func receive(name: String, data: Data) {
        let safeName = FileNames.sanitize(name)
        let ext = (safeName as NSString).pathExtension
        let image = NSImage(data: data)
            ?? NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)

        IslandController.shared.flash(incoming: true, name: safeName, image: NSImage(data: data))
        model.play(.incoming, image: image) {
            do {
                let url = try DownloadsSaver.save(data: data, name: safeName)
                DownloadsSaver.bounceDownloadsStack(url)
            } catch {
                NSLog("Portal: failed to save \(safeName): \(error)")
                NSSound.beep()
            }
        }
    }

    // MARK: Outgoing (Mac → iPhone)

    func send(_ urls: [URL]) {
        guard PortalServer.shared.isConnected else { NSSound.beep(); return }
        for url in urls {
            let thumb = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
            let started = PortalServer.shared.send(fileURL: url) { ok in
                if !ok { NSSound.beep() }
            }
            if started {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                model.play(.outgoing, image: thumb)
                IslandController.shared.flash(incoming: false, name: url.lastPathComponent, image: thumb)
            } else {
                NSSound.beep()
            }
        }
    }

    // MARK: Drag tracking

    /// Fallback for when the window server doesn't route the drop to DropZoneView:
    /// if the button went up inside the send zone, read the dragged files from the drag pasteboard.
    private func dragReleased(at point: NSPoint) {
        guard let screen = currentScreen else { return }
        let f = screen.frame
        guard point.y >= f.minY, point.y <= f.maxY,
              f.maxX - point.x <= max(Prefs.sendZone, 2) + 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.dropHandled else { return }
                self.dropHandled = true
                let urls = (NSPasteboard(name: .drag).readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
                    .filter { !$0.hasDirectoryPath }
                if urls.isEmpty { NSSound.beep() } else { self.send(urls) }
            }
        }
    }

    private func dragStateChanged(_ active: Bool) {
        if active { dropHandled = false }
        zonePanel.ignoresMouseEvents = !active
        if active { zonePanel.orderFrontRegardless() }
        haptics.reset()
        model.zoneWidth = Prefs.sendZone
        withAnimation(.easeOut(duration: 0.2)) {
            model.dragActive = active
            if !active { model.dragProximity = 0; model.dropHover = false }
        }
    }

    private func dragMoved(to point: NSPoint) {
        guard let screen = currentScreen else { return }
        let f = screen.frame
        // Only react when the cursor is vertically on the edge screen.
        guard point.y >= f.minY, point.y <= f.maxY, point.x <= f.maxX + 1 else {
            model.dragProximity = 0
            return
        }
        let distance = max(0, f.maxX - point.x)
        haptics.update(distance: distance, zoneWidth: Prefs.sendZone)
        model.dragProximity = Double(max(0, 1 - distance / haptics.rampDistance))
    }

    // MARK: Layout

    private func preferencesChanged() {
        let width = Prefs.sendZone
        if width != model.zoneWidth {
            model.zoneWidth = width
            layout()
        }
        if model.effect != Prefs.currentEffect, model.playIntensity == 0 {
            model.effect = Prefs.currentEffect
        }
    }

    /// Pins both panels to the right edge of the right-most display
    /// (the only edge where the cursor actually stops in a multi-monitor setup).
    private func layout() {
        guard let screen = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) else { return }
        currentScreen = screen
        let f = screen.frame
        overlayPanel.setFrame(NSRect(x: f.maxX - overlayWidth, y: f.minY, width: overlayWidth, height: f.height),
                              display: true)
        let zone = max(2, Prefs.sendZone)
        zonePanel.setFrame(NSRect(x: f.maxX - zone, y: f.minY, width: zone, height: f.height), display: true)
        dropView.frame = NSRect(origin: .zero, size: zonePanel.frame.size)
    }
}

enum DownloadsSaver {
    static func save(data: Data, name: String) throws -> URL {
        // Sandboxed + com.apple.security.files.downloads.read-write → this resolves to the real ~/Downloads.
        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let url = FileNames.uniqueURL(in: downloads, for: name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Makes the Downloads stack in the Dock bounce, like Safari does.
    static func bounceDownloadsStack(_ url: URL) {
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                     object: url.resolvingSymlinksInPath().path)
    }
}
