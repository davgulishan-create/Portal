import AppKit
import SwiftUI

struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double // seconds (0 = unknown)
    var source: PlayerSource

    var id: String { "\(source.bundleID)|\(artist)|\(album)|\(title)" }
}

/// Where the music comes from. Music and Spotify are scripted directly; browsers are asked,
/// through AppleScript, to run a tiny JavaScript snippet in the tab that is playing media.
enum PlayerSource: Equatable {
    case music
    case spotify
    case browser(Browser)

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .browser(let b): return b.bundleID
        }
    }

    var displayName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        case .browser(let b): return b.name
        }
    }
}

struct Browser: Equatable {
    enum Kind { case safari, chromium }
    let bundleID: String
    let name: String
    let kind: Kind

    static let all: [Browser] = [
        Browser(bundleID: "com.apple.Safari", name: "Safari", kind: .safari),
        Browser(bundleID: "com.google.Chrome", name: "Chrome", kind: .chromium),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc", kind: .chromium),
        Browser(bundleID: "com.brave.Browser", name: "Brave", kind: .chromium),
        Browser(bundleID: "com.microsoft.edgemac", name: "Edge", kind: .chromium),
        Browser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", kind: .chromium),
    ]

    /// How to switch on "Allow JavaScript from Apple Events" (off by default in every browser).
    var enableJavaScriptHint: String {
        switch kind {
        case .safari:
            return "Safari ▸ Settings ▸ Advanced ▸ “Show features for web developers”, then Develop ▸ “Allow JavaScript from Apple Events”."
        case .chromium:
            return "\(name): View ▸ Developer ▸ “Allow JavaScript from Apple Events”."
        }
    }
}

/// Reads the current track from Music, Spotify or a browser tab via AppleScript (the private
/// MediaRemote framework is off-limits to third-party apps on recent macOS).
/// Polls once a second only while someone is watching (`start()` / `stop()`).
@MainActor
final class NowPlayingProvider: ObservableObject {
    static let shared = NowPlayingProvider()

    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: Color = Color(white: 0.15)
    @Published private(set) var lyrics: Lyrics = .none
    /// The user declined "Portal wants to control …" for every running player.
    @Published private(set) var automationDenied = false
    /// A browser is running but has "Allow JavaScript from Apple Events" switched off.
    @Published private(set) var browserHint: String?

