public enum RDPListener {
    public static func port(fromBind bind: String) -> UInt16? {
        guard let colon = bind.lastIndex(of: ":"),
              let port = UInt16(bind[bind.index(after: colon)...]), port != 0 else { return nil }
        return port
    }

    /// Match socket name fields only under the requested PID. lsof has
    /// already filtered for LISTEN; retain the port check for wildcard/IPv6.
    public static func isOwned(by pid: Int, port: UInt16, in output: String) -> Bool {
        var selected = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.first == "p" {
                selected = Int(line.dropFirst()) == pid
            } else if selected, line.first == "n", !line.contains("->"),
                      line.hasSuffix(":\(port)") {
                return true
            }
        }
        return false
    }
}
