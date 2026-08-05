import AppKit
import ApplicationServices

final class SelectionReplacementController {
    static let shared = SelectionReplacementController()

    private let trustedPasteApplications: Set<String> = [
        "com.apple.Pages",
        "com.apple.iWork.Pages",
        "com.apple.TextEdit",
        "com.apple.mail",
        "com.apple.Notes",
        "com.microsoft.Word",
        "com.microsoft.Powerpoint",
        "com.redlex.mellel6",
        "com.ulyssesapp.mac",
        "com.iconfactory.Tot"
    ]

    private init() {}

    func replaceOrCopy(_ replacement: String, in context: SelectionContext) {
        guard !replacement.isEmpty,
              let application = NSRunningApplication(
                  processIdentifier: context.applicationPID
              ),
              !application.isTerminated else {
            Actions.copy(replacement)
            return
        }

        if replaceThroughAccessibility(replacement, pid: context.applicationPID) {
            Diagnostics.shared.log(.selection, "Thesaurus replaced selection through Accessibility")
            return
        }

        if let bundleIdentifier = context.bundleIdentifier,
           trustedPasteApplications.contains(bundleIdentifier),
           paste(replacement, to: context.applicationPID) {
            Diagnostics.shared.log(.selection, "Thesaurus replaced selection through trusted paste")
            return
        }

        Actions.copy(replacement)
        Diagnostics.shared.log(.selection, "Thesaurus copied suggestion for non-editable selection")
    }

    private func replaceThroughAccessibility(_ replacement: String, pid: pid_t) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return false
        }

        var element: AXUIElement? = (value as! AXUIElement)
        for _ in 0..<12 {
            guard let current = element else { break }
            var currentPID: pid_t = 0
            guard AXUIElementGetPid(current, &currentPID) == .success,
                  currentPID == pid else {
                return false
            }

            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(
                current,
                kAXSelectedTextAttribute as CFString,
                &settable
            ) == .success,
            settable.boolValue,
            AXUIElementSetAttributeValue(
                current,
                kAXSelectedTextAttribute as CFString,
                replacement as CFString
            ) == .success {
                return true
            }

            element = copyElementAttribute(kAXParentAttribute as CFString, from: current)
        }
        return false
    }

    private func paste(_ replacement: String, to pid: pid_t) -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(replacement, forType: .string) else {
            snapshot.restore(to: pasteboard)
            return false
        }
        let temporaryChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            snapshot.restore(to: pasteboard)
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if pasteboard.changeCount == temporaryChangeCount {
                snapshot.restore(to: pasteboard)
            }
        }
        return true
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
}
