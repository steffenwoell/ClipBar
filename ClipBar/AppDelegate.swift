import AppKit
import ApplicationServices
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let selectionMonitor = SelectionMonitor()
    private let panelController = ActionPanelController()
    private let pluginManager = PluginManager.shared
    private let settings = ClipBarSettings.shared
    private let crashRecovery = CrashRecoveryManager.shared

    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let pluginMenu = NSMenu()
    private let blacklistMenu = NSMenu()
    private let currentAppsMenu = NSMenu()
    private let settingsMenu = NSMenu()
    private let appearanceMenu = NSMenu()
    private let developerMenu = NSMenu()
    private var launchAtLoginItem: NSMenuItem?
    private var crashRecoveryItem: NSMenuItem?
    private var clipboardLoggingItem: NSMenuItem?
    private var selectionLoggingItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ClipBarPaths.prepare()
        settings.reload()
        crashRecovery.refreshExecutablePathIfNeeded()
        panelController.applyPopoverTheme(settings.popoverTheme)
        ApplicationBlacklist.shared.start()
        installStatusItem()
        requestAccessibilityPermission()

        selectionMonitor.onSelection = { [weak self] context in
            self?.panelController.show(for: context)
        }
        selectionMonitor.onClear = { [weak self] in
            self?.panelController.hide()
        }
        selectionMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        selectionMonitor.stop()
        ApplicationBlacklist.shared.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusMenu {
            settings.reload()
            panelController.applyPopoverTheme(settings.popoverTheme)
            rebuildPluginMenu()
            rebuildCurrentAppsMenu()
            updateLaunchAtLoginItem()
            updateCrashRecoveryItem()
            updateDiagnosticsItems()
            updateAppearanceMenu()
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "ClipBar")
        statusMenu.delegate = self

        let pluginsItem = NSMenuItem(title: "Plugins", action: nil, keyEquivalent: "")
        pluginsItem.submenu = pluginMenu
        statusMenu.addItem(pluginsItem)

        let blacklistItem = NSMenuItem(title: "Blacklist", action: nil, keyEquivalent: "")
        blacklistItem.submenu = blacklistMenu
        statusMenu.addItem(blacklistItem)

        blacklistMenu.addItem(menuItem(title: "Open Blacklist", action: #selector(openBlacklist)))
        let currentAppsItem = NSMenuItem(title: "Current Apps", action: nil, keyEquivalent: "")
        currentAppsItem.submenu = currentAppsMenu
        blacklistMenu.addItem(currentAppsItem)

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu

        let appearanceItem = NSMenuItem(title: "Popover Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        settingsMenu.addItem(appearanceItem)
        rebuildAppearanceMenu()

        settingsMenu.addItem(.separator())
        let recoveryItem = menuItem(title: "Recover After Crashes", action: #selector(toggleCrashRecovery))
        settingsMenu.addItem(recoveryItem)
        crashRecoveryItem = recoveryItem

        settingsMenu.addItem(.separator())
        settingsMenu.addItem(menuItem(title: "Open Configuration Folder", action: #selector(openConfigurationFolder)))
        statusMenu.addItem(settingsItem)

        statusMenu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        statusMenu.addItem(launchItem)
        launchAtLoginItem = launchItem

        statusMenu.addItem(.separator())

        let developerItem = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        developerItem.submenu = developerMenu

        let clipboardItem = menuItem(title: "Log Clipboard Events", action: #selector(toggleClipboardLogging))
        developerMenu.addItem(clipboardItem)
        clipboardLoggingItem = clipboardItem

        let selectionItem = menuItem(title: "Log Selection Events", action: #selector(toggleSelectionLogging))
        developerMenu.addItem(selectionItem)
        selectionLoggingItem = selectionItem

        developerMenu.addItem(.separator())
        developerMenu.addItem(menuItem(title: "Open Logs", action: #selector(openLogs)))
        developerMenu.addItem(menuItem(title: "Export Diagnostic Log…", action: #selector(exportDiagnosticLog)))
        developerMenu.addItem(menuItem(title: "Clear Diagnostic Log", action: #selector(clearDiagnosticLog)))
        statusMenu.addItem(developerItem)

        statusMenu.addItem(.separator())
        statusMenu.addItem(menuItem(title: "About ClipBar…", action: #selector(showAbout)))
        statusMenu.addItem(menuItem(title: "Quit ClipBar", action: #selector(quit), keyEquivalent: "q"))

        rebuildPluginMenu()
        rebuildCurrentAppsMenu()
        updateLaunchAtLoginItem()
        updateCrashRecoveryItem()
        updateDiagnosticsItems()
        updateAppearanceMenu()

        item.menu = statusMenu
        statusItem = item
    }

    private func rebuildPluginMenu() {
        pluginMenu.removeAllItems()

        pluginMenu.addItem(
            builtInPluginMenuItem(
                id: "word-count",
                title: "Word Count",
                symbol: "textformat.123"
            )
        )
        pluginMenu.addItem(
            builtInPluginMenuItem(
                id: "remove-line-breaks",
                title: "Remove Line Breaks",
                symbol: "text.alignleft"
            )
        )

        let caseMenu = NSMenu()
        caseMenu.addItem(
            builtInPluginMenuItem(
                id: "case-converter",
                title: "Enable Case Converter",
                symbol: "textformat"
            )
        )
        caseMenu.addItem(.separator())

        let caseActions: [(id: String, title: String, symbol: String)] = [
            ("case-lowercase", "lowercase", "textformat.size.smaller"),
            ("case-sentence", "Sentence case", "textformat"),
            ("case-title", "Title Case", "textformat.abc"),
            ("case-uppercase", "UPPERCASE", "textformat.size.larger")
        ]

        for action in caseActions.sorted(by: {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }) {
            caseMenu.addItem(
                builtInPluginMenuItem(
                    id: action.id,
                    title: action.title,
                    symbol: action.symbol
                )
            )
        }

        let caseItem = NSMenuItem(title: "Case Converter", action: nil, keyEquivalent: "")
        caseItem.image = NSImage(
            systemSymbolName: "textformat",
            accessibilityDescription: "Case Converter"
        )
        caseItem.submenu = caseMenu
        pluginMenu.addItem(caseItem)

        let formattingMenu = NSMenu()
        formattingMenu.addItem(
            builtInPluginMenuItem(
                id: "text-formatting",
                title: "Enable Formatting",
                symbol: "textformat"
            )
        )
        formattingMenu.addItem(.separator())

        for command in TextFormattingCommand.allCases.sorted(by: {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }) {
            formattingMenu.addItem(
                builtInPluginMenuItem(
                    id: "format-\(command.rawValue)",
                    title: command.title,
                    symbol: command.symbol
                )
            )
        }

        let formattingItem = NSMenuItem(
            title: "Formatting",
            action: nil,
            keyEquivalent: ""
        )
        formattingItem.image = NSImage(
            systemSymbolName: "textformat",
            accessibilityDescription: "Formatting"
        )
        formattingItem.submenu = formattingMenu
        pluginMenu.addItem(formattingItem)

        pluginMenu.addItem(
            builtInPluginMenuItem(
                id: "thesaurus",
                title: "Thesaurus",
                symbol: "text.book.closed"
            )
        )

        if !pluginManager.definitions.isEmpty {
            pluginMenu.addItem(.separator())

            let grouped = Dictionary(grouping: pluginManager.definitions) { $0.group }
            for definition in (grouped[nil] ?? []).sorted(by: pluginMenuSort) {
                pluginMenu.addItem(pluginMenuItem(for: definition))
            }

            let groupIDs = grouped.keys.compactMap { $0 }.sorted { lhs, rhs in
                let lhsDefinition = pluginManager.groupDefinition(for: lhs)
                let rhsDefinition = pluginManager.groupDefinition(for: rhs)
                let lhsPriority = lhsDefinition?.priority ?? grouped[lhs]?.compactMap(\.priority).min() ?? 50
                let rhsPriority = rhsDefinition?.priority ?? grouped[rhs]?.compactMap(\.priority).min() ?? 50
                return lhsPriority == rhsPriority ? lhs < rhs : lhsPriority < rhsPriority
            }

            for groupID in groupIDs {
                guard let definitions = grouped[groupID], !definitions.isEmpty else { continue }
                let explicit = pluginManager.groupDefinition(for: groupID)
                let title = explicit?.title ?? groupID.replacingOccurrences(of: "-", with: " ").capitalized
                let submenu = NSMenu()
                for definition in definitions.sorted(by: pluginMenuSort) {
                    submenu.addItem(pluginMenuItem(for: definition))
                }
                let groupItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                groupItem.submenu = submenu
                if let symbol = explicit?.symbol ?? definitions.compactMap(\.groupSymbol).first {
                    groupItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                }
                pluginMenu.addItem(groupItem)
            }
        }

        if !pluginManager.failedFiles.isEmpty {
            pluginMenu.addItem(.separator())
            let count = pluginManager.failedFiles.count
            let title = count == 1 ? "⚠ 1 Plugin Failed to Load" : "⚠ \(count) Plugins Failed to Load"
            let warning = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            pluginMenu.addItem(warning)
        }

        pluginMenu.addItem(.separator())
        pluginMenu.addItem(menuItem(title: "Reload Plugins", action: #selector(reloadPlugins)))
        pluginMenu.addItem(menuItem(title: "Open Plugins Folder", action: #selector(openPluginsFolder)))
    }

    private func rebuildCurrentAppsMenu() {
        currentAppsMenu.removeAllItems()
        let applications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        if applications.isEmpty {
            let empty = NSMenuItem(title: "No Applications Found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            currentAppsMenu.addItem(empty)
            return
        }

        for application in applications {
            guard let bundleIdentifier = application.bundleIdentifier else { continue }
            let title = application.localizedName ?? bundleIdentifier
            let item = NSMenuItem(title: title, action: #selector(copyBundleIdentifier(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleIdentifier
            item.toolTip = bundleIdentifier
            item.image = application.icon
            currentAppsMenu.addItem(item)
        }
        currentAppsMenu.addItem(.separator())
        let hint = NSMenuItem(title: "Click an app to copy its bundle identifier", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        currentAppsMenu.addItem(hint)
    }

    private func builtInPluginMenuItem(
        id: String,
        title: String,
        symbol: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(togglePlugin(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = id
        item.state = pluginManager.isEnabled(id: id) ? .on : .off
        item.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )
        return item
    }

    private func pluginMenuItem(for definition: ExternalPluginDefinition) -> NSMenuItem {
        let item = NSMenuItem(title: definition.title, action: #selector(togglePlugin(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = definition.id
        item.state = pluginManager.isEnabled(definition) ? .on : .off
        item.image = NSImage(systemSymbolName: definition.symbol, accessibilityDescription: definition.title)
        return item
    }

    private func pluginMenuSort(_ lhs: ExternalPluginDefinition, _ rhs: ExternalPluginDefinition) -> Bool {
        let lhsPriority = lhs.priority ?? 50
        let rhsPriority = rhs.priority ?? 50
        return lhsPriority == rhsPriority ? lhs.title < rhs.title : lhsPriority < rhsPriority
    }

    private func rebuildAppearanceMenu() {
        appearanceMenu.removeAllItems()

        for theme in PopoverTheme.allCases {
            let item = NSMenuItem(
                title: theme.title,
                action: #selector(changePopoverTheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = theme.rawValue
            appearanceMenu.addItem(item)
        }

        updateAppearanceMenu()
    }

    private func updateAppearanceMenu() {
        for item in appearanceMenu.items {
            guard let rawValue = item.representedObject as? String else { continue }
            item.state = rawValue == settings.popoverTheme.rawValue ? .on : .off
        }
    }

    private func updateLaunchAtLoginItem() {
        guard let launchAtLoginItem else { return }
        if settings.recoverAfterCrashes {
            launchAtLoginItem.isEnabled = false
            launchAtLoginItem.state = .on
            launchAtLoginItem.toolTip = "Crash recovery also starts ClipBar at login."
        } else if #available(macOS 13.0, *) {
            launchAtLoginItem.isEnabled = true
            launchAtLoginItem.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
            launchAtLoginItem.toolTip = nil
        } else {
            launchAtLoginItem.isEnabled = false
            launchAtLoginItem.state = .off
        }
    }

    private func updateCrashRecoveryItem() {
        crashRecoveryItem?.state = settings.recoverAfterCrashes ? .on : .off
    }

    private func updateDiagnosticsItems() {
        clipboardLoggingItem?.state = Diagnostics.shared.clipboardLoggingEnabled ? .on : .off
        selectionLoggingItem?.state = Diagnostics.shared.selectionLoggingEnabled ? .on : .off
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func togglePlugin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        pluginManager.togglePlugin(id: id)
        rebuildPluginMenu()
        panelController.hide()
    }

    @objc private func reloadPlugins() {
        pluginManager.reload()
        rebuildPluginMenu()
        panelController.hide()
    }

    @objc private func openPluginsFolder() {
        ClipBarPaths.prepare()
        NSWorkspace.shared.open(ClipBarPaths.plugins)
    }

    @objc private func openBlacklist() {
        ClipBarPaths.prepare()
        NSWorkspace.shared.open(ClipBarPaths.blacklist)
    }

    @objc private func changePopoverTheme(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let theme = PopoverTheme(rawValue: rawValue) else { return }

        do {
            try settings.setPopoverTheme(theme)
            panelController.applyPopoverTheme(theme)
            updateAppearanceMenu()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Save Popover Appearance"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func openConfigurationFolder() {
        ClipBarPaths.prepare()
        NSWorkspace.shared.open(ClipBarPaths.root)
    }

    @objc private func openLogs() {
        ClipBarPaths.prepare()
        NSWorkspace.shared.open(ClipBarPaths.logs)
    }

    @objc private func copyBundleIdentifier(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(identifier, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            try LaunchAtLoginManager.shared.setEnabled(!LaunchAtLoginManager.shared.isEnabled)
            updateLaunchAtLoginItem()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            updateLaunchAtLoginItem()
        }
    }

    @objc private func toggleCrashRecovery() {
        let enabled = !settings.recoverAfterCrashes

        do {
            try settings.setRecoverAfterCrashes(enabled)
            updateCrashRecoveryItem()
            updateLaunchAtLoginItem()

            if enabled {
                try crashRecovery.enable()
            } else {
                try crashRecovery.disable()
            }
        } catch {
            try? settings.setRecoverAfterCrashes(!enabled)
            updateCrashRecoveryItem()
            updateLaunchAtLoginItem()

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Change Crash Recovery"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func toggleClipboardLogging() {
        Diagnostics.shared.clipboardLoggingEnabled.toggle()
        updateDiagnosticsItems()
    }

    @objc private func toggleSelectionLogging() {
        Diagnostics.shared.selectionLoggingEnabled.toggle()
        updateDiagnosticsItems()
    }

    @objc private func exportDiagnosticLog() {
        let source = Diagnostics.shared.logURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            let alert = NSAlert()
            alert.messageText = "No Diagnostic Log"
            alert.informativeText = "Enable logging and reproduce the issue first."
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ClipBar-Diagnostics.log"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let fileManager = FileManager.default
        let temporaryDestination = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
            )

        do {
            defer { try? fileManager.removeItem(at: temporaryDestination) }

            try fileManager.copyItem(at: source, to: temporaryDestination)

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporaryDestination
                )
            } else {
                try fileManager.moveItem(
                    at: temporaryDestination,
                    to: destination
                )
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Export Diagnostics"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func clearDiagnosticLog() {
        Diagnostics.shared.clear()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "ClipBar 1.4 \"Frija\""
        alert.informativeText = "A lightweight contextual action bar for selected text on macOS."

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 145))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.alignment = .center
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        let text = NSMutableAttributedString(
            string: "Copyright © 2026 Steffen Wöll\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
        let website = NSAttributedString(
            string: "steffenwoell.github.io",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .link: URL(string: "https://steffenwoell.github.io")!,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        text.append(website)
        text.append(NSAttributedString(
            string: """


            ClipBar is licensed under the MIT License

            Thesaurus data:
            OpenThesaurus — GNU LGPL 2.1 or later
            Princeton WordNet 3.0 — WordNet License
            Full license texts are included in the app bundle.
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        text.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: text.length)
        )
        textView.textStorage?.setAttributedString(text)

        alert.accessoryView = textView
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
