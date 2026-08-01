import AppKit

struct Actions {
    static func search(_ text: String) {
        openWebURL(base: "https://duckduckgo.com/", queryName: "q", value: text)
    }


    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }



    static func copyWithoutLineBreaks(_ text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .replacingOccurrences(
                        of: #"[ \t]+"#,
                        with: " ",
                        options: .regularExpression
                    )
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        copy(paragraphs)
    }

    static func copyUppercased(_ text: String) {
        copy(text.uppercased())
    }

    static func copyLowercased(_ text: String) {
        copy(text.lowercased())
    }

    static func copyTitleCased(_ text: String) {
        copy(text.capitalized)
    }

    static func copySentenceCased(_ text: String) {
        let lowercased = text.lowercased()
        var result = ""
        var shouldCapitalize = true

        for character in lowercased {
            if shouldCapitalize, character.isLetter {
                result.append(contentsOf: String(character).uppercased())
                shouldCapitalize = false
            } else {
                result.append(character)
            }

            if character == "." || character == "!" || character == "?" || character == "\n" {
                shouldCapitalize = true
            }
        }

        copy(result)
    }

    static func composeEmail(to address: String) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    static func openFolderContaining(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        guard exists else { return }

        let folderURL = isDirectory.boolValue
            ? url
            : url.deletingLastPathComponent()
        NSWorkspace.shared.open(folderURL)
    }


    static func showWordCount(for text: String) {
        let words = wordCount(in: text)
        let characters = text.count
        let charactersWithoutWhitespace = text.filter { !$0.isWhitespace }.count
        let normalizedLineEndings = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedLineEndings.isEmpty
            ? 0
            : normalizedLineEndings.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).count
        var paragraphs = 0
        var insideParagraph = false
        for line in normalizedLineEndings.components(separatedBy: .newlines) {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                insideParagraph = false
            } else if !insideParagraph {
                paragraphs += 1
                insideParagraph = true
            }
        }
        let readingMinutes = words == 0 ? 0 : max(1, Int(ceil(Double(words) / 200.0)))

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let formatted: (Int) -> String = { value in
            formatter.string(from: NSNumber(value: value)) ?? String(value)
        }

        let alert = NSAlert()
        alert.messageText = "Word Count"
        alert.informativeText = """
        Words: \(formatted(words))
        Characters: \(formatted(characters))
        Characters without spaces: \(formatted(charactersWithoutWhitespace))
        Lines: \(formatted(lines))
        Paragraphs: \(formatted(paragraphs))
        Estimated reading time: \(readingMinutes) min
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func wordCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }

    private static func openWebURL(base: String, queryName: String, value: String) {
        guard !value.isEmpty,
              var components = URLComponents(string: base) else {
            return
        }
        components.queryItems = [URLQueryItem(name: queryName, value: value)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}
