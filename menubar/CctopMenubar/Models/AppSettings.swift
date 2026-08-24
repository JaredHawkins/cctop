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

enum NotchStatusPlacement: String {
    case side
    case below

    static let defaultValue = NotchStatusPlacement.below
}

enum StatusIndicatorPlacement: String, CaseIterable {
    case side
    case below
    case menuBar = "menu_bar"

    static let defaultsKey = "notchStatusPlacement"
    static let defaultValue = StatusIndicatorPlacement.below

    var label: String {
        switch self {
        case .side: "Side"
        case .below: "Below"
        case .menuBar: "Menu Bar"
        }
    }

    var notchPlacement: NotchStatusPlacement? {
        switch self {
        case .side: .side
        case .below: .below
        case .menuBar: nil
        }
    }

    static func current(defaults: UserDefaults = .standard) -> StatusIndicatorPlacement {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let placement = StatusIndicatorPlacement(rawValue: rawValue) else {
            return defaultValue
        }
        return placement
    }
}

extension Notification.Name {
    static let statusIndicatorPlacementDidChange = Notification.Name(
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
