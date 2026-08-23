import KeyboardShortcuts
import Foundation

enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum NotchStatusPlacement: String, CaseIterable {
    case side
    case below

    static let defaultsKey = "notchStatusPlacement"
    static let defaultValue = NotchStatusPlacement.below

    var label: String {
        switch self {
        case .side: "Side"
        case .below: "Below"
        }
    }

    static func current(defaults: UserDefaults = .standard) -> NotchStatusPlacement {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let placement = NotchStatusPlacement(rawValue: rawValue) else {
            return defaultValue
        }
        return placement
    }
}

extension Notification.Name {
    static let notchStatusPlacementDidChange = Notification.Name(
        "com.st0012.CctopMenubar.notchStatusPlacementDidChange"
    )
}

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel")
    // Storage key is "refocus" (the old name) for backward compatibility with existing user shortcuts.
    static let navigate = Self("refocus", default: .init(.n, modifiers: [.control, .command]))
}

enum FileAccessSettings {
    static let filesAndFoldersURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    static let privacySecurityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
}
