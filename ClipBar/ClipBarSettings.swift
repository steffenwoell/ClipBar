import AppKit
import Foundation

enum PopoverTheme: String, CaseIterable, Codable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}

final class ClipBarSettings {
    static let shared = ClipBarSettings()

    private(set) var popoverTheme: PopoverTheme = .system
    private(set) var recoverAfterCrashes = false

    private init() {}

    func reload() {
        guard let data = try? Data(contentsOf: ClipBarPaths.settings),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            popoverTheme = .system
            recoverAfterCrashes = false
            return
        }

        if let rawTheme = dictionary["popoverTheme"] as? String,
           let theme = PopoverTheme(rawValue: rawTheme) {
            popoverTheme = theme
        } else {
            popoverTheme = .system
        }
        recoverAfterCrashes = dictionary["recoverAfterCrashes"] as? Bool ?? false
    }

    func setRecoverAfterCrashes(_ enabled: Bool) throws {
        var dictionary: [String: Any] = [:]

        if let data = try? Data(contentsOf: ClipBarPaths.settings),
           let object = try? JSONSerialization.jsonObject(with: data),
           let existing = object as? [String: Any] {
            dictionary = existing
        }

        dictionary["recoverAfterCrashes"] = enabled
        let data = try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: ClipBarPaths.settings, options: .atomic)
        recoverAfterCrashes = enabled
    }

    func setPopoverTheme(_ theme: PopoverTheme) throws {
        var dictionary: [String: Any] = [:]

        if let data = try? Data(contentsOf: ClipBarPaths.settings),
           let object = try? JSONSerialization.jsonObject(with: data),
           let existing = object as? [String: Any] {
            dictionary = existing
        }

        dictionary["popoverTheme"] = theme.rawValue
        let data = try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: ClipBarPaths.settings, options: .atomic)
        popoverTheme = theme
    }
}
