import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class ActionPanelController {
    private let panel: NSPanel
    private let registry = ActionRegistry()
    private let model = ActionBarModel()
    private let hostingView: NSHostingView<ActionBarView>
    private var visibilityGeneration = 0

    init() {
        hostingView = NSHostingView(rootView: ActionBarView(model: model))
        hostingView.wantsLayer = true

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 162, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.contentView = hostingView
        applyPopoverTheme(ClipBarSettings.shared.popoverTheme)
    }

    func applyPopoverTheme(_ theme: PopoverTheme) {
        let appearance = theme.appearance
        panel.appearance = appearance
        hostingView.appearance = appearance
    }

    func show(for context: SelectionContext) {
        // All AppKit work is serialized on the main actor. The stable hosting
        // view avoids replacing NSWindow content during rapid Preview updates.
        visibilityGeneration += 1
        let generation = visibilityGeneration
        cancelAnimations()

        let latencyMS = (CFAbsoluteTimeGetCurrent() - context.detectedAt) * 1000
        Diagnostics.shared.log(.panel, String(format: "Preparing panel after %.1f ms", latencyMS))

        let items = registry.availableItems(for: context) { [weak self] in
            self?.hide()
        }

        guard !items.isEmpty else {
            hide()
            return
        }

        Diagnostics.shared.log(.panel, "Updating action model")
        model.resetPresentation()
        model.actions = items
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize

        guard fittingSize.width.isFinite,
              fittingSize.height.isFinite,
              fittingSize.width > 0,
              fittingSize.height > 0,
              fittingSize.width < 2_000,
              fittingSize.height < 500 else {
            Diagnostics.shared.log(.panel, "Rejected invalid panel size")
            hide()
            return
        }

        guard let targetOrigin = panelOrigin(
            for: context.selection.anchor,
            panelSize: fittingSize
        ) else {
            Diagnostics.shared.log(.panel, "Rejected invalid panel origin")
            hide()
            return
        }

        let targetFrame = NSRect(origin: targetOrigin, size: fittingSize)

        guard isValidPanelFrame(targetFrame) else {
            Diagnostics.shared.log(
                .panel,
                "Rejected invalid panel frame: \(NSStringFromRect(targetFrame))"
            )
            hide()
            return
        }

        if framesAreEffectivelyEqual(panel.frame, targetFrame) {
            Diagnostics.shared.log(.panel, "Panel frame unchanged")
        } else {
            Diagnostics.shared.log(
                .panel,
                "Updating panel frame: \(NSStringFromRect(targetFrame))"
            )
            panel.setFrame(targetFrame, display: false)
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            Diagnostics.shared.log(.panel, "Panel ordered front")
            return
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animateAppearanceScale(on: hostingView)

        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0.13
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            guard let self, generation == self.visibilityGeneration else { return }
            self.panel.alphaValue = 1
            Diagnostics.shared.log(.panel, "Panel presentation completed")
        }
    }

    func hide() {
        model.resetPresentation()
        visibilityGeneration += 1
        let generation = visibilityGeneration
        cancelAnimations()

        guard panel.isVisible else {
            panel.alphaValue = 1
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0.08
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, generation == self.visibilityGeneration else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    private func cancelAnimations() {
        panel.contentView?.layer?.removeAllAnimations()
    }

    private func animateAppearanceScale(on host: NSView) {
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        layer.removeAnimation(forKey: "clipbarAppearanceScale")

        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.97
        animation.toValue = 1.0
        animation.duration = 0.13
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: "clipbarAppearanceScale")
    }

    private func isUsableSelectionRect(_ rect: CGRect) -> Bool {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0,
              rect.width < 100_000,
              rect.height < 100_000 else {
            return false
        }

        return NSScreen.screens.contains { screen in
            screen.frame.insetBy(dx: -500, dy: -500).intersects(rect)
        }
    }

    private func panelOrigin(
        for anchor: SelectionAnchor,
        panelSize: NSSize
    ) -> NSPoint? {
        guard panelSize.width.isFinite,
              panelSize.height.isFinite,
              panelSize.width > 0,
              panelSize.height > 0 else {
            return nil
        }

        let anchorPoint: NSPoint
        let lowerFallbackY: CGFloat?

        switch anchor {
        case .accessibilityBounds(let rect):
            if let appKitRect = appKitRect(fromAccessibilityRect: rect),
               isUsableSelectionRect(appKitRect) {
                anchorPoint = NSPoint(
                    x: appKitRect.midX,
                    y: appKitRect.maxY + 8
                )
                lowerFallbackY = appKitRect.minY - panelSize.height - 8
            } else {
                let cursor = NSEvent.mouseLocation

                Diagnostics.shared.log(
                    .panel,
                    "Invalid accessibility bounds; falling back to cursor position"
                )

                anchorPoint = NSPoint(
                    x: cursor.x,
                    y: cursor.y + 12
                )
                lowerFallbackY = cursor.y - panelSize.height - 12
            }

        case .dragBounds(let rect):
            guard isFiniteRect(rect) else { return nil }

            anchorPoint = NSPoint(
                x: rect.midX,
                y: rect.maxY + 8
            )
            lowerFallbackY = rect.minY - panelSize.height - 8

        case .cursor(let point):
            guard point.x.isFinite, point.y.isFinite else { return nil }

            anchorPoint = NSPoint(
                x: point.x,
                y: point.y + 10
            )
            lowerFallbackY = point.y - panelSize.height - 10
        }

        guard anchorPoint.x.isFinite, anchorPoint.y.isFinite else {
            return nil
        }

        var origin = NSPoint(
            x: anchorPoint.x - panelSize.width / 2,
            y: anchorPoint.y
        )

        let targetScreen = NSScreen.screens.first { $0.frame.contains(anchorPoint) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let visible = targetScreen?.visibleFrame else {
            return origin.x.isFinite && origin.y.isFinite ? origin : nil
        }

        origin.x = min(
            max(origin.x, visible.minX + 4),
            visible.maxX - panelSize.width - 4
        )

        if origin.y + panelSize.height > visible.maxY,
           let lowerFallbackY,
           lowerFallbackY.isFinite {
            origin.y = lowerFallbackY
        }

        origin.y = min(
            max(origin.y, visible.minY + 4),
            visible.maxY - panelSize.height - 4
        )

        guard origin.x.isFinite, origin.y.isFinite else {
            return nil
        }

        return origin
    }

    private func appKitRect(fromAccessibilityRect rect: CGRect) -> CGRect? {
        guard isFiniteRect(rect),
              rect.width < 100_000,
              rect.height < 100_000 else {
            return nil
        }

        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        guard primaryTop.isFinite else { return nil }

        let converted = CGRect(
            x: rect.minX,
            y: primaryTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        guard isFiniteRect(converted) else {
            return nil
        }

        return converted
    }

    private func isFiniteRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width >= 0
            && rect.height >= 0
    }

    private func isValidPanelFrame(_ frame: NSRect) -> Bool {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.size.width.isFinite,
              frame.size.height.isFinite,
              frame.size.width > 0,
              frame.size.height > 0,
              frame.size.width < 2_000,
              frame.size.height < 500 else {
            return false
        }

        return NSScreen.screens.contains { screen in
            screen.frame
                .insetBy(dx: -2_000, dy: -2_000)
                .intersects(frame)
        }
    }

    private func framesAreEffectivelyEqual(
        _ lhs: NSRect,
        _ rhs: NSRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
    }
}
