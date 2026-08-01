import AppKit
import Foundation

enum ExternalPluginType: String, Decodable {
    case web
    case ai
}

struct ExternalPluginDefinition: Decodable, Identifiable {
    let id: String
    let title: String
    let symbol: String
    let type: ExternalPluginType?
    let url: String
    let prompt: String?
    let priority: Int?
    let maximumLength: Int?
    let enabled: Bool?
    let group: String?
    let groupSymbol: String?

    var resolvedType: ExternalPluginType { type ?? .web }

    enum CodingKeys: String, CodingKey {
        case id, title, symbol, type, url, prompt, priority, enabled, group
        case maximumLength = "maximum_length"
        case groupSymbol = "group_symbol"
    }
}

struct PluginGroupDefinition: Decodable, Identifiable {
    let id: String
    let title: String
    let symbol: String
    let priority: Int?
}

struct ExternalPluginAction: ClipAction {
    let definition: ExternalPluginDefinition

    var id: String { "external.\(definition.id)" }
    var title: String { definition.title }
    var symbol: String { definition.symbol }

    func priority(for context: SelectionContext) -> Int {
        max(definition.priority ?? 50, 50)
    }

    func isAvailable(for context: SelectionContext) -> Bool {
        let text = context.selection.trimmedText
        guard !text.isEmpty else { return false }

        if let maximumLength = definition.maximumLength, text.count > maximumLength {
            return false
        }

        switch definition.resolvedType {
        case .web:
            return definition.url.contains("{{text}}")
        case .ai:
            guard let prompt = definition.prompt else { return false }
            return prompt.contains("{{text}}") && definition.url.contains("{{prompt}}")
        }
    }

    func perform(with context: SelectionContext) {
        let text = context.selection.trimmedText
        let encodedText = text.clipBarPercentEncoded
        var renderedURL = definition.url

        switch definition.resolvedType {
        case .web:
            renderedURL = renderedURL.replacingOccurrences(of: "{{text}}", with: encodedText)
        case .ai:
            guard let promptTemplate = definition.prompt else { return }
            let prompt = promptTemplate.replacingOccurrences(of: "{{text}}", with: text)
            renderedURL = renderedURL
                .replacingOccurrences(of: "{{prompt}}", with: prompt.clipBarPercentEncoded)
                .replacingOccurrences(of: "{{text}}", with: encodedText)
        }

        guard let url = URL(string: renderedURL),
              let scheme = url.scheme?.lowercased(),
              ["https", "http", "codex"].contains(scheme) else {
            Diagnostics.shared.log(
                .plugin,
                "Rejected URL for plugin \(definition.id)"
            )
            return
        }

        if !NSWorkspace.shared.open(url) {
            Diagnostics.shared.log(
                .plugin,
                "Could not open URL for plugin \(definition.id)"
            )
        }
    }
}

struct PluginLoadResult {
    let definitions: [ExternalPluginDefinition]
    let groups: [PluginGroupDefinition]
    let failedFiles: [URL]
}

final class ExternalPluginLoader {
    static let shared = ExternalPluginLoader()

    let pluginsDirectory: URL

    private init() {
        pluginsDirectory = ClipBarPaths.plugins
    }

    func ensureDirectoryExists() {
        ClipBarPaths.prepare()
    }

