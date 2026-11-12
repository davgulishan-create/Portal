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
    /// From the system-wide Now Playing (any app: Yandex Music, VK, Telegram…).
    case system(app: String, bundleID: String)

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .browser(let b): return b.bundleID
        case .system(_, let id): return id
        }
    }

    var isBrowser: Bool {
        if case .browser = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        case .browser(let b): return b.name
        case .system(let app, _): return app.isEmpty ? "Now Playing" : app
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
        Browser(bundleID: "ru.yandex.desktop.yandex-browser", name: "Yandex Browser", kind: .chromium),
        Browser(bundleID: "com.operasoftware.Opera", name: "Opera", kind: .chromium),
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
    /// One line per player from the last poll ("Music: playing", "Safari: JavaScript off"…).
    /// Shown in Settings so problems can be diagnosed from a screenshot.
    @Published private(set) var diagnostics: [String] = []

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

    /// NSAppleScript is only reliable on the main thread, so polls run here. Every script is
    /// wrapped in a short timeout, so a hung app can't freeze Portal for long.
    private let systemQueue = DispatchQueue(label: "portal.nowplaying.system", qos: .userInitiated)
    private var systemWorks = true // flips to false if this macOS closes the workaround

    private func refresh() {
        guard !polling else { return }
        polling = true
        guard systemWorks else { refreshViaAppleScript(systemNote: nil); return }
        systemQueue.async {
            let result = MediaRemoteBridge.nowPlaying(withArtwork: false)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishSystemRefresh(result) }
            }
        }
    }

    private func finishSystemRefresh(_ result: (info: MediaRemoteBridge.Info?, error: String?)) {
        if let info = result.info {
            polling = false
            let snap = Snapshot(system: info)
            diagnostics = ["System Now Playing: \(snap.track.source.displayName) — \(snap.playing ? "playing" : "paused") — \(snap.track.title)"]
            automationDenied = false
            browserHint = nil
            apply(snap)
            return
        }
        if let error = result.error, error.contains("unavailable") || error.contains("not found") {
            systemWorks = false
        }
        refreshViaAppleScript(systemNote: "System Now Playing: " + (result.error ?? "nothing playing"))
    }

    private func refreshViaAppleScript(systemNote: String?) {
        polling = false
        // Only talk to players that are already running — never launch them.
        let sources = runningSources()
        guard !sources.isEmpty else {
            diagnostics = [systemNote, "No Music, Spotify or supported browser is running"].compactMap { $0 }
            browserHint = nil
            automationDenied = false
            apply(nil)
            return
        }
        var best: Snapshot?
        var denied = 0
        var hint: String?
        var report: [String] = systemNote.map { [$0] } ?? []
        for source in sources {
            let name = source.displayName
            let result = Self.runScript(Self.statusScript(for: source))
            if result.errorCode == -1743 {
                denied += 1
                report.append("\(name): permission denied — System Settings ▸ Privacy & Security ▸ Automation ▸ Portal")
                continue
            }
            if let message = result.errorMessage {
                if case .browser(let b) = source, message.localizedCaseInsensitiveContains("javascript") {
                    hint = hint ?? b.enableJavaScriptHint
                    report.append("\(name): “Allow JavaScript from Apple Events” is off")
                } else {
                    report.append("\(name): error \(result.errorCode ?? 0) — \(message)")
                }
                continue
            }
            guard let desc = result.descriptor, let snap = Snapshot(desc, source: source) else {
                report.append(source.isBrowser ? "\(name): no tab playing media" : "\(name): stopped")
                continue
            }
            report.append("\(name): \(snap.playing ? "playing" : "paused") — \(snap.track.title)")
            if snap.playing { best = snap; break } // a playing source wins
            if best == nil { best = snap }          // otherwise remember a paused one
        }
        diagnostics = report
        automationDenied = denied > 0 && best == nil
        browserHint = best == nil ? hint : nil
        apply(best)
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
                let result = Self.runScript("""
                tell application id "com.apple.Music"
                    try
                        return data of artwork 1 of current track
                    end try
                end tell
                """)
                if let data = result.descriptor?.data { image = NSImage(data: data) }
            }
            if case .system = track.source {
                let info = await withCheckedContinuation { cont in
                    systemQueue.async { cont.resume(returning: MediaRemoteBridge.nowPlaying(withArtwork: true).info) }
                }
                if let b64 = info?.artwork, !b64.isEmpty, let data = Data(base64Encoded: b64) {
                    image = NSImage(data: data)
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
        case .system(_, let bundleID):
            // Music and Spotify are scriptable — more reliable than MediaRemote commands.
            if bundleID == PlayerSource.music.bundleID || bundleID == PlayerSource.spotify.bundleID {
                script = "tell application id \"\(bundleID)\" to \(verb)"
            } else {
                systemQueue.async {
                    if verb == "playpause" { MediaRemoteBridge.send(.togglePlayPause) }
                    else if verb == "next track" { MediaRemoteBridge.send(.nextTrack) }
                    else if verb == "previous track" { MediaRemoteBridge.send(.previousTrack) }
                    else if verb.hasPrefix("set player position to "),
                            let seconds = Double(verb.dropFirst("set player position to ".count)) {
                        MediaRemoteBridge.seek(to: seconds)
                    }
                }
                return
            }
        case .music, .spotify:
            script = "tell application id \"\(source.bundleID)\" to \(verb)"
        case .browser(let browser):
            guard let tabURL else { return }
            script = Self.browserCommandScript(browser, tabURL: tabURL, js: Self.findMediaJS + js)
        }
        _ = Self.runScript(script)
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
        case .system:
            return "" // read through MediaRemoteBridge, never via AppleScript
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
        let frontTab = browser.kind == .safari ? "current tab of w" : "active tab of w"
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
            if best is not "" then return best
            -- Any other site: look at the visible tab of each window.
            repeat with w in windows
                set t to missing value
                try
                    set t to \(frontTab)
                end try
                if t is not missing value then
                    set r to \(run)
                    if r is not missing value and r is not "" then
                        if r contains "\\"playing\\":true" then return r
                        if best is "" then set best to r
                    end if
                end if
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
        let wrapped = "with timeout of 3 seconds\n" + source + "\nend timeout"
        let result = NSAppleScript(source: wrapped)?.executeAndReturnError(&error)
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

    init(system info: MediaRemoteBridge.Info) {
        let source = PlayerSource.system(app: info.app ?? "", bundleID: info.bundleID ?? "system")
        track = NowPlayingTrack(title: info.title ?? "", artist: info.artist ?? "", album: info.album ?? "",
                                duration: info.duration ?? 0, source: source)
        let isPlaying = info.playing ?? ((info.rate ?? 0) > 0)
        playing = isPlaying
        // Elapsed time is reported "as of" timestamp; advance it to now while playing.
        var pos = info.elapsed ?? 0
        if isPlaying, let ts = info.timestamp, ts > 0 {
            pos += max(0, Date().timeIntervalSince1970 - ts) * max(info.rate ?? 1, 0.01)
        }
        position = pos
        artworkURL = nil
        tabURL = nil
    }

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
