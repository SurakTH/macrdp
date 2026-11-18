import Foundation

/// Merge only edited settings into the latest file, then replace it atomically.
/// Comments and settings owned by other tools survive a GUI Apply.
public enum ConfigurationFile {
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
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                if let value = changes[key] {
                    // Collapse duplicate edited keys so the last occurrence
                    // cannot silently override the user's selection.
                    if remaining.removeValue(forKey: key) != nil {
                        lines.append("\(key)=\(value)")
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
