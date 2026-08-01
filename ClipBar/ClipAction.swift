import AppKit

struct ClipActionItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let priority: Int
    let children: [ClipActionItem]
    let perform: () -> Void

    var isGroup: Bool { !children.isEmpty }

    init(
        id: String,
        title: String,
        symbol: String,
        priority: Int,
        children: [ClipActionItem] = [],
        perform: @escaping () -> Void = {}
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.priority = priority
        self.children = children
        self.perform = perform
    }
}

protocol ClipAction {
    var id: String { get }
    var title: String { get }
    var symbol: String { get }

    func priority(for context: SelectionContext) -> Int
    func isAvailable(for context: SelectionContext) -> Bool
    func perform(with context: SelectionContext)
}

private enum ActionPriority {
    static let primaryContextual = 0
    static let search = 10
    static let copy = 20
    static let contextual = 30
    static let secondaryContextual = 35
}

struct SearchAction: ClipAction {
    let id = "search"
    let title = "Search with DuckDuckGo"
    let symbol = "magnifyingglass"
    func priority(for context: SelectionContext) -> Int { ActionPriority.search }
    func isAvailable(for context: SelectionContext) -> Bool {
        !context.selection.trimmedText.isEmpty
            && context.selection.detectedDOI == nil
            && context.selection.detectedISBN == nil
            && context.selection.detectedURL == nil
            && context.selection.detectedEmailAddress == nil
            && context.selection.detectedFileURL == nil
    }
    func perform(with context: SelectionContext) { Actions.search(context.selection.trimmedText) }
}

struct CopyAction: ClipAction {
    let id = "copy"
    let title = "Copy"
    let symbol = "doc.on.doc"
    func priority(for context: SelectionContext) -> Int { ActionPriority.copy }
    func isAvailable(for context: SelectionContext) -> Bool { !context.selection.trimmedText.isEmpty }
    func perform(with context: SelectionContext) { Actions.copy(context.selection.text) }
}

struct OpenURLAction: ClipAction {
    let id = "open-url"
    let title = "Open URL"
    let symbol = "globe"
    func priority(for context: SelectionContext) -> Int { ActionPriority.primaryContextual }
    func isAvailable(for context: SelectionContext) -> Bool {
        context.selection.detectedDOI == nil
            && context.selection.detectedURL != nil
    }
    func perform(with context: SelectionContext) {
        guard let url = context.selection.detectedURL else { return }
        NSWorkspace.shared.open(url)
    }
}


