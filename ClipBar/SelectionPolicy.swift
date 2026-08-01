import ApplicationServices
import Foundation

struct SelectionPolicy {
    /// Security-sensitive and system apps that cannot be removed from the exclusion list.
    static let builtInExcludedApplications: Set<String> = [
        "de.steffenwoell.clipbar",
        "com.apple.dock",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc"
    ]

    /// Apps where Accessibility may still work, but synthetic Command-C is unsafe or noisy.
    static let clipboardFallbackExcludedApplications: Set<String> = [
        "de.steffenwoell.clipbar",
        "com.apple.dock",
        "com.apple.finder"
    ]

    static func excludesApplication(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return builtInExcludedApplications.contains(bundleIdentifier)
            || ApplicationBlacklist.shared.contains(bundleIdentifier)
    }

    static func allowsClipboardFallback(in bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        return !excludesApplication(bundleIdentifier)
            && !clipboardFallbackExcludedApplications.contains(bundleIdentifier)
    }
}

struct SecureFieldDetector {
    func isSecure(_ element: AXUIElement?) -> Bool {
        var current = element

        for _ in 0..<8 {
            guard let element = current else { break }
            if subrole(of: element) == "AXSecureTextField" { return true }
            current = copyElementAttribute(kAXParentAttribute as CFString, from: element)
        }
        return false
    }

    private func subrole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
