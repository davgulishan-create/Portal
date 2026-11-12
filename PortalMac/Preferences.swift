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

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            sendZoneWidth: 12.0,
            effect: EdgeEffect.rainbow.rawValue,
            showOnThisMac: true,
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
}
