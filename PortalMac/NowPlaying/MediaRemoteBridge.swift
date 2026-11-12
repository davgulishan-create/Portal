import Foundation

/// Reads the system-wide "Now Playing" (the one in Control Center), which every player feeds:
/// Yandex Music, VK, Telegram, YouTube Music apps, browsers, Music, Spotify…
///
/// Since macOS 15.4 the private MediaRemote framework only answers Apple's own processes.
/// `/usr/bin/osascript` is one of them, so we ask it to run a small JavaScript-for-Automation
/// snippet that loads MediaRemote and prints the current item as JSON. This is a workaround:
/// if a future macOS closes it, `nowPlaying()` returns an error and Portal falls back to
/// AppleScript (Music, Spotify, browser tabs).
///
/// Requires Portal to run without the App Sandbox (a sandboxed child process can't reach
/// the media service).
enum MediaRemoteBridge {
    struct Info: Decodable {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var timestamp: Double?
        var playing: Bool?
        var app: String?
        var bundleID: String?
        var artwork: String? // base64, only when asked for
        var error: String?
    }

    enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    /// nil info + message = not available / failed; nil info + nil message = nothing playing.
    static func nowPlaying(withArtwork: Bool) -> (info: Info?, error: String?) {
        guard let output = runJXA(statusScript, arguments: withArtwork ? ["art"] : []) else {
            return (nil, "osascript did not answer")
        }
        if output.isEmpty { return (nil, nil) }
        guard let info = try? JSONDecoder().decode(Info.self, from: Data(output.utf8)) else {
            return (nil, String(output.prefix(160)))
        }
        if let error = info.error { return (nil, error) }
        guard let title = info.title, !title.isEmpty else { return (nil, nil) }
        return (info, nil)
    }

    static func send(_ command: Command) {
        _ = runJXA(commandScript, arguments: [String(command.rawValue)])
    }

    static func seek(to seconds: Double) {
        _ = runJXA(commandScript, arguments: ["seek", String(format: "%.2f", seconds)])
    }

    // MARK: - JXA

    private static let statusScript = """
    ObjC.import('Foundation');
    function run(argv) {
      try { return status(argv); } catch (e) { return JSON.stringify({error: 'JXA: ' + String(e)}); }
    }
    function status(argv) {
      var b = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
      if (!b || !b.load) return JSON.stringify({error: 'MediaRemote not found'});
      var R = $.NSClassFromString('MRNowPlayingRequest');
      if (!R || R.isNil()) return JSON.stringify({error: 'MRNowPlayingRequest unavailable on this macOS'});
      var item = R.localNowPlayingItem;
      if (!item || item.isNil()) return '';
      var info = item.nowPlayingInfo;
      if (!info || info.isNil()) return '';
      function get(k) { var v = info.valueForKey(k); return (v && !v.isNil()) ? ObjC.unwrap(v) : null; }
      var app = '', bid = '';
      try {
        var c = R.localNowPlayingPlayerPath.client;
        app = ObjC.unwrap(c.displayName) || '';
        bid = ObjC.unwrap(c.bundleIdentifier) || '';
      } catch (e) {}
      var art = '';
      if (argv.length > 0 && argv[0] === 'art') {
        var d = info.valueForKey('kMRMediaRemoteNowPlayingInfoArtworkData');
        if (d && !d.isNil()) art = ObjC.unwrap(d.base64EncodedStringWithOptions(0));
      }
      var ts = get('kMRMediaRemoteNowPlayingInfoTimestamp');
      var playing = false;
      try { playing = !!ObjC.unwrap(R.localIsPlaying); } catch (e) {
        playing = (get('kMRMediaRemoteNowPlayingInfoPlaybackRate') || 0) > 0;
      }
      return JSON.stringify({
        title: get('kMRMediaRemoteNowPlayingInfoTitle') || '',
        artist: get('kMRMediaRemoteNowPlayingInfoArtist') || '',
        album: get('kMRMediaRemoteNowPlayingInfoAlbum') || '',
        duration: get('kMRMediaRemoteNowPlayingInfoDuration') || 0,
        elapsed: get('kMRMediaRemoteNowPlayingInfoElapsedTime') || 0,
        rate: get('kMRMediaRemoteNowPlayingInfoPlaybackRate') || 0,
        timestamp: (ts && ts.getTime) ? ts.getTime() / 1000 : 0,
        playing: playing, app: app, bundleID: bid, artwork: art
      });
    }
    """

    private static let commandScript = """
    ObjC.import('Foundation');
    function run(argv) {
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
      if (argv[0] === 'seek') {
        ObjC.bindFunction('MRMediaRemoteSetElapsedTime', ['void', ['double']]);
        $.MRMediaRemoteSetElapsedTime(parseFloat(argv[1]));
      } else {
        ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
        $.MRMediaRemoteSendCommand(parseInt(argv[0]), $.NSDictionary.dictionary);
      }
      return '';
    }
    """

    /// Runs `osascript -l JavaScript` and returns trimmed stdout, or nil on failure / timeout.
    private static func runJXA(_ script: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script] + arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Never let a stuck osascript block polling.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
