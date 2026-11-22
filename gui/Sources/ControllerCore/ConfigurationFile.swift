import Foundation

/// Merge only edited settings into the latest file, then replace it atomically.
/// Comments and settings owned by other tools survive a GUI Apply.
public enum ConfigurationFile {
    public static func parse(_ text: String) -> [String: String] {
        var settings: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, rawValue) = assignment(in: String(line)) else { continue }
            var value = rawValue
            if value.count >= 2, let quote = value.first,
               (quote == "\"" || quote == "'"), value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            settings[key] = value
        }
        return settings
    }

    private static func assignment(in raw: String) -> (key: String, value: String)? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
        let rawKey = line[..<eq]
        let key = rawKey.hasPrefix("export ") ? rawKey.dropFirst(7) : rawKey
        return (key.trimmingCharacters(in: .whitespaces), line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }

    public static func save(changes: [String: String], to url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = try merging(changes: changes, into: text)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func merging(changes: [String: String], into text: String) throws -> String {
        for (key, value) in changes {
            guard !key.isEmpty, !key.contains("="),
                  key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  value.rangeOfCharacter(from: .newlines) == nil else {
                throw NSError(domain: "macrdp.Configuration", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid setting: \(key). Values must fit on one line."])
            }
        }
        var remaining = changes
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            if let (key, _) = assignment(in: raw) {
                if let value = changes[key] {
                    // Collapse duplicate edited keys so the last occurrence
                    // cannot silently override the user's selection.
                    if remaining.removeValue(forKey: key) != nil {
                        let prefix = raw.trimmingCharacters(in: .whitespaces).hasPrefix("export ") ? "export " : ""
                        lines.append("\(prefix)\(key)=\(value)")
                    }
                    continue
                }
            }
            lines.append(raw)
        }
        while lines.last == "" { lines.removeLast() }
        for key in remaining.keys.sorted() { lines.append("\(key)=\(remaining[key]!)") }
        return lines.joined(separator: "\n") + "\n"
    }
}
