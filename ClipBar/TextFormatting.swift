import AppKit
import ApplicationServices

enum TextFormattingCommand: String, CaseIterable {
    case bold
    case italic
    case underline

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        }
    }

    var symbol: String { rawValue }

    var keyEquivalent: String {
        switch self {
        case .bold: return "b"
        case .italic: return "i"
        case .underline: return "u"
        }
    }

    var virtualKeyCode: CGKeyCode {
        switch self {
        case .bold: return 11
        case .italic: return 34
        case .underline: return 32
        }
    }
}

final class TextFormattingController {
    static let shared = TextFormattingController()

    private struct AvailabilityCache {
        let pid: pid_t
        let createdAt: CFAbsoluteTime
        let commands: Set<TextFormattingCommand>
    }

    private var cache: AvailabilityCache?
    private let cacheLifetime: CFTimeInterval = 0.5
    private let standardShortcutApplicationIDs: Set<String> = [
        "com.microsoft.Word",
        "com.microsoft.Powerpoint",
        "com.redlex.mellel6"
    ]

    private init() {}

    func isAvailable(_ command: TextFormattingCommand, in pid: pid_t) -> Bool {
        availableCommands(in: pid).contains(command)
    }

    @discardableResult
    func perform(_ command: TextFormattingCommand, in pid: pid_t) -> Bool {
        cache = nil

        guard let application = NSRunningApplication(processIdentifier: pid),
              !application.isTerminated else {
            Diagnostics.shared.log(
                .selection,
                "Formatting \(command.rawValue) rejected; source application is unavailable"
            )
            return false
        }

        if usesStandardFormattingShortcuts(application) {
            return postStandardShortcut(command, to: pid)
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        guard let menuBar = copyElementAttribute(
            kAXMenuBarAttribute as CFString,
            from: applicationElement
        ),
        let menuItem = matchingMenuItem(
            for: command,
            in: menuBar,
            requireEnabled: true
        ) else {
            Diagnostics.shared.log(
                .selection,
                "Formatting \(command.rawValue) rejected; enabled native command not found"
            )
            return false
        }

        let result = AXUIElementPerformAction(
            menuItem,
            kAXPressAction as CFString
        )
        Diagnostics.shared.log(
            .selection,
            "Formatting \(command.rawValue) native command result=\(result.rawValue) pid=\(pid)"
        )
        return result == .success
    }

    private func availableCommands(in pid: pid_t) -> Set<TextFormattingCommand> {
        let now = CFAbsoluteTimeGetCurrent()
        if let cache,
           cache.pid == pid,
           now - cache.createdAt <= cacheLifetime {
            return cache.commands
        }

        guard let application = NSRunningApplication(processIdentifier: pid),
              !application.isTerminated else {
            return []
        }

        if usesStandardFormattingShortcuts(application) {
            let commands = Set(TextFormattingCommand.allCases)
            cache = AvailabilityCache(pid: pid, createdAt: now, commands: commands)
            Diagnostics.shared.log(
                .selection,
                "Formatting availability pid=\(pid) commands=bold,italic,underline source=trusted-standard-shortcuts"
            )
            return commands
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        guard let menuBar = copyElementAttribute(
            kAXMenuBarAttribute as CFString,
            from: applicationElement
        ) else {
            Diagnostics.shared.log(
                .selection,
                "Formatting availability unavailable; menu bar not exposed for pid=\(pid)"
            )
            return []
        }

        let scanStartedAt = CFAbsoluteTimeGetCurrent()
        let commands = availableFormattingCommands(in: menuBar)
        cache = AvailabilityCache(pid: pid, createdAt: now, commands: commands)

        let elapsedMS = (CFAbsoluteTimeGetCurrent() - scanStartedAt) * 1_000
        Diagnostics.shared.log(
            .selection,
            String(
                format: "Formatting availability pid=%d commands=%@ scan=%.1fms",
                pid,
                commands.map(\.rawValue).sorted().joined(separator: ","),
                elapsedMS
            )
        )
        return commands
    }

    private func usesStandardFormattingShortcuts(
        _ application: NSRunningApplication
    ) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else {
            return false
        }
        return standardShortcutApplicationIDs.contains(bundleIdentifier)
    }

    private func postStandardShortcut(
        _ command: TextFormattingCommand,
        to pid: pid_t
    ) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: command.virtualKeyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: command.virtualKeyCode,
                  keyDown: false
              ) else {
            Diagnostics.shared.log(
                .selection,
                "Formatting \(command.rawValue) rejected; shortcut event creation failed"
            )
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        Diagnostics.shared.log(
            .selection,
            "Formatting \(command.rawValue) posted trusted standard shortcut pid=\(pid)"
        )
        return true
    }

