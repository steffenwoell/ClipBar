import AppKit

/// Owns the temporary clipboard transaction used only when an application
/// does not expose its selected text through Accessibility.
final class ClipboardSelectionEngine {
    enum State: String {
        case idle
        case selectionRequested
        case waitingForClipboard
        case readingSelection
        case restoringClipboard
        case cancelled
    }

    private(set) var state: State = .idle
    private var transactionID = 0
    private var userCopyGeneration = 0
    private let diagnostics = Diagnostics.shared

    func userDidRequestCopy() {
        userCopyGeneration += 1
        transactionID += 1
        if state != .idle {
            state = .cancelled
            diagnostics.log(.clipboard, "User ⌘C detected; pending restore cancelled")
        }
    }

    func cancel() {
        transactionID += 1
        if state != .idle { state = .cancelled }
    }

    func readSelection(
        anchor: SelectionAnchor,
        sendCopy: () -> Bool,
        completion: @escaping (Selection?) -> Void
    ) {
        cancel()
        transactionID += 1
        let transaction = transactionID
        let copyGeneration = userCopyGeneration
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        state = .selectionRequested
        diagnostics.log(.clipboard, "Synthetic copy transaction \(transaction) requested")

        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount

        guard sendCopy() else {
            state = .restoringClipboard
            snapshot.restore(to: pasteboard)
            state = .idle
            diagnostics.log(.clipboard, "Synthetic copy could not be posted")
            completion(nil)
            return
        }

        state = .waitingForClipboard
        pollPasteboard(
            transaction: transaction,
            copyGeneration: copyGeneration,
            snapshot: snapshot,
            pasteboard: pasteboard,
            clearedChangeCount: clearedChangeCount,
            anchor: anchor,
            attemptsRemaining: 8,
            completion: completion
        )
    }

    private func pollPasteboard(
        transaction: Int,
        copyGeneration: Int,
        snapshot: PasteboardSnapshot,
        pasteboard: NSPasteboard,
        clearedChangeCount: Int,
        anchor: SelectionAnchor,
        attemptsRemaining: Int,
        completion: @escaping (Selection?) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self else { return }
            guard transaction == self.transactionID,
                  copyGeneration == self.userCopyGeneration else {
                self.state = .idle
                self.diagnostics.log(.clipboard, "Transaction \(transaction) abandoned; user clipboard wins")
                completion(nil)
                return
            }

            if pasteboard.changeCount == clearedChangeCount, attemptsRemaining > 0 {
                self.pollPasteboard(
                    transaction: transaction,
                    copyGeneration: copyGeneration,
                    snapshot: snapshot,
                    pasteboard: pasteboard,
                    clearedChangeCount: clearedChangeCount,
                    anchor: anchor,
                    attemptsRemaining: attemptsRemaining - 1,
                    completion: completion
                )
                return
            }

            self.state = .readingSelection
            let copiedChangeCount = pasteboard.changeCount
            let containsFileObjects = pasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            )
            let copiedText = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if containsFileObjects {
                self.diagnostics.log(
                    .clipboard,
                    "Synthetic copy produced file objects; rejecting non-text Finder drag"
                )
            } else if let copiedText {
                self.diagnostics.log(
                    .clipboard,
                    "Synthetic copy produced \(copiedText.count) chars"
                )
            } else {
                self.diagnostics.log(
                    .clipboard,
                    "Synthetic copy produced no text"
                )
            }

            // Restore only if nobody—including a clipboard manager or the user—
            // changed the clipboard after the synthetic copy was observed.
            if transaction == self.transactionID,
               copyGeneration == self.userCopyGeneration,
               pasteboard.changeCount == copiedChangeCount {
                self.state = .restoringClipboard
                snapshot.restore(to: pasteboard)
                self.diagnostics.log(.clipboard, "Transaction \(transaction) restored original clipboard")
            } else {
                self.diagnostics.log(.clipboard, "Transaction \(transaction) skipped restore because clipboard changed")
            }

            self.state = .idle
            guard !containsFileObjects,
                  let copiedText,
                  !copiedText.isEmpty else {
                completion(nil)
                return
            }

            completion(Selection(text: copiedText, anchor: anchor, source: .clipboardFallback))
        }
    }
}

struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var saved: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { saved[type] = data }
            }
            return saved
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        }
        if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
    }
}
