import Foundation

/// The stable, testable contract between macrdp Controller and launchd.
///
/// Keeping this outside the AppKit executable lets CI exercise upgrades from an
/// old/moved server bundle without registering a real LaunchAgent.
public struct LaunchAgentSpec {
    public let label: String
    public let serverBinaryPath: String
    public let configPath: String
    public let stderrPath: String

    public init(label: String, serverBinaryPath: String, configPath: String, stderrPath: String) {
        self.label = label
        self.serverBinaryPath = serverBinaryPath
        self.configPath = configPath
        self.stderrPath = stderrPath
    }

    public var programArguments: [String] {
        [serverBinaryPath, "--config", configPath]
    }

    public var propertyList: [String: Any] {
        [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardErrorPath": stderrPath,
            "EnvironmentVariables": ["RUST_LOG": "info"],
        ]
    }

    /// True only when the loaded-on-disk contract is complete and points to a
    /// real server executable. Extra plist keys are tolerated for forward
    /// compatibility; every key owned by the controller must still match.
    public func matches(_ plist: [String: Any], fileExists: (String) -> Bool) -> Bool {
        guard plist["Label"] as? String == label,
              plist["ProgramArguments"] as? [String] == programArguments,
              bool(plist["RunAtLoad"]),
              bool(plist["KeepAlive"]),
              plist["StandardErrorPath"] as? String == stderrPath,
              let environment = plist["EnvironmentVariables"] as? [String: String],
              environment["RUST_LOG"] == "info",
              fileExists(serverBinaryPath) else {
            return false
        }
        return true
    }

    /// Reconcile both the plist on disk and launchd's cached program path. A
    /// correct file is not enough when an older job was bootstrapped before the
    /// file changed; that live job must be unloaded and registered again.
    public func requiresRepair(
        plist: [String: Any]?,
        loadedProgramPath: String?,
        isLoaded: Bool,
        fileExists: (String) -> Bool
    ) -> Bool {
        guard let plist, matches(plist, fileExists: fileExists) else { return true }
        return isLoaded && loadedProgramPath != serverBinaryPath
    }

    public static func programPath(in plist: [String: Any]) -> String? {
        (plist["ProgramArguments"] as? [String])?.first
    }

    private func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }
}
