import AppKit
import Foundation

final class Diagnostics {
    static let shared = Diagnostics()

    enum Category: String {
        case clipboard = "Clipboard"
        case selection = "Selection"
        case panel = "Panel"
        case plugin = "Plugin"
    }

    private let queue = DispatchQueue(label: "de.steffenwoell.clipbar.diagnostics")
    private let clipboardKey = "diagnostics.clipboardLogging"
    private let selectionKey = "diagnostics.selectionLogging"
    private let maximumLogSize = 5 * 1_024 * 1_024
    private let retainedLogSize = 4 * 1_024 * 1_024

    var clipboardLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: clipboardKey) }
        set { UserDefaults.standard.set(newValue, forKey: clipboardKey) }
    }

    var selectionLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: selectionKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectionKey) }
    }

    var logURL: URL { ClipBarPaths.diagnosticLog }

    func log(_ category: Category, _ message: @autoclosure @escaping () -> String) {
        let enabled: Bool
        switch category {
        case .clipboard: enabled = clipboardLoggingEnabled
        case .selection, .panel, .plugin: enabled = selectionLoggingEnabled
        }
        guard enabled else { return }

        let text = message()
        queue.async { [logURL, maximumLogSize, retainedLogSize] in
            let formatter = ISO8601DateFormatter()
            let line = "\(formatter.string(from: Date())) [\(category.rawValue)] \(text)\n"
            let data = Data(line.utf8)
            let directory = logURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            self.truncateOldestEntriesIfNeeded(
                at: logURL,
                incomingByteCount: data.count,
                maximumSize: maximumLogSize,
                retainedSize: retainedLogSize
            )

            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: data)
                return
            }

            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    private func truncateOldestEntriesIfNeeded(
        at url: URL,
        incomingByteCount: Int,
        maximumSize: Int,
        retainedSize: Int
    ) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let currentSize = attributes[.size] as? NSNumber,
              currentSize.intValue + incomingByteCount > maximumSize,
              let existingData = try? Data(contentsOf: url),
              !existingData.isEmpty else {
            return
        }

        let keepCount = min(retainedSize, existingData.count)
        var retained = Data(existingData.suffix(keepCount))

        // Start at the first complete log entry after the truncated prefix.
        if keepCount < existingData.count,
           let newlineIndex = retained.firstIndex(of: 0x0A) {
            let nextIndex = retained.index(after: newlineIndex)
            retained = Data(retained[nextIndex...])
        }

        try? retained.write(to: url, options: .atomic)
    }
}