    private func installBundledPluginsIfNeeded() {
        guard let bundledDirectory = Bundle.main.resourceURL?.appendingPathComponent("DefaultPlugins", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(
                at: bundledDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return }

        for source in files where source.pathExtension.lowercased() == "json" {
            let destination = pluginsDirectory.appendingPathComponent(source.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                NSLog("ClipBar: Could not install bundled plugin %@: %@", source.lastPathComponent, error.localizedDescription)
            }
        }
    }

    func loadDefinitions() -> PluginLoadResult {
        ensureDirectoryExists()
        installBundledPluginsIfNeeded()

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return PluginLoadResult(definitions: [], groups: [], failedFiles: [])
        }

        let decoder = JSONDecoder()
        var definitions: [ExternalPluginDefinition] = []
        var groups: [PluginGroupDefinition] = []
        var failedFiles: [URL] = []
        var seenPluginIDs = Set<String>()
        var seenGroupIDs = Set<String>()

        let jsonFiles = files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for fileURL in jsonFiles {
            do {
                let data = try Data(contentsOf: fileURL)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let type = object?["type"] as? String

                if type == "group" {
                    let group = try decoder.decode(PluginGroupDefinition.self, from: data)
                    guard isValid(group), seenGroupIDs.insert(group.id).inserted else {
                        failedFiles.append(fileURL)
                        continue
                    }
                    groups.append(group)
                } else {
                    let definition = try decoder.decode(ExternalPluginDefinition.self, from: data)
                    guard isValid(definition), seenPluginIDs.insert(definition.id).inserted else {
                        failedFiles.append(fileURL)
                        continue
                    }
                    definitions.append(definition)
                }
            } catch {
                failedFiles.append(fileURL)
                NSLog("ClipBar: Could not load plugin %@: %@", fileURL.lastPathComponent, error.localizedDescription)
            }
        }

        return PluginLoadResult(definitions: definitions, groups: groups, failedFiles: failedFiles)
    }

    private func isValid(_ definition: ExternalPluginDefinition) -> Bool {
        guard !definition.id.isEmpty, !definition.title.isEmpty, !definition.symbol.isEmpty else { return false }
        switch definition.resolvedType {
        case .web:
            return definition.url.contains("{{text}}")
        case .ai:
            return definition.prompt?.contains("{{text}}") == true
                && definition.url.contains("{{prompt}}")
        }
    }

    private func isValid(_ group: PluginGroupDefinition) -> Bool {
        !group.id.isEmpty && !group.title.isEmpty && !group.symbol.isEmpty
    }
}

final class PluginPreferences {
    static let shared = PluginPreferences()
    private let key = "externalPluginEnabledOverrides"
    private init() {}

    func isEnabled(_ definition: ExternalPluginDefinition) -> Bool {
        isEnabled(id: definition.id, defaultValue: definition.enabled ?? true)
    }

    func isEnabled(id: String, defaultValue: Bool = true) -> Bool {
        overrides[id] ?? defaultValue
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        var values = overrides
        values[id] = enabled
        UserDefaults.standard.set(values, forKey: key)
    }

    private var overrides: [String: Bool] {
        let stored = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        return stored.reduce(into: [:]) { result, entry in
            if let value = entry.value as? Bool { result[entry.key] = value }
        }
    }
}

final class PluginManager {
    static let shared = PluginManager()

    private(set) var definitions: [ExternalPluginDefinition] = []
    private(set) var groups: [PluginGroupDefinition] = []
    private(set) var failedFiles: [URL] = []

    private init() { reload() }

    func reload() {
        let result = ExternalPluginLoader.shared.loadDefinitions()
        definitions = result.definitions
        groups = result.groups
        failedFiles = result.failedFiles
    }

    func isEnabled(_ definition: ExternalPluginDefinition) -> Bool {
        PluginPreferences.shared.isEnabled(definition)
    }

    func isEnabled(id: String, defaultValue: Bool = true) -> Bool {
        PluginPreferences.shared.isEnabled(id: id, defaultValue: defaultValue)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        PluginPreferences.shared.setEnabled(enabled, for: id)
    }

    func togglePlugin(id: String) {
        if let definition = definitions.first(where: { $0.id == id }) {
            setEnabled(!isEnabled(definition), for: id)
            return
        }

        setEnabled(!isEnabled(id: id), for: id)
    }

    func enabledDefinitions() -> [ExternalPluginDefinition] {
        definitions.filter(isEnabled)
    }

    func groupDefinition(for id: String) -> PluginGroupDefinition? {
        groups.first { $0.id == id }
    }
}

private extension String {
    var clipBarPercentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .clipBarQueryValueAllowed) ?? ""
    }
}

private extension CharacterSet {
    static let clipBarQueryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
