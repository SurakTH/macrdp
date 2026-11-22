import Foundation

public struct PersonalPreset: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var settings: [String: String]

    public init(id: UUID = UUID(), name: String, settings: [String: String]) {
        self.id = id
        self.name = name
        self.settings = settings.filter { Self.allowedKeys.contains($0.key) }
    }

    // Explicit allowlist: presets never carry accounts, network access, paths,
    // EXTRA_FLAGS or physical-display takeover settings.
    public static let allowedKeys: Set<String> = [
        "ENABLE_H264", "HIDPI", "CAPTURE_SIZE", "FPS", "BITRATE", "ADAPTIVE_BITRATE",
        "AVC444", "KEYFRAME_INTERVAL", "KEYFRAME_ON_CHANGE", "KEYFRAME_CHANGE_PCT",
        "KEYFRAME_CLICK_PCT", "H264_FRAMES_IN_FLIGHT", "FLUSH_FRAMES", "FLUSH_INTERVAL_MS", "RESPONSIVE_CAPTURE",
        "TCP_VIDEO_BACKPRESSURE", "H264_MAX_UNACKED_FRAMES", "CAPTURE_NV12",
        "ENABLE_AAC", "MAP_CTRL_TO_CMD", "ALT_TAB_SWITCH", "ENABLE_UDP_MULTITRANSPORT",
        "UDP_MIGRATE_EGFX", "UNMINIMIZE", "BLANK_RECOVERY", "STATS_ENDPOINT",
        "ENABLE_LOSSY_AUDIO", "REVERSE_SCROLL", "ALT_Q_QUIT", "ALT_BACKTICK_SWITCH", "ALT_SPACE_SPOTLIGHT",
    ]
}

public struct PersonalPresetStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    private struct Document: Codable { var version: Int = 1; var presets: [PersonalPreset] }

    public func load() throws -> [PersonalPreset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw failure("Preset file is too large.") }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw failure("Unsupported preset file version.") }
        let presets = document.presets.map { PersonalPreset(id: $0.id, name: $0.name, settings: $0.settings) }
        try validate(presets)
        return presets
    }

    public func save(_ presets: [PersonalPreset]) throws {
        try validate(presets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(presets: presets))
        guard data.count <= 1_048_576 else { throw failure("Preset file is too large.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validate(_ presets: [PersonalPreset]) throws {
        guard presets.count <= 100, Set(presets.map(\.id)).count == presets.count else {
            throw failure("Keep at most 100 presets with unique identifiers.")
        }
        var names = Set<String>()
        for preset in presets {
            let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80, name.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw failure("Use a preset name from 1 to 80 characters on one line.")
            }
            guard names.insert(name.lowercased()).inserted else { throw failure("A preset with that name already exists.") }
            guard preset.settings.keys.allSatisfy({ PersonalPreset.allowedKeys.contains($0) }),
                  preset.settings.values.allSatisfy({ $0.count <= 256 && $0.rangeOfCharacter(from: .newlines) == nil }) else {
                throw failure("Preset contains unsupported settings.")
            }
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "macrdp.presets", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