struct OpenDOIAction: ClipAction {
    let id = "open-doi"
    let title = "Open DOI"
    let symbol = "doc.text.magnifyingglass"
    func priority(for context: SelectionContext) -> Int { ActionPriority.primaryContextual }
    func isAvailable(for context: SelectionContext) -> Bool { context.selection.detectedDOI != nil }
    func perform(with context: SelectionContext) {
        guard let doi = context.selection.detectedDOI,
              let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://doi.org/\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct OpenISBNAction: ClipAction {
    let id = "open-isbn"
    let title = "Open ISBN in WorldCat"
    let symbol = "books.vertical"
    func priority(for context: SelectionContext) -> Int { ActionPriority.primaryContextual }
    func isAvailable(for context: SelectionContext) -> Bool { context.selection.detectedISBN != nil }
    func perform(with context: SelectionContext) {
        guard let isbn = context.selection.detectedISBN,
              let url = URL(string: "https://search.worldcat.org/isbn/\(isbn)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct WordCountAction: ClipAction {
    let id = "word-count"
    let title = "Word Count"
    let symbol = "textformat.123"
    func priority(for context: SelectionContext) -> Int { ActionPriority.secondaryContextual }
    func isAvailable(for context: SelectionContext) -> Bool {
        !context.selection.trimmedText.isEmpty
            && context.selection.detectedDOI == nil
            && context.selection.detectedISBN == nil
            && context.selection.detectedURL == nil
            && context.selection.detectedEmailAddress == nil
            && context.selection.detectedFileURL == nil
    }
    func perform(with context: SelectionContext) {
        Actions.showWordCount(for: context.selection.text)
    }
}

struct RemoveLineBreaksAction: ClipAction {
    let id = "remove-line-breaks"
    let title = "Remove Line Breaks"
    let symbol = "text.alignleft"

    func priority(for context: SelectionContext) -> Int {
        ActionPriority.secondaryContextual + 1
    }

    func isAvailable(for context: SelectionContext) -> Bool {
        context.selection.text.contains("\n") || context.selection.text.contains("\r")
    }

    func perform(with context: SelectionContext) {
        Actions.copyWithoutLineBreaks(context.selection.text)
    }
}

private protocol CaseConversionAction: ClipAction {}

extension CaseConversionAction {
    func priority(for context: SelectionContext) -> Int {
        ActionPriority.secondaryContextual + 2
    }

    func isAvailable(for context: SelectionContext) -> Bool {
        !context.selection.trimmedText.isEmpty
            && context.selection.detectedDOI == nil
            && context.selection.detectedISBN == nil
            && context.selection.detectedURL == nil
            && context.selection.detectedEmailAddress == nil
            && context.selection.detectedFileURL == nil
    }
}

struct UppercaseAction: CaseConversionAction {
    let id = "case-uppercase"
    let title = "UPPERCASE"
    let symbol = "textformat.size.larger"
    func perform(with context: SelectionContext) {
        Actions.copyUppercased(context.selection.text)
    }
}

struct LowercaseAction: CaseConversionAction {
    let id = "case-lowercase"
    let title = "lowercase"
    let symbol = "textformat.size.smaller"
    func perform(with context: SelectionContext) {
        Actions.copyLowercased(context.selection.text)
    }
}

struct TitleCaseAction: CaseConversionAction {
    let id = "case-title"
    let title = "Title Case"
    let symbol = "textformat.abc"
    func perform(with context: SelectionContext) {
        Actions.copyTitleCased(context.selection.text)
    }
}

struct SentenceCaseAction: CaseConversionAction {
    let id = "case-sentence"
    let title = "Sentence case"
    let symbol = "textformat"
    func perform(with context: SelectionContext) {
        Actions.copySentenceCased(context.selection.text)
    }
}

struct EmailAction: ClipAction {
    let id = "email"
    let title = "New Email"
    let symbol = "envelope"
    func priority(for context: SelectionContext) -> Int { ActionPriority.primaryContextual }
    func isAvailable(for context: SelectionContext) -> Bool { context.selection.detectedEmailAddress != nil }
    func perform(with context: SelectionContext) {
        guard let address = context.selection.detectedEmailAddress else { return }
        Actions.composeEmail(to: address)
    }
}

struct OpenFolderAction: ClipAction {
    let id = "open-folder"
    let title = "Open Folder in Finder"
    let symbol = "folder"
    func priority(for context: SelectionContext) -> Int { ActionPriority.primaryContextual }
    func isAvailable(for context: SelectionContext) -> Bool {
        context.selection.detectedFileURL != nil
    }
    func perform(with context: SelectionContext) {
        guard let url = context.selection.detectedFileURL else { return }
        Actions.openFolderContaining(url)
    }
}

final class ActionRegistry {
    private let builtInActions: [any ClipAction] = [
        SearchAction(), CopyAction(), OpenDOIAction(), OpenISBNAction(),
        OpenURLAction(), EmailAction(), OpenFolderAction(), WordCountAction(),
        RemoveLineBreaksAction()
    ]

    private let caseConversionActions: [any ClipAction] = [
        UppercaseAction(), LowercaseAction(), TitleCaseAction(), SentenceCaseAction()
    ]

    private let optionalBuiltInActionIDs: Set<String> = [
        "word-count",
        "remove-line-breaks",
        "case-uppercase",
        "case-lowercase",
        "case-title",
        "case-sentence"
    ]

    func availableItems(
        for context: SelectionContext,
        afterPerform: @escaping () -> Void
    ) -> [ClipActionItem] {
        var items = builtInActions
            .filter { action in
                !optionalBuiltInActionIDs.contains(action.id)
                    || PluginManager.shared.isEnabled(id: action.id)
            }
            .filter { $0.isAvailable(for: context) }
            .map { item(for: $0, context: context, afterPerform: afterPerform) }

        if PluginManager.shared.isEnabled(id: "case-converter") {
            let availableCaseActions = caseConversionActions
                .filter { PluginManager.shared.isEnabled(id: $0.id) }
                .filter { $0.isAvailable(for: context) }
                .map { item(for: $0, context: context, afterPerform: afterPerform) }
                .sorted { lhs, rhs in
                    lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }

            if availableCaseActions.count == 1, let onlyAction = availableCaseActions.first {
                items.append(onlyAction)
            } else if !availableCaseActions.isEmpty {
                items.append(
                    ClipActionItem(
                        id: "group.case-converter",
                        title: "Case Converter",
                        symbol: "textformat",
                        priority: ActionPriority.secondaryContextual + 2,
                        children: availableCaseActions
                    )
                )
            }
        }

        let availablePlugins = PluginManager.shared.enabledDefinitions()
            .map(ExternalPluginAction.init)
            .filter { $0.isAvailable(for: context) }

        let grouped = Dictionary(grouping: availablePlugins) { $0.definition.group }

        for plugin in grouped[nil] ?? [] {
            items.append(item(for: plugin, context: context, afterPerform: afterPerform))
        }

        for (groupIDOptional, plugins) in grouped {
            guard let groupID = groupIDOptional else { continue }

            if plugins.count == 1, let plugin = plugins.first {
                items.append(item(for: plugin, context: context, afterPerform: afterPerform))
                continue
            }

            let children = plugins
                .map { item(for: $0, context: context, afterPerform: afterPerform) }
                .sorted(by: itemSort)

            let explicit = PluginManager.shared.groupDefinition(for: groupID)
            let title = explicit?.title ?? groupID.replacingOccurrences(of: "-", with: " ").capitalized
            let symbol = explicit?.symbol
                ?? plugins.compactMap(\.definition.groupSymbol).first
                ?? "square.grid.2x2"
            let priority = explicit?.priority
                ?? children.map(\.priority).min()
                ?? 50

            items.append(
                ClipActionItem(
                    id: "group.\(groupID)",
                    title: title,
                    symbol: symbol,
                    priority: priority,
                    children: children
                )
            )
        }

        return items.sorted(by: itemSort)
    }

    private func item(
        for action: any ClipAction,
        context: SelectionContext,
        afterPerform: @escaping () -> Void
    ) -> ClipActionItem {
        ClipActionItem(
            id: action.id,
            title: action.title,
            symbol: action.symbol,
            priority: action.priority(for: context),
            perform: {
                action.perform(with: context)
                // A submenu action is hosted by a SwiftUI popover attached to
                // the panel. Resetting the panel model synchronously destroys
                // that popover while its button action is still running.
                // Perform the action first and dismiss on the next run-loop
                // pass so grouped actions behave like top-level actions.
                DispatchQueue.main.async {
                    afterPerform()
                }
            }
        )
    }

    private func itemSort(_ lhs: ClipActionItem, _ rhs: ClipActionItem) -> Bool {
        lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
    }
}
