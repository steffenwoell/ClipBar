import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

final class ThesaurusStore {
    static let shared = ThesaurusStore()

    private var database: OpaquePointer?

    private init() {
        guard let url = Bundle.main.url(
            forResource: "Thesaurus",
            withExtension: "sqlite"
        ) else {
            return
        }
        if sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            database = nil
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func suggestions(for input: String, limit: Int = 8) -> [String] {
        guard let database else { return [] }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 80,
              trimmed.split(whereSeparator: \Character.isWhitespace).count <= 4 else {
            return []
        }

        let normalized = trimmed
            .precomposedStringWithCanonicalMapping
            .lowercased()
        let preferred = Locale.preferredLanguages.first?.lowercased().hasPrefix("de") == true
            ? ["de", "en"]
            : ["en", "de"]

        for language in preferred {
            let values = query(
                database: database,
                term: normalized,
                language: language,
                limit: limit
            )
            if !values.isEmpty {
                return values.map { matchCase(of: trimmed, in: $0) }
            }
        }
        return []
    }

    private func query(
        database: OpaquePointer,
        term: String,
        language: String,
        limit: Int
    ) -> [String] {
        let sql = """
        SELECT DISTINCT candidate.display
        FROM entries AS source
        JOIN entries AS candidate
          ON candidate.language = source.language
         AND candidate.group_id = source.group_id
        WHERE source.language = ?1
          AND source.term IN (
              ?2,
              COALESCE(
                  (SELECT lemma FROM forms WHERE language = ?1 AND form = ?2 LIMIT 1),
                  ?2
              )
          )
          AND candidate.term != ?2
        ORDER BY candidate.rank, candidate.display COLLATE NOCASE
        LIMIT ?3
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, language, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, term, -1, sqliteTransient)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var results: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { continue }
            results.append(String(cString: value))
        }
        return results
    }

    private func matchCase(of source: String, in suggestion: String) -> String {
        if source == source.uppercased() {
            return suggestion.uppercased()
        }
        if source.first?.isUppercase == true,
           source.dropFirst() == source.dropFirst().lowercased() {
            return suggestion.prefix(1).uppercased() + suggestion.dropFirst()
        }
        return suggestion
    }
}
