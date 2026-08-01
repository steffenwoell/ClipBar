import Foundation

struct ClipBarPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/clipbar", isDirectory: true)
    static let plugins = root.appendingPathComponent("plugins", isDirectory: true)
    static let logs = root.appendingPathComponent("logs", isDirectory: true)
    static let cache = root.appendingPathComponent("cache", isDirectory: true)
    static let blacklist = root.appendingPathComponent("blacklist.txt")
    static let settings = root.appendingPathComponent("settings.json")
    static let diagnosticLog = logs.appendingPathComponent("clipbar.log")

    static func prepare() {
        let manager = FileManager.default
        for directory in [root, plugins, logs, cache] {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        createSettingsIfNeeded()
        createBlacklistIfNeeded()
        migrateLegacyLogIfNeeded()
    }

    private static func createSettingsIfNeeded() {
        guard !FileManager.default.fileExists(atPath: settings.path) else { return }
        let contents = """
        {
          "popupScale": 1.0,
          "animations": true,
          "showTooltips": true,
          "developerMode": false,
          "popoverTheme": "system",
          "recoverAfterCrashes": false
        }
        """
        try? contents.write(to: settings, atomically: true, encoding: .utf8)
    }

    private static func createBlacklistIfNeeded() {
        guard !FileManager.default.fileExists(atPath: blacklist.path) else { return }
        let contents = """
        # ClipBar application blacklist
        # One bundle identifier per line. Lines beginning with # are ignored.
        # Example:
        # com.apple.Preview
        # com.microsoft.Powerpoint

        """
        try? contents.write(to: blacklist, atomically: true, encoding: .utf8)
    }

    private static func migrateLegacyLogIfNeeded() {
        let oldURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClipBar.log")
        guard FileManager.default.fileExists(atPath: oldURL.path),
              !FileManager.default.fileExists(atPath: diagnosticLog.path) else { return }
        try? FileManager.default.moveItem(at: oldURL, to: diagnosticLog)
    }
}
