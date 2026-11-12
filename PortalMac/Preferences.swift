import Foundation

enum EdgeEffect: String, CaseIterable, Identifiable {
    case rainbow, portal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rainbow: return "Rainbow"
        case .portal: return "Portal"
        }
    }
}

/// UserDefaults keys shared by @AppStorage in SettingsView and the AppKit controllers.
enum Prefs {
    static let sendZoneWidth = "sendZoneWidth"
    static let effect = "edgeEffect"
    static let showOnThisMac = "showOnThisMac"
    static let pairingCode = "pairingCode"
    static let nowPlayingHandleKey = "nowPlayingHandle"
    static let fetchLyricsKey = "fetchLyrics"
    static let dynamicIslandKey = "dynamicIsland"
    static let screensaverKey = "nowPlayingScreensaver"
    static let screensaverMinutesKey = "nowPlayingScreensaverMinutes"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            sendZoneWidth: 12.0,
            effect: EdgeEffect.rainbow.rawValue,
            showOnThisMac: true,
            nowPlayingHandleKey: true,
            fetchLyricsKey: true,
            dynamicIslandKey: true,
            screensaverKey: true,
            screensaverMinutesKey: 2.0,
        ])
    }

    static var sendZone: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: sendZoneWidth))
    }
    static var currentEffect: EdgeEffect {
        EdgeEffect(rawValue: UserDefaults.standard.string(forKey: effect) ?? "") ?? .rainbow
    }
    static var showEffects: Bool {
        UserDefaults.standard.bool(forKey: showOnThisMac)
    }
    static var nowPlayingHandle: Bool {
        UserDefaults.standard.bool(forKey: nowPlayingHandleKey)
    }
    static var fetchLyrics: Bool {
        UserDefaults.standard.bool(forKey: fetchLyricsKey)
    }
    static var dynamicIsland: Bool {
        UserDefaults.standard.bool(forKey: dynamicIslandKey)
    }
    static var screensaver: Bool {
        UserDefaults.standard.bool(forKey: screensaverKey)
    }
    static var screensaverMinutes: Double {
        max(0.5, UserDefaults.standard.double(forKey: screensaverMinutesKey))
    }
}
