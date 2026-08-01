import Foundation
import Darwin

final class ApplicationBlacklist {
    static let shared = ApplicationBlacklist()

    private let stateQueue = DispatchQueue(label: "de.steffenwoell.clipbar.blacklist.state")
    private let watchQueue = DispatchQueue(label: "de.steffenwoell.clipbar.blacklist.watch")
    private var customBundleIdentifiers = Set<String>()
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    private init() {}

    func start() {
        ClipBarPaths.prepare()
        reload()
        startWatching()
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
    }

    func contains(_ bundleIdentifier: String) -> Bool {
        stateQueue.sync { customBundleIdentifiers.contains(bundleIdentifier) }
    }

    func reload() {
        let contents = (try? String(contentsOf: ClipBarPaths.blacklist, encoding: .utf8)) ?? ""
        let identifiers = Set(contents
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })

        stateQueue.sync {
            customBundleIdentifiers = identifiers
        }
        Diagnostics.shared.log(.selection, "Reloaded blacklist with \(identifiers.count) custom application(s)")
    }

    private func startWatching() {
        fileSource?.cancel()
        fileSource = nil

        ClipBarPaths.prepare()
        let descriptor = open(ClipBarPaths.blacklist.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        fileDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.fileSource?.data ?? []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                ClipBarPaths.prepare()
                self.reload()
                if flags.contains(.rename) || flags.contains(.delete) {
                    self.startWatching()
                }
            }
        }

        source.setCancelHandler { [weak self] in
            close(descriptor)
            if self?.fileDescriptor == descriptor {
                self?.fileDescriptor = -1
            }
        }

        fileSource = source
        source.resume()
    }
}
