import AppKit
import ApplicationServices

final class SelectionReader {
    private let secureFieldDetector = SecureFieldDetector()
    private let clipboardEngine = ClipboardSelectionEngine()

    func userDidRequestCopy() {
        clipboardEngine.userDidRequestCopy()
    }

    func cancelPendingClipboardRead() {
        clipboardEngine.cancel()
    }

    func currentSelection(
        allowClipboardFallback: Bool,
        bundleIdentifier: String?,
        originatingApplicationPID: pid_t,
        mouseLocation: NSPoint,
        dragRect: CGRect?,
        completion: @escaping (Selection?) -> Void
    ) {
        Diagnostics.shared.log(.selection, "AX hit test started")
        let systemWide = AXUIElementCreateSystemWide()
        let focused = copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: systemWide)
        let pointed = element(atAppKitPoint: mouseLocation)
        Diagnostics.shared.log(.selection, "AX hit test completed")

        if isPagesApplication(bundleIdentifier),
           Diagnostics.shared.selectionLoggingEnabled {
            logPagesAccessibilitySnapshot(
                focused: focused,
                pointed: pointed,
                mouseLocation: mouseLocation,
                dragRect: dragRect
            )
        }

        // NSWorkspace can briefly continue reporting the source application
        // while a cross-application drop completes. Verify the actual AX
        // element under the pointer as a second, independent drag guard.
        if let pointed {
            var pointedPID: pid_t = 0
            if AXUIElementGetPid(pointed, &pointedPID) == .success,
               pointedPID != originatingApplicationPID {
                Diagnostics.shared.log(
                    .selection,
                    "Rejected selection target belonging to another process"
                )
                completion(nil)
                return
            }
        }

        // Never invoke the clipboard fallback from a secure field. Check both
        // the focused element and the element underneath the pointer.
        guard !secureFieldDetector.isSecure(focused),
              !secureFieldDetector.isSecure(pointed) else {
            completion(nil)
            return
        }

        // A double-click or drag can also target menu items, table rows,
        // splitters, image handles, and other controls. Only continue when the
        // element under the pointer belongs to a text-selection hierarchy.
        // This also prevents stale AXSelectedText from a previously focused
        // editor from reopening ClipBar after an unrelated gesture.
        let pointedIsTextual = isTextSelectionTarget(pointed)
        let focusedIsTextual = pointed == nil && isTextSelectionTarget(focused)
        let allowsRichWebFallback = isRichWebApplication(bundleIdentifier)
            && !isExplicitlyNonTextControl(pointed)

        let clipboardFallbackForNonTextApps: Set<String> = [
            "com.microsoft.Powerpoint",
            "com.apple.Preview",
            "com.apple.Pages",
            "com.apple.iWork.Pages",
            "com.iconfactory.Tot"
        ]

        let allowsClipboardFallbackForNonText =
            clipboardFallbackForNonTextApps.contains(bundleIdentifier ?? "")

        guard pointedIsTextual
            || focusedIsTextual
            || allowsRichWebFallback
            || allowsClipboardFallbackForNonText else {

            Diagnostics.shared.log(
                .selection,
                "Rejected non-text selection target in \(bundleIdentifier ?? "unknown")"
            )
            completion(nil)
            return
        }

        if allowsClipboardFallbackForNonText
            && !(pointedIsTextual || focusedIsTextual) {

            Diagnostics.shared.log(
                .selection,
                "Non-text AX target; continuing with clipboard fallback in \(bundleIdentifier ?? "unknown")"
            )
        }

        // The pointed element is authoritative for mouse-driven selection.
        // Its parent chain already reaches the relevant text container. Only
        // consult the focused element when hit testing returned no element;
        // otherwise an older selection in a different control could leak in.
        let shouldAttemptAccessibilitySelection =
            pointedIsTextual || focusedIsTextual || allowsRichWebFallback

        if shouldAttemptAccessibilitySelection,
           let selection = accessibilitySelection(
               from: pointed,
               mouseLocation: mouseLocation,
               dragRect: dragRect
           ) ?? (pointed == nil
               ? accessibilitySelection(
                   from: focused,
                   mouseLocation: mouseLocation,
                   dragRect: dragRect
               )
               : nil) {
            Diagnostics.shared.log(.selection, "Accessibility selection validated")
            completion(selection)
            return
        }

        // For ordinary applications, a synthetic copy is safe only after the
        // pointer hierarchy has been validated as textual. Dedicated fallback
        // applications retain their compatibility path. This prevents a
        // double-clicked UI row from copying its label and opening ClipBar.
        // Finder's file clipboard contains private, lazily supplied metadata
        // used by Paste and "Move Item Here". A synthetic Command-C followed
        // by snapshot restoration can strip that metadata and make Command-V
        // appear to do nothing. Finder must therefore never enter the
        // clipboard fallback, even if a future compatibility rule accidentally
        // classifies one of its controls as textual.
        let isFinder = bundleIdentifier == "com.apple.finder"
        let shouldUseClipboardFallback = !isFinder && (
            allowsClipboardFallbackForNonText
            || (allowClipboardFallback && (pointedIsTextual || focusedIsTextual || allowsRichWebFallback))
        )

