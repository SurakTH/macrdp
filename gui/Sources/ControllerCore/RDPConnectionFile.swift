import Foundation
import Network

public enum RDPConnectionFile {
    /// Only export concrete addresses another machine can use. The Controller's
    /// saved Bind and route lookup both produce numeric IP addresses.
    public static func data(for endpoint: String) -> Data? {
        guard let separator = endpoint.lastIndex(of: ":"),
              let port = UInt16(endpoint[endpoint.index(after: separator)...]), port != 0 else { return nil }
        let host = String(endpoint[..<separator])
        let address: String
        if let ipv4 = IPv4Address(host), ipv4 != .any, ipv4.rawValue.first != 127 {
            address = ipv4.debugDescription
        } else if host.hasPrefix("["), host.hasSuffix("]"), !host.contains("%"),
                  let ipv6 = IPv6Address(String(host.dropFirst().dropLast())),
                  ipv6 != .any, ipv6 != .loopback, !ipv6.isLinkLocal {
            // Mapped IPv4 loopback/unspecified is just as local as plain IPv4.
            if let mapped = ipv6.asIPv4, mapped == .any || mapped.rawValue.first == 127 { return nil }
            address = "[\(ipv6.debugDescription)]"
        } else {
            return nil
        }
        // Use the standard mstsc text file envelope. Only the address is
        // exported; the client controls authentication and other preferences.
        let contents = "full address:s:\(address):\(port)\r\n"
        guard let encoded = contents.data(using: .utf16LittleEndian) else { return nil }
        return Data([0xff, 0xfe]) + encoded
    }
}
