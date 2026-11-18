public enum CredentialStatus: String {
    case waiting, recovered

    /// Both builds can share a log. Only accept a transition tagged with the
    /// currently managed process, and let its most recent transition win.
    public static func latest(for pid: Int, in lines: [String]) -> Self? {
        guard pid > 0 else { return nil }
        for line in lines.reversed() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.contains("credential_process=\(pid)") else { continue }
            for status in [Self.waiting, .recovered] where fields.contains("credential_status=\(status.rawValue)")
                || fields.contains("credential_status=\"\(status.rawValue)\"") {
                return status
            }
        }
        return nil
    }
}