    private func availableFormattingCommands(
        in root: AXUIElement
    ) -> Set<TextFormattingCommand> {
        var commands = Set<TextFormattingCommand>()
        var pending: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0

        while index < pending.count,
              commands.count < TextFormattingCommand.allCases.count {
            let current = pending[index]
            index += 1
            guard current.depth <= 8 else { continue }

            if copyStringAttribute(
                kAXRoleAttribute as CFString,
                from: current.element
            ) == (kAXMenuItemRole as String),
            let command = formattingCommand(for: current.element),
            isEnabled(current.element) {
                commands.insert(command)
            }

            pending.append(contentsOf: copyChildren(from: current.element).map {
                ($0, current.depth + 1)
            })
        }

        return commands
    }

    private func matchingMenuItem(
        for command: TextFormattingCommand,
        in root: AXUIElement,
        requireEnabled: Bool
    ) -> AXUIElement? {
        var pending: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0

        while index < pending.count {
            let current = pending[index]
            index += 1
            guard current.depth <= 8 else { continue }

            if copyStringAttribute(
                kAXRoleAttribute as CFString,
                from: current.element
            ) == (kAXMenuItemRole as String),
            formattingCommand(for: current.element) == command,
            (!requireEnabled || isEnabled(current.element)) {
                return current.element
            }

            pending.append(contentsOf: copyChildren(from: current.element).map {
                ($0, current.depth + 1)
            })
        }

        return nil
    }

    private func formattingCommand(
        for element: AXUIElement
    ) -> TextFormattingCommand? {
        guard let keyEquivalent = copyStringAttribute(
            kAXMenuItemCmdCharAttribute as CFString,
            from: element
        )?.lowercased(),
        let command = TextFormattingCommand.allCases.first(where: {
            $0.keyEquivalent == keyEquivalent
        }),
        hasCommandOnlyModifiers(element),
        hasFormattingSemantics(element, for: command) else {
            return nil
        }
        return command
    }

    private func hasFormattingSemantics(
        _ element: AXUIElement,
        for command: TextFormattingCommand
    ) -> Bool {
        let title = normalizedSemanticValue(
            copyStringAttribute(kAXTitleAttribute as CFString, from: element)
        )
        let identifier = normalizedSemanticValue(
            copyStringAttribute(kAXIdentifierAttribute as CFString, from: element)
        )

        let acceptedTitles: Set<String>
        let identifierTokens: [String]
        switch command {
        case .bold:
            acceptedTitles = [
                "bold", "boldface", "fett", "fettdruck",
                "strong"
            ]
            identifierTokens = ["bold"]
        case .italic:
            acceptedTitles = [
                "italic", "italics", "kursiv",
                "emphasis"
            ]
            identifierTokens = ["italic"]
        case .underline:
            acceptedTitles = ["underline", "underlined", "unterstreichen", "unterstrichen"]
            identifierTokens = ["underline"]
        }

        return acceptedTitles.contains(title)
            || identifierTokens.contains(where: identifier.contains)
    }

    private func normalizedSemanticValue(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "")
            .lowercased()
    }

    private func hasCommandOnlyModifiers(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXMenuItemCmdModifiersAttribute as CFString,
            &value
        )

        // Command is implicit in this Accessibility attribute. A value of zero
        // means there are no additional Shift, Option, Control, or NoCommand flags.
        guard result == .success else { return true }
        return (value as? NSNumber)?.intValue == 0
    }

    private func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &value
        ) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue == true
    }

    private func copyChildren(from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func copyElementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyStringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
