import CoreGraphics
import Foundation

enum SelectionSource: Equatable {
    case accessibility
    case clipboardFallback
}

enum SelectionAnchor: Equatable {
    case accessibilityBounds(CGRect)
    case dragBounds(CGRect)
    case cursor(CGPoint)
}

struct Selection: Equatable {
    let text: String
    let anchor: SelectionAnchor
    let source: SelectionSource

    private static let localFileExtensions: Set<String> = [
        "plist", "json", "xml", "yaml", "yml",
        "txt", "md", "markdown", "rtf", "csv",
        "swift", "zsh", "sh", "bash", "py", "js", "ts", "css", "html",
        "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx",
        "jpg", "jpeg", "png", "gif", "webp", "svg", "icns",
        "zip", "7z", "tar", "gz", "dmg", "pkg", "app"
    ]

    private static let commonTopLevelDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "io", "ai", "app", "dev",
        "co", "me", "tv", "info", "biz", "name", "pro", "xyz", "online", "site",
        "de", "at", "ch", "uk", "us", "ca", "fr", "es", "it", "nl", "be", "dk",
        "se", "no", "fi", "pl", "cz", "eu", "jp", "cn", "in", "au", "nz"
    ]

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First plausible HTTP(S) URL contained anywhere in the selected text.
    /// Explicit http(s) URLs are always accepted; bare domains are filtered so
    /// local filenames such as Info.plist are not mistaken for web addresses.
    var detectedURL: URL? {
        let value = trimmedText
        guard !value.isEmpty else { return nil }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let fullRange = NSRange(value.startIndex..., in: value)

            for match in detector.matches(in: value, range: fullRange) {
                guard let url = match.url,
                      let range = Range(match.range, in: value) else {
                    continue
                }

                let original = String(value[range])
                if Self.isAcceptableWebURL(url, originalText: original) {
                    return Self.normalizedWebURL(url, originalText: original)
                }
            }
        }

        // NSDataDetector can miss bare domains embedded in surrounding prose.
        let pattern = #"(?i)(?<![@\w])(?:https?://)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}(?::\d+)?(?:/[^\s<>\"]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let fullRange = NSRange(value.startIndex..., in: value)
        for match in regex.matches(in: value, range: fullRange) {
            guard let range = Range(match.range, in: value) else { continue }

            var candidate = String(value[range])
            candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))

            let explicitScheme = candidate.lowercased().hasPrefix("http://")
                || candidate.lowercased().hasPrefix("https://")
            let normalized = explicitScheme ? candidate : "https://" + candidate

            guard let url = URL(string: normalized),
                  Self.isAcceptableWebURL(url, originalText: candidate) else {
                continue
            }

            return url
        }

        return nil
    }

    /// First DOI contained in the selection, normalized without a doi.org prefix.
    var detectedDOI: String? {
        let value = trimmedText
        guard !value.isEmpty else { return nil }

        let pattern = #"(?i)(?:https?://(?:dx\.)?doi\.org/|doi:\s*)?(10\.\d{4,9}/[-._;()/:A-Z0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let doiRange = Range(match.range(at: 1), in: value) else {
            return nil
        }

        var doi = String(value[doiRange])
        doi = doi.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r.,;:!?]}") )

        // A closing parenthesis is often sentence punctuation, but may also be
        // part of a DOI. Remove it only when it is unmatched.
        while doi.hasSuffix(")")
            && doi.filter({ $0 == "(" }).count < doi.filter({ $0 == ")" }).count {
            doi.removeLast()
        }

        return doi.isEmpty ? nil : doi
    }

    /// A valid ISBN-10 or ISBN-13 contained in the selection, normalized to
    /// digits (and a possible trailing X for ISBN-10).
    var detectedISBN: String? {
        guard detectedDOI == nil else { return nil }

        let value = trimmedText
        guard !value.isEmpty else { return nil }

        let pattern = #"(?i)(?:ISBN(?:-1[03])?[:\s]*)?((?:97[89][ -]?)?(?:\d[ -]?){9}[\dX])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let fullRange = NSRange(value.startIndex..., in: value)
        for match in regex.matches(in: value, range: fullRange) {
            guard let candidateRange = Range(match.range(at: 1), in: value) else {
                continue
            }

            let normalized = value[candidateRange]
                .uppercased()
                .filter { $0.isNumber || $0 == "X" }

            if Self.isValidISBN10(normalized) || Self.isValidISBN13(normalized) {
                return normalized
            }
        }

        return nil
    }

    /// An email address is treated as actionable only when the complete selection is the address.
    var detectedEmailAddress: String? {
        let value = trimmedText
        guard !value.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.range.length == value.utf16.count,
              match.url?.scheme?.lowercased() == "mailto" else {
            return nil
        }

        return value
    }

    /// Existing local files and folders only. Supports shell-style paths such as
    /// /absolute/path, ~/bin, $HOME/.toolbox, ${HOME}/file, and home-relative
    /// dotfiles such as .zsh_private. Terminal location suffixes (:line[:column])
    /// are ignored when the underlying path exists.
    var detectedFileURL: URL? {
        guard let candidate = Self.normalizedFileSystemCandidate(from: trimmedText) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: candidate,
            isDirectory: &isDirectory
        ) else {
            return nil
        }

        return URL(fileURLWithPath: candidate, isDirectory: isDirectory.boolValue)
    }

    var detectedPathIsDirectory: Bool {
        guard let url = detectedFileURL else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func normalizedFileSystemCandidate(from rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
            || (value.hasPrefix("`") && value.hasSuffix("`")) {
            value.removeFirst()
            value.removeLast()
        }

        // Accept paths copied as simple shell commands, e.g. `cd ~/bin` or
        // `source $HOME/.zsh_private`, while avoiding arbitrary command parsing.
        let commandPrefixes = [
            "cd ", "open ", "cat ", "less ", "vim ", "nano ",
            "code ", "source ", ". "
        ]
        if let prefix = commandPrefixes.first(where: { value.hasPrefix($0) }) {
            value.removeFirst(prefix.count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }

        value = value.replacingOccurrences(of: "\\ ", with: " ")
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t,;"))

        if value.hasPrefix("file://"), let fileURL = URL(string: value), fileURL.isFileURL {
            value = fileURL.path
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        if value == "$HOME" || value == "${HOME}" || value == "~" {
            value = home
        } else if value.hasPrefix("$HOME/") {
            value = home + String(value.dropFirst("$HOME".count))
        } else if value.hasPrefix("${HOME}/") {
            value = home + String(value.dropFirst("${HOME}".count))
        } else if value.hasPrefix("~/") {
            value = NSString(string: value).expandingTildeInPath
        } else if value.hasPrefix("./") || value.hasPrefix("../") {
            let relative = value
            let roots = [fileManager.currentDirectoryPath, home]
            if let existing = roots
                .map({ URL(fileURLWithPath: $0).appendingPathComponent(relative).standardizedFileURL.path })
                .first(where: { fileManager.fileExists(atPath: $0) }) {
                value = existing
            }
        } else if value.hasPrefix(".") {
            // Shell dotfiles are conventionally home-relative in copied commands.
            value = (home as NSString).appendingPathComponent(value)
        }

        // Strip terminal diagnostics suffixes only when doing so produces a real path.
        let suffixPattern = #"^(.*?):\d+(?::\d+)?$"#
        if let regex = try? NSRegularExpression(pattern: suffixPattern),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let pathRange = Range(match.range(at: 1), in: value) {
            let stripped = String(value[pathRange])
            if fileManager.fileExists(atPath: stripped) {
                value = stripped
            }
        }

        // Normalize trailing slashes and dot components without resolving symlinks.
        value = NSString(string: value).standardizingPath
        guard value.hasPrefix("/") else { return nil }
        return value
    }

    private static func isValidISBN10(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let characters = Array(value)
        var sum = 0

        for index in 0..<10 {
            let digit: Int
            if index == 9, characters[index] == "X" {
                digit = 10
            } else if let parsed = characters[index].wholeNumberValue {
                digit = parsed
            } else {
                return false
            }
            sum += (10 - index) * digit
        }

        return sum % 11 == 0
    }

    private static func isValidISBN13(_ value: String) -> Bool {
        guard value.count == 13, value.allSatisfy({ $0.isNumber }) else { return false }
        let digits = value.compactMap { $0.wholeNumberValue }
        guard digits.count == 13 else { return false }

        let sum = digits.enumerated().reduce(0) { partial, pair in
            partial + pair.element * (pair.offset.isMultiple(of: 2) ? 1 : 3)
        }
        return sum % 10 == 0
    }

    private static func isAcceptableWebURL(_ url: URL, originalText: String) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }

        let lower = originalText.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return true
        }

        let trimmed = originalText.trimmingCharacters(
            in: CharacterSet(charactersIn: ".,;:!?)]}")
        )
        let extensionCandidate = URL(fileURLWithPath: trimmed).pathExtension.lowercased()
        if localFileExtensions.contains(extensionCandidate) {
            return false
        }

        guard let host = url.host?.lowercased(),
              let topLevelDomain = host.split(separator: ".").last.map(String.init),
              commonTopLevelDomains.contains(topLevelDomain) else {
            return false
        }

        return true
    }

    private static func normalizedWebURL(_ url: URL, originalText: String) -> URL? {
        let lower = originalText.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return url
        }

        return URL(string: "https://" + originalText)
    }
}

struct SelectionContext {
    let selection: Selection
    let bundleIdentifier: String?
    let applicationPID: pid_t
    let detectedAt: CFAbsoluteTime
}
