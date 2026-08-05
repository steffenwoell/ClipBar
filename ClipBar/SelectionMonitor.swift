import AppKit
import ApplicationServices
import CoreGraphics

final class SelectionMonitor {
    var onSelection: ((SelectionContext) -> Void)?
    var onClear: (() -> Void)?

    private let reader = SelectionReader()
    private var mouseUpMonitor: Any?
    private var mouseDownMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var keyEventTap: CFMachPort?
    private var keyEventTapSource: CFRunLoopSource?
    private var workItem: DispatchWorkItem?
    private var requestID = 0
    private var mouseDownLocation: NSPoint?
    private var mouseDownWindowFrame: CGRect?
    private var mouseDownApplicationPID: pid_t?

    private let retryDelays: [TimeInterval] = [
        0.05,
        0.12
    ]

    private let selectionDelay: TimeInterval = 0.12

    func start() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }

            let isLeftMouseDown = event.type == .leftMouseDown
            let location = event.locationInWindow
            let pointedPID = isLeftMouseDown
                ? self.processIdentifier(atAppKitPoint: location)
                : nil
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

            self.mouseDownLocation = isLeftMouseDown ? location : nil
            self.mouseDownWindowFrame = isLeftMouseDown ? self.frontmostWindowFrame() : nil
            self.mouseDownApplicationPID = isLeftMouseDown
                ? pointedPID ?? frontmostPID
                : nil

            if isLeftMouseDown {
                Diagnostics.shared.log(
                    .selection,
                    "Mouse down source pointedPID=\(Self.pidDescription(pointedPID)) frontmostPID=\(Self.pidDescription(frontmostPID)) selectedPID=\(Self.pidDescription(self.mouseDownApplicationPID))"
                )
            }
            self.reader.cancelPendingClipboardRead()
            self.invalidatePendingSelection()
            self.onClear?()
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.readSelectionAfterMouseUp(event)
        }

        installKeyboardEventTap()

        // Keep NSEvent monitors as a fallback when macOS refuses the event tap.
        if keyEventTap == nil {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard !Self.isInternalCopyEvent(event) else { return }
                self?.handleKeyboardInput(event)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard !Self.isInternalCopyEvent(event) else { return event }
            self?.handleKeyboardInput(event)
            return event
        }
    }

    func stop() {
        [mouseDownMonitor, mouseUpMonitor, globalKeyMonitor, localKeyMonitor]
            .compactMap { $0 }
            .forEach(NSEvent.removeMonitor)

        mouseDownMonitor = nil
        mouseUpMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil

        if let source = keyEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = keyEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        keyEventTapSource = nil
        keyEventTap = nil

        reader.cancelPendingClipboardRead()
        invalidatePendingSelection()
    }

    private func installKeyboardEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard type == .keyDown,
                  let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            if event.getIntegerValueField(.eventSourceUserData) == ClipBarSyntheticEventMarker.copy {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<SelectionMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            monitor.handleKeyboardCGEvent(event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Diagnostics.shared.log(.selection, "Keyboard event tap unavailable; using NSEvent fallback")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        keyEventTap = tap
        keyEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleKeyboardCGEvent(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isCommandC = event.flags.contains(.maskCommand) && keyCode == 8
        handleKeyboardInput(isUserCopy: isCommandC)
    }

    private func handleKeyboardInput(_ event: NSEvent? = nil) {
        let isUserCopy = event?.modifierFlags.contains(.command) == true
            && event?.keyCode == 8
        handleKeyboardInput(isUserCopy: isUserCopy)
    }

    private func handleKeyboardInput(isUserCopy: Bool) {
        if isUserCopy {
            reader.userDidRequestCopy()
        } else {
            reader.cancelPendingClipboardRead()
        }
        invalidatePendingSelection()
        onClear?()
    }

    private static func isInternalCopyEvent(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            == ClipBarSyntheticEventMarker.copy
    }

    private func invalidatePendingSelection() {
        requestID += 1
        workItem?.cancel()
        workItem = nil
    }

    private func frontmostWindowFrame() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == Int(pid),
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                continue
            }

            return rect
        }

        return nil
    }

    private func windowFrameChanged(from oldFrame: CGRect?, to newFrame: CGRect?) -> Bool {
        guard let oldFrame, let newFrame else { return false }
        let tolerance: CGFloat = 1
        return abs(oldFrame.minX - newFrame.minX) > tolerance
            || abs(oldFrame.minY - newFrame.minY) > tolerance
            || abs(oldFrame.width - newFrame.width) > tolerance
            || abs(oldFrame.height - newFrame.height) > tolerance
    }

    private func readSelectionAfterMouseUp(_ event: NSEvent) {
        let start = mouseDownLocation
        let initialWindowFrame = mouseDownWindowFrame
        let initialApplicationPID = mouseDownApplicationPID
        mouseDownLocation = nil
        mouseDownWindowFrame = nil
        mouseDownApplicationPID = nil
        let end = event.locationInWindow
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let pointedApplicationPID = processIdentifier(atAppKitPoint: end)
        let finalApplicationPID = pointedApplicationPID
            ?? frontmostApplication?.processIdentifier
        let bundleIdentifier = initialApplicationPID.flatMap {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        } ?? frontmostApplication?.bundleIdentifier
        let selectionStartedAt = CFAbsoluteTimeGetCurrent()

        Diagnostics.shared.log(
            .selection,
            "Mouse up source pointedPID=\(Self.pidDescription(pointedApplicationPID)) frontmostPID=\(Self.pidDescription(frontmostApplication?.processIdentifier)) selectedPID=\(Self.pidDescription(finalApplicationPID)) bundle=\(bundleIdentifier ?? "unknown")"
        )

        // A drag that starts in one process and ends in another is application
        // drag and drop, not text selection. Without this check, dropping a
        // Finder item into an editor can reuse that editor's old AX selection.
        guard let initialApplicationPID,
              initialApplicationPID == finalApplicationPID else {
            Diagnostics.shared.log(
                .selection,
                "Rejected cross-application drag or incomplete mouse gesture"
            )
            onClear?()
            return
        }

        guard !SelectionPolicy.excludesApplication(bundleIdentifier) else {
            onClear?()
            return
        }

        let distance: CGFloat
        if let start {
            distance = hypot(end.x - start.x, end.y - start.y)
        } else {
            distance = 0
        }

        let draggedFarEnough = distance >= 4
        let finalWindowFrame = frontmostWindowFrame()
        let windowGeometryChanged = windowFrameChanged(
            from: initialWindowFrame,
            to: finalWindowFrame
        )
        let selectionGesture = (draggedFarEnough || event.clickCount >= 2)
            && !windowGeometryChanged

        guard selectionGesture else {
            onClear?()
            return
        }

        let allowClipboardFallback = SelectionPolicy.allowsClipboardFallback(
            in: bundleIdentifier
        )

        let dragRect: CGRect?
        if let start, draggedFarEnough {
            dragRect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 1),
                height: max(abs(end.y - start.y), 1)
            )
        } else {
            dragRect = nil
        }

        invalidatePendingSelection()
        let currentRequest = requestID

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }

            self.attemptSelection(
                requestID: currentRequest,
                attempt: 0,
                allowClipboardFallback: allowClipboardFallback,
                bundleIdentifier: bundleIdentifier,
                originatingApplicationPID: initialApplicationPID,
                mouseLocation: end,
                dragRect: dragRect,
                detectedAt: selectionStartedAt
            )
        }

        workItem = item

        DispatchQueue.main.asyncAfter(
            deadline: .now() + selectionDelay,
            execute: item
        )
    }

    private func processIdentifier(atAppKitPoint point: NSPoint) -> pid_t? {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?

        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(primaryTop - point.y),
            &element
        ) == .success,
        let element else {
            return nil
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return pid
    }

    private static func pidDescription(_ pid: pid_t?) -> String {
        pid.map(String.init) ?? "unavailable"
    }

    private func attemptSelection(
        requestID: Int,
        attempt: Int,
        allowClipboardFallback: Bool,
        bundleIdentifier: String?,
        originatingApplicationPID: pid_t,
        mouseLocation: CGPoint,
        dragRect: CGRect?,
        detectedAt: CFAbsoluteTime
    ) {
        reader.currentSelection(
            allowClipboardFallback: allowClipboardFallback,
            bundleIdentifier: bundleIdentifier,
            originatingApplicationPID: originatingApplicationPID,
            mouseLocation: mouseLocation,
            dragRect: dragRect
        ) { [weak self] selection in
            guard let self else { return }
            guard requestID == self.requestID else { return }

            if let selection {
                let elapsed =
                    (CFAbsoluteTimeGetCurrent() - detectedAt) * 1000

                Diagnostics.shared.log(
                    .selection,
                    String(
                        format: "Detected %@ selection (%d chars) after %.1f ms (attempt %d) in %@",
                        String(describing: selection.source),
                        selection.text.count,
                        elapsed,
                        attempt + 1,
                        bundleIdentifier ?? "unknown"
                    )
                )

                self.onSelection?(
                    SelectionContext(
                        selection: selection,
                        bundleIdentifier: bundleIdentifier,
                        applicationPID: originatingApplicationPID,
                        detectedAt: detectedAt
                    )
                )

                return
            }

            let finderDragWasRejected =
                bundleIdentifier == "com.apple.finder" && dragRect != nil

            guard !finderDragWasRejected,
                  attempt < self.retryDelays.count else {
                Diagnostics.shared.log(
                    .selection,
                    finderDragWasRejected
                        ? "Finder drag produced no text selection; retries suppressed"
                        : "Selection retries exhausted in \(bundleIdentifier ?? "unknown")"
                )

                self.onClear?()
                return
            }

            let delay = self.retryDelays[attempt]

            Diagnostics.shared.log(
                .selection,
                "Retrying selection in \(Int(delay * 1000)) ms"
            )

            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay
            ) { [weak self] in
                guard let self else { return }
                guard requestID == self.requestID else { return }

                self.attemptSelection(
                    requestID: requestID,
                    attempt: attempt + 1,
                    allowClipboardFallback: allowClipboardFallback,
                    bundleIdentifier: bundleIdentifier,
                    originatingApplicationPID: originatingApplicationPID,
                    mouseLocation: mouseLocation,
                    dragRect: dragRect,
                    detectedAt: detectedAt
                )
            }
        }
    }
}