        guard shouldUseClipboardFallback else {
            completion(nil)
            return
        }

        clipboardSelection(
            anchor: dragRect.map(SelectionAnchor.dragBounds)
                ?? .cursor(mouseLocation),
            completion: completion
        )
    }



    private func isRichWebApplication(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.openai.chat"
            || bundleIdentifier == "com.openai.ChatGPT"
            || bundleIdentifier.hasPrefix("com.openai.chat")
    }

    private func isPagesApplication(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.Pages"
            || bundleIdentifier == "com.apple.iWork.Pages"
    }

    private func isExplicitlyNonTextControl(_ element: AXUIElement?) -> Bool {
        guard let element,
              let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element) else {
            return false
        }

        return [
            "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem",
            "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
            "AXSlider", "AXSplitter", "AXToolbar", "AXImage",
            "AXRow", "AXCell"
        ].contains(role)
    }

    private func isTextSelectionTarget(_ startingElement: AXUIElement?) -> Bool {
        var element = startingElement

        let directTextRoles: Set<String> = [
            "AXTextField",
            "AXTextArea",
            "AXWebArea",
            "AXDocument",
            "AXComboBox",
            "AXLink"
        ]

        // These elements represent actions or structural UI rather than text
        // selection. Stop immediately instead of walking up to a broad parent
        // such as AXWindow or AXWebArea and producing a false positive.
        let blockingRoles: Set<String> = [
            "AXMenuBar",
            "AXMenuBarItem",
            "AXMenu",
            "AXMenuItem",
            "AXButton",
            "AXCheckBox",
            "AXRadioButton",
            "AXPopUpButton",
            "AXSlider",
            "AXSplitter",
            "AXToolbar",
            "AXImage",
            "AXTable",
            "AXOutline",
            "AXList",
            "AXRow",
            "AXCell"
        ]

        var foundTextCandidate = false

        for _ in 0..<10 {
            guard let current = element else { break }
            let role = copyStringAttribute(kAXRoleAttribute as CFString, from: current)

            if let role, directTextRoles.contains(role) {
                foundTextCandidate = true
            }

            if let role, blockingRoles.contains(role) {
                return false
            }

            if supportsTextSelectionAttributes(current) {
                foundTextCandidate = true
            }

            element = copyElementAttribute(kAXParentAttribute as CFString, from: current)
        }

        return foundTextCandidate
    }

    private func supportsTextSelectionAttributes(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let attributes = names as? [String] else {
            return false
        }

        return attributes.contains(kAXSelectedTextAttribute as String)
            || attributes.contains(kAXSelectedTextRangeAttribute as String)
    }

    private func accessibilitySelection(
        from startingElement: AXUIElement?,
        mouseLocation: NSPoint,
        dragRect: CGRect?
    ) -> Selection? {
        var element = startingElement

        // Some applications expose AXSelectedText and AXBoundsForRange on
        // different levels of their accessibility hierarchy.
        for _ in 0..<10 {
            guard let current = element else { break }

            if let selectedText = copyStringAttribute(kAXSelectedTextAttribute as CFString, from: current)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !selectedText.isEmpty {
                let anchor: SelectionAnchor

                if let bounds = selectedTextBounds(for: current), !bounds.isEmpty {
                    guard selectionBounds(
                        bounds,
                        matchMouseLocation: mouseLocation,
                        dragRect: dragRect
                    ) else {
                        Diagnostics.shared.log(
                            .selection,
                            "Rejected stale accessibility selection outside current gesture"
                        )
                        element = copyElementAttribute(kAXParentAttribute as CFString, from: current)
                        continue
                    }
                    anchor = .accessibilityBounds(bounds)
                } else {
                    anchor = .cursor(NSEvent.mouseLocation)
                }

                return Selection(
                    text: selectedText,
                    anchor: anchor,
                    source: .accessibility
                )
            }

            element = copyElementAttribute(kAXParentAttribute as CFString, from: current)
        }

        return nil
    }

    private func selectionBounds(
        _ accessibilityBounds: CGRect,
        matchMouseLocation mouseLocation: NSPoint,
        dragRect: CGRect?
    ) -> Bool {
        guard accessibilityBounds.origin.x.isFinite,
              accessibilityBounds.origin.y.isFinite,
              accessibilityBounds.width.isFinite,
              accessibilityBounds.height.isFinite,
              accessibilityBounds.width > 0,
              accessibilityBounds.height > 0 else {
            return false
        }

        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let mouseInAccessibilityCoordinates = CGPoint(
            x: mouseLocation.x,
            y: primaryTop - mouseLocation.y
        )
        let tolerance: CGFloat = 10
        let expandedBounds = accessibilityBounds.insetBy(
            dx: -tolerance,
            dy: -tolerance
        )

        if let dragRect {
            let dragInAccessibilityCoordinates = CGRect(
                x: dragRect.minX,
                y: primaryTop - dragRect.maxY,
                width: dragRect.width,
                height: dragRect.height
            )
            return expandedBounds.intersects(dragInAccessibilityCoordinates)
        }

        return expandedBounds.contains(mouseInAccessibilityCoordinates)
    }

    private func clipboardSelection(
        anchor: SelectionAnchor,
        completion: @escaping (Selection?) -> Void
    ) {
        Diagnostics.shared.log(
            .clipboard,
            "Entering clipboard fallback"
        )
        
        clipboardEngine.readSelection(
            anchor: anchor,
            sendCopy: { [weak self] in self?.sendCopyShortcut() ?? false },
            completion: completion
        )
    }

    private func sendCopyShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.setIntegerValueField(
            .eventSourceUserData,
            value: ClipBarSyntheticEventMarker.copy
        )
        keyUp.setIntegerValueField(
            .eventSourceUserData,
            value: ClipBarSyntheticEventMarker.copy
        )
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func element(atAppKitPoint point: NSPoint) -> AXUIElement? {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let axY = primaryTop - point.y
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?

        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(axY),
            &element
        ) == .success else {
            return nil
        }

        return element
    }

    private func selectedTextBounds(for element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )

        guard rangeResult == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )

        guard boundsResult == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    /// Records only Accessibility structure and result metadata. Selected text,
    /// element titles, descriptions, values, and document contents are never
    /// written to the diagnostic log.
    private func logPagesAccessibilitySnapshot(
        focused: AXUIElement?,
        pointed: AXUIElement?,
        mouseLocation: NSPoint,
        dragRect: CGRect?
    ) {
        let gesture = dragRect.map { NSStringFromRect($0) } ?? "double-click"
        Diagnostics.shared.log(
            .selection,
            "Pages AX snapshot mouse=\(NSStringFromPoint(mouseLocation)) gesture=\(gesture)"
        )
        logPagesAccessibilityChain(named: "pointed", from: pointed)

        if let focused, let pointed, CFEqual(focused, pointed) {
            Diagnostics.shared.log(.selection, "Pages AX focused element matches pointed element")
        } else {
            logPagesAccessibilityChain(named: "focused", from: focused)
        }
    }

    private func logPagesAccessibilityChain(
        named name: String,
        from startingElement: AXUIElement?
    ) {
        guard var element = startingElement else {
            Diagnostics.shared.log(.selection, "Pages AX \(name): unavailable")
            return
        }

        for depth in 0..<12 {
            var pid: pid_t = 0
            let pidResult = AXUIElementGetPid(element, &pid)
            let role = accessibilityString(kAXRoleAttribute as CFString, from: element)
            let subrole = accessibilityString(kAXSubroleAttribute as CFString, from: element)
            let selectedText = accessibilitySelectedTextMetadata(from: element)
            let selectedRange = accessibilitySelectedRangeMetadata(from: element)
            let bounds = selectedTextBounds(for: element).map(NSStringFromRect) ?? "unavailable"
            let attributeFlags = accessibilityAttributeFlags(for: element)

            Diagnostics.shared.log(
                .selection,
                "Pages AX \(name)[\(depth)] pid=\(pidResult == .success ? String(pid) : "error:\(pidResult.rawValue)") role=\(role) subrole=\(subrole) selectedText=\(selectedText) selectedRange=\(selectedRange) bounds=\(bounds) attributes=\(attributeFlags)"
            )

            guard let parent = copyElementAttribute(kAXParentAttribute as CFString, from: element) else {
                break
            }
            element = parent
        }
    }

    private func accessibilityString(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return "error:\(result.rawValue)" }
        return (value as? String) ?? "non-string"
    }

    private func accessibilitySelectedTextMetadata(from element: AXUIElement) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard result == .success else { return "error:\(result.rawValue)" }
        guard let text = value as? String else { return "non-string" }
        return "length:\(text.count)"
    }

    private func accessibilitySelectedRangeMetadata(from element: AXUIElement) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard result == .success else { return "error:\(result.rawValue)" }
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return "invalid"
        }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return "invalid"
        }
        return "location:\(range.location),length:\(range.length)"
    }

    private func accessibilityAttributeFlags(for element: AXUIElement) -> String {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let attributes = names as? [String] else {
            return "error:\(result.rawValue)"
        }

        let relevant = [
            kAXSelectedTextAttribute as String,
            kAXSelectedTextRangeAttribute as String,
            kAXValueAttribute as String,
            kAXFocusedAttribute as String,
            kAXEnabledAttribute as String
        ]
        return relevant.filter(attributes.contains).joined(separator: ",")
    }

    private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