    private var position: Double = 0
    private var positionDate = Date()
    private var tabURL: String? // the browser tab currently being followed
    private var timer: Timer?
    private var watchers = 0
    private var generation = 0 // bumps on every track change to drop stale async results
    private var polling = false
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
        send(app: "playpause", js: "if(m){if(m.paused){m.play()}else{m.pause()}}")
        position = position(at: .now)
        positionDate = .now
        isPlaying.toggle()
    }

    func next() {
        send(app: "next track",
             js: "var b=document.querySelector('.ytp-next-button,.next-button,[data-testid=control-button-skip-forward],[aria-label=Next]');if(b){b.click()}")
        refreshSoon()
    }

    func previous() {
        send(app: "previous track",
             js: "var b=document.querySelector('.ytp-prev-button,.previous-button,[data-testid=control-button-skip-back],[aria-label=Previous]');if(b){b.click()}else if(m){m.currentTime=0}")
        refreshSoon()
    }

    func seek(to seconds: Double) {
        let s = String(format: "%.2f", max(0, seconds))
        send(app: "set player position to \(s)", js: "if(m){m.currentTime=\(s)}")
        position = seconds
        positionDate = .now
    }

    // MARK: Polling

    private func runningSources() -> [PlayerSource] {
        let isRunning = { (id: String) in !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
        var sources: [PlayerSource] = [.spotify, .music].filter { isRunning($0.bundleID) }
        sources += Browser.all.filter { isRunning($0.bundleID) }.map { .browser($0) }
        return sources
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard !polling else { return } // previous poll still talking to a slow app
        // Only talk to players that are already running — never launch them.
        let sources = runningSources()
        guard !sources.isEmpty else { apply(nil); browserHint = nil; return }
        polling = true

        queue.async {
            var best: Snapshot?
            var denied = 0
            var hint: String?
            for source in sources {
                let result = Self.runScript(Self.statusScript(for: source))
                if result.errorCode == -1743 { denied += 1; continue }
                if case .browser(let b) = source, let message = result.errorMessage,
                   message.localizedCaseInsensitiveContains("javascript") {
                    hint = hint ?? b.enableJavaScriptHint
                    continue
                }
                guard let desc = result.descriptor, let snap = Snapshot(desc, source: source) else { continue }
                if snap.playing { best = snap; break } // a playing source wins
                if best == nil { best = snap }          // otherwise remember a paused one
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.polling = false
                    self.automationDenied = denied > 0 && best == nil
                    self.browserHint = best == nil ? hint : nil
                    self.apply(best)
                }
            }
        }
    }

    private func apply(_ snap: Snapshot?) {
        guard let snap else {
            if track != nil { track = nil; artwork = nil; lyrics = .none; tint = Color(white: 0.15) }
            isPlaying = false
            tabURL = nil
            return
        }
        isPlaying = snap.playing
        position = snap.position
        positionDate = .now
        tabURL = snap.tabURL

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
                let q = LyricsService.cleaned(track)
                url = await ArtworkService.lookup(artist: q.artist, album: q.album, title: q.title)
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
            let q = LyricsService.cleaned(track)
            let result = await LyricsService.fetch(title: q.title, artist: q.artist,
                                                   album: q.album, duration: track.duration)
            guard gen == generation else { return }
            lyrics = result
        }
    }

    // MARK: AppleScript

    /// Sends a command to the current player: an AppleScript verb for Music/Spotify, or a
    /// JavaScript snippet (with `m` bound to the page's media element) for a browser tab.
    private func send(app verb: String, js: String) {
        guard let source = track?.source else { return }
        let script: String
        switch source {
        case .music, .spotify:
            script = "tell application id \"\(source.bundleID)\" to \(verb)"
        case .browser(let browser):
            guard let tabURL else { return }
            script = Self.browserCommandScript(browser, tabURL: tabURL, js: Self.findMediaJS + js)
        }
        queue.async { _ = Self.runScript(script) }
    }

    private nonisolated static func statusScript(for source: PlayerSource) -> String {
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
        case .browser(let browser):
            return browserStatusScript(browser)
        }
    }

    // MARK: Browser scripts

    /// Sites worth scanning. Checking the URL first keeps us from running JS in every tab.
    private nonisolated static let mediaHosts = [
        "youtube.com", "youtu.be", "soundcloud.com", "open.spotify.com", "music.apple.com",
        "deezer.com", "bandcamp.com", "music.yandex", "vk.com", "vk.ru", "zvuk.com",
        "mixcloud.com", "tidal.com", "music.amazon", "twitch.tv",
    ]

    /// Binds `m` to the playing (or first) audio/video element on the page.
    private nonisolated static let findMediaJS =
        "var ms=Array.prototype.slice.call(document.querySelectorAll('video,audio'));" +
        "var m=ms.find(function(e){return !e.paused&&e.duration>0})||ms.find(function(e){return e.duration>0})||null;"

    /// Returns a JSON string describing the media in the tab, or '' if there is none.
    /// Title/artist/artwork come from the Media Session API, which YouTube, SoundCloud,
    /// Spotify Web, Yandex Music, VK etc. all fill in for the system media controls.
    private nonisolated static let statusJS =
        "(function(){" + findMediaJS +
        "var s=navigator.mediaSession;var md=s&&s.metadata;" +
        "if(!m&&!(md&&s.playbackState&&s.playbackState!=='none'))return '';" +
        "var art='';if(md&&md.artwork&&md.artwork.length){art=md.artwork[md.artwork.length-1].src}" +
        "var playing=m?!m.paused:s.playbackState==='playing';" +
        "return JSON.stringify({title:(md&&md.title)||document.title,artist:(md&&md.artist)||''," +
        "album:(md&&md.album)||'',artwork:art,duration:(m&&isFinite(m.duration))?m.duration:0," +
        "position:m?m.currentTime:0,playing:playing,url:location.href})})()"

    private nonisolated static func browserStatusScript(_ browser: Browser) -> String {
        let hostCheck = mediaHosts.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let run = browser.kind == .safari
            ? "do JavaScript \"\(appleScriptEscaped(statusJS))\" in t"
            : "execute t javascript \"\(appleScriptEscaped(statusJS))\""
        return """
        tell application id "\(browser.bundleID)"
            set best to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set u to ""
                    try
                        set u to URL of t
                    end try
                    if u is not missing value and (\(hostCheck)) then
                        set r to \(run)
                        if r is not missing value and r is not "" then
                            if r contains "\\"playing\\":true" then return r
                            if best is "" then set best to r
                        end if
                    end if
                end repeat
            end repeat
            return best
        end tell
        """
    }

    private nonisolated static func browserCommandScript(_ browser: Browser, tabURL: String, js: String) -> String {
        let wrapped = "(function(){" + js + "})()"
        let run = browser.kind == .safari
            ? "do JavaScript \"\(appleScriptEscaped(wrapped))\" in t"
            : "execute t javascript \"\(appleScriptEscaped(wrapped))\""
        return """
        tell application id "\(browser.bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    set u to ""
                    try
                        set u to URL of t
                    end try
                    if u is "\(appleScriptEscaped(tabURL))" then
                        \(run)
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    private nonisolated static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private nonisolated static func runScript(_ source: String)
        -> (descriptor: NSAppleEventDescriptor?, errorCode: Int?, errorMessage: String?) {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return (error == nil ? result : nil,
                error?[NSAppleScript.errorNumber] as? Int,
                error?[NSAppleScript.errorMessage] as? String)
    }
}

/// One poll result, parsed off the main thread.
private struct Snapshot {
    let track: NowPlayingTrack
    let playing: Bool
    let position: Double
    let artworkURL: URL?
    let tabURL: String?

    init?(_ d: NSAppleEventDescriptor, source: PlayerSource) {
        if case .browser = source {
            // Browser scripts return the JSON string from the page.
            struct Page: Decodable {
                let title: String; let artist: String; let album: String; let artwork: String
                let duration: Double; let position: Double; let playing: Bool; let url: String
            }
            guard let json = d.stringValue, !json.isEmpty,
                  let page = try? JSONDecoder().decode(Page.self, from: Data(json.utf8)),
                  !page.title.isEmpty else { return nil }
            track = NowPlayingTrack(title: page.title, artist: page.artist, album: page.album,
                                    duration: page.duration, source: source)
            playing = page.playing
            position = page.position
            artworkURL = URL(string: page.artwork)
            tabURL = page.url
            return
        }

        guard d.numberOfItems >= 6, let state = d.atIndex(1)?.stringValue, state != "stopped" else { return nil }
        func str(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double { d.atIndex(i)?.doubleValue ?? 0 }
        let title = str(2)
        guard !title.isEmpty else { return nil }
        track = NowPlayingTrack(title: title, artist: str(3), album: str(4), duration: num(5), source: source)
        playing = state == "playing"
        position = num(6)
        artworkURL = d.numberOfItems >= 7 ? URL(string: str(7)) : nil
        tabURL = nil
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
