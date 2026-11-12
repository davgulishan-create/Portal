import AppKit
import SwiftUI

struct NowPlayingTrack: Equatable {
    enum Source: String {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"
    }

    var title: String
    var artist: String
    var album: String
    var duration: Double // seconds
    var source: Source

    var id: String { "\(source.rawValue)|\(artist)|\(album)|\(title)" }
}

/// Reads the current track from Music or Spotify via AppleScript (both apps are scriptable;
/// the private MediaRemote framework is off-limits to third-party apps on recent macOS).
/// Polls once a second only while someone is watching (`start()` / `stop()`).
@MainActor
final class NowPlayingProvider: ObservableObject {
    static let shared = NowPlayingProvider()

    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: Color = Color(white: 0.15)
    @Published private(set) var lyrics: Lyrics = .none
    /// The user declined "Portal wants to control Music/Spotify".
    @Published private(set) var automationDenied = false

    private var position: Double = 0
    private var positionDate = Date()
    private var timer: Timer?
    private var watchers = 0
    private var generation = 0 // bumps on every track change to drop stale async results
    private let queue = DispatchQueue(label: "portal.nowplaying.applescript", qos: .userInitiated)

    // MARK: Lifecycle

    func start() {
        watchers += 1
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Interpolated playback position, smooth between the 1 s polls.
    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return track.duration > 0 ? min(max(0, p), track.duration) : max(0, p)
    }

    // MARK: Controls

    func playPause() {
        command("playpause")
        isPlaying.toggle()
        position = position(at: .now)
        positionDate = .now
    }

    func next() { command("next track"); refreshSoon() }
    func previous() { command("previous track"); refreshSoon() }

    func seek(to seconds: Double) {
        command("set player position to \(String(format: "%.2f", max(0, seconds)))")
        position = seconds
        positionDate = .now
    }

    // MARK: Polling

    private var runningSources: [NowPlayingTrack.Source] {
        [.spotify, .music].filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty
        }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        // Only talk to players that are already running — never launch them.
        let sources = runningSources
        guard !sources.isEmpty else { apply(nil); return }

        queue.async {
            var best: Snapshot?
            var denied = false
            for source in sources {
                let result = Self.runScript(Self.statusScript(for: source))
                if result.errorCode == -1743 { denied = true; continue }
                guard let desc = result.descriptor, let snap = Snapshot(desc, source: source) else { continue }
                if snap.playing { best = snap; break } // a playing source wins
                if best == nil { best = snap }          // otherwise remember a paused one
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.automationDenied = denied && best == nil
                    self.apply(best)
                }
            }
        }
    }

    private func apply(_ snap: Snapshot?) {
        guard let snap else {
            if track != nil { track = nil; artwork = nil; lyrics = .none; tint = Color(white: 0.15) }
            isPlaying = false
            return
        }
        isPlaying = snap.playing
        position = snap.position
        positionDate = .now

        guard snap.track.id != track?.id else { return }
        track = snap.track
        generation += 1
        artwork = nil
        lyrics = Prefs.fetchLyrics ? .loading : .none
        loadArtwork(for: snap, generation: generation)
        if Prefs.fetchLyrics { loadLyrics(for: snap.track, generation: generation) }
    }

    // MARK: Artwork & lyrics

    private func loadArtwork(for snap: Snapshot, generation gen: Int) {
        let track = snap.track
        Task {
            var image: NSImage?
            if track.source == .music {
                image = await withCheckedContinuation { cont in
                    queue.async {
                        let result = Self.runScript("""
                        tell application id "com.apple.Music"
                            try
                                return data of artwork 1 of current track
                            end try
                        end tell
                        """)
                        let data = result.descriptor?.data
                        cont.resume(returning: data.flatMap { NSImage(data: $0) })
                    }
                }
            }
            var url = snap.artworkURL
            if image == nil, url == nil {
                url = await ArtworkService.lookup(artist: track.artist, album: track.album, title: track.title)
            }
            if image == nil, let url, let result = try? await URLSession.shared.data(from: url) {
                image = NSImage(data: result.0)
            }
            guard gen == generation else { return }
            withAnimation(.easeInOut(duration: 0.8)) {
                artwork = image
                tint = image.map { Color(nsColor: $0.averageColor) } ?? Color(white: 0.15)
            }
        }
    }

    private func loadLyrics(for track: NowPlayingTrack, generation gen: Int) {
        Task {
            let result = await LyricsService.fetch(title: track.title, artist: track.artist,
                                                   album: track.album, duration: track.duration)
            guard gen == generation else { return }
            lyrics = result
        }
    }

    // MARK: AppleScript

    private func command(_ verb: String) {
        guard let source = track?.source ?? runningSources.first else { return }
        queue.async {
            _ = Self.runScript("tell application id \"\(source.rawValue)\" to \(verb)")
        }
    }

    private nonisolated static func statusScript(for source: NowPlayingTrack.Source) -> String {
        switch source {
        case .music:
            return """
            tell application id "com.apple.Music"
                set st to player state as string
                if st is "stopped" then return {"stopped"}
                set t to current track
                return {st, name of t, artist of t, album of t, duration of t, player position, ""}
            end tell
            """
        case .spotify:
            return """
            tell application id "com.spotify.client"
                set st to player state as string
                if st is "stopped" then return {"stopped"}
                set t to current track
                return {st, name of t, artist of t, album of t, (duration of t) / 1000, player position, artwork url of t}
            end tell
            """
        }
    }

    private nonisolated static func runScript(_ source: String) -> (descriptor: NSAppleEventDescriptor?, errorCode: Int?) {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return (error == nil ? result : nil, error?[NSAppleScript.errorNumber] as? Int)
    }
}

/// One poll result, parsed off the main thread.
private struct Snapshot {
    let track: NowPlayingTrack
    let playing: Bool
    let position: Double
    let artworkURL: URL?

    init?(_ d: NSAppleEventDescriptor, source: NowPlayingTrack.Source) {
        guard d.numberOfItems >= 6, let state = d.atIndex(1)?.stringValue, state != "stopped" else { return nil }
        func str(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double { d.atIndex(i)?.doubleValue ?? 0 }
        let title = str(2)
        guard !title.isEmpty else { return nil }
        track = NowPlayingTrack(title: title, artist: str(3), album: str(4), duration: num(5), source: source)
        playing = state == "playing"
        position = num(6)
        artworkURL = d.numberOfItems >= 7 ? URL(string: str(7)) : nil
    }
}

extension NSImage {
    /// Average colour of the image (used to tint the background glow).
    var averageColor: NSColor {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)
        guard let rep else { return .darkGray }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .medium
        draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 0, y: 0) ?? .darkGray
    }
}
