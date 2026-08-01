import AppKit
import Foundation
import ServiceManagement

@MainActor
final class CrashRecoveryManager {
    static let shared = CrashRecoveryManager()

    private let label = "de.steffenwoell.clipbar.crash-recovery"
    private let fileManager = FileManager.default

    private init() {}

    var agentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    var isEnabled: Bool {
        fileManager.fileExists(atPath: agentURL.path)
    }

    func enable() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw CrashRecoveryError.missingExecutable
        }

        try fileManager.createDirectory(
            at: agentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAgent(executablePath: executableURL.path)

        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }

        try scheduleRestart(enableAgent: true, applicationURL: Bundle.main.bundleURL)
        NSApp.terminate(nil)
    }

    func disable() throws {
        let applicationURL = Bundle.main.bundleURL
        try? fileManager.removeItem(at: agentURL)
        try scheduleRestart(enableAgent: false, applicationURL: applicationURL)
        NSApp.terminate(nil)
    }

    func refreshExecutablePathIfNeeded() {
        guard isEnabled, let executableURL = Bundle.main.executableURL else { return }
        guard let dictionary = NSDictionary(contentsOf: agentURL),
              let arguments = dictionary["ProgramArguments"] as? [String],
              arguments.first != executableURL.path else { return }
        try? writeAgent(executablePath: executableURL.path)
    }

    private func writeAgent(executablePath: String) throws {
        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "ThrottleInterval": 3
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try data.write(to: agentURL, options: .atomic)
    }

    private func scheduleRestart(enableAgent: Bool, applicationURL: URL) throws {
        let uid = getuid()
        let domain = "gui/\(uid)"
        let quotedPlist = shellQuote(agentURL.path)
        let quotedApp = shellQuote(applicationURL.path)
        let command: String

        if enableAgent {
            command = "sleep 0.6; /bin/launchctl bootout \(domain)/\(label) >/dev/null 2>&1 || true; /bin/launchctl bootstrap \(domain) \(quotedPlist)"
        } else {
            command = "sleep 0.6; /bin/launchctl bootout \(domain)/\(label) >/dev/null 2>&1 || true; sleep 0.3; /usr/bin/open \(quotedApp)"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum CrashRecoveryError: LocalizedError {
    case missingExecutable

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "ClipBar could not determine its executable path."
        }
    }
}
