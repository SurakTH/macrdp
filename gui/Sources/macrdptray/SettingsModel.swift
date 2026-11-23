import AppKit
import ControllerCore
import Network
import SwiftUI

/// The live-verified launcher presets, expressed as config.env keys so the
/// installed app and the terminal launchers select the same runtime behavior.
/// Network exposure is deliberately not part of a performance profile; the
/// user enables LAN access separately and sees the existing security warning.
enum PerformanceProfile: String, CaseIterable, Identifiable {
    case stable, hevc1080, hevc1440, hevc4K, ultimate, lan, native, fast, fourK, fourKText

    static let hevcProfiles: [Self] = [.hevc1080, .hevc1440, .hevc4K]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: return "Stable"
        case .hevc1080: return "1080p/60 HEVC Preview"
        case .hevc1440: return "1440p/60 HEVC Preview"
        case .hevc4K: return "4K/60 HEVC Preview"
        case .ultimate: return "Ultimate"
        case .lan: return "LAN Max"
        case .native: return "Native"
        case .fast: return "Fast"
        case .fourK: return "4K/60 Preview"
        case .fourKText: return "4K/60 Sharp Text (LAN)"
        }
    }

    var detail: String {
        switch self {
        case .stable:
            return "1080p AVC420 at 60 FPS with a 60 Mbps adaptive bitrate target over TCP. Tested on wired LAN."
        case .hevc4K:
            return "4K/60 over TCP with HEVC on compatible clients, faster encoding, NV12, and a two-frame acknowledgement limit."
        case .hevc1080:
            return "1080p/60 over TCP with HEVC on compatible clients, direct NV12 capture, and a 60 Mbps adaptive ceiling."
        case .hevc1440:
            return "2560 × 1440 at 60 FPS over TCP with direct NV12 capture and a 60 Mbps adaptive ceiling."
        case .ultimate:
            return "Best overall balance: AVC420 at 60 FPS, 25 Mbps adaptive, UDP offered, AAC."
        case .lan:
            return "Highest live-verified LAN quality: HiDPI AVC420, 60 FPS, 50 Mbps, stable TCP and PCM."
        case .native:
            return "Sharpest text and UI: HiDPI bitmap/RemoteFX at a stable 12 FPS."
        case .fast:
            return "Lowest latency: AVC420 at 60 FPS, 50 Mbps and a minimal one-frame pipeline."
        case .fourKText:
            return "Sharper text while scrolling on a fast wired LAN. Uses the 4K/60 Preview settings with a 100 Mbps adaptive ceiling."
        case .fourK:
            return "4K at up to 60 FPS with NV12 capture, 60 Mbps adaptive, and TCP. Virtual displays use their own resolution or the client's request."
        }
    }

    var settings: [String: String] {
        var values = [
            "AVC444": "0",
            "PREFER_HEVC": "0",
            "HEVC_HIGH_SPEED": "0",
            "H264_MAIN_PROFILE": "0",
            "CAPTURE_SIZE": "",
            "UDP_MIGRATE_EGFX": "0",
            "KEYFRAME_INTERVAL": "2.0",
            "KEYFRAME_CHANGE_PCT": "20",
            "KEYFRAME_CLICK_PCT": "5",
            "H264_FRAMES_IN_FLIGHT": "2",
            "FLUSH_FRAMES": "4",
            "FLUSH_INTERVAL_MS": "",
            "RESPONSIVE_CAPTURE": "0",
            "H264_MAX_UNACKED_FRAMES": "0",
            "CAPTURE_NV12": "0",
            "ENABLE_LOSSY_AUDIO": "0",
            "STATS_ENDPOINT": "1",
        ]
        switch self {
        case .hevc4K:
            return PerformanceProfile.hevc1080.settings.merging([
                "CAPTURE_SIZE": "3840x2160", "HEVC_HIGH_SPEED": "1",
                "RESPONSIVE_CAPTURE": "1", "H264_MAX_UNACKED_FRAMES": "2",
                "KEYFRAME_ON_CHANGE": "0",
            ]) { _, new in new }
        case .hevc1080:
            return PerformanceProfile.stable.settings.merging([
                "PREFER_HEVC": "1", "CAPTURE_NV12": "1",
            ]) { _, new in new }
        case .hevc1440:
            return PerformanceProfile.hevc1080.settings.merging(["CAPTURE_SIZE": "2560x1440"]) { _, new in new }
        case .stable:
            values.merge([
                "ENABLE_H264": "1", "HIDPI": "0", "CAPTURE_SIZE": "1920x1080",
                "ENABLE_AAC": "0", "ADAPTIVE_BITRATE": "1", "ENABLE_UDP_MULTITRANSPORT": "0",
                "BITRATE": "60", "FPS": "60", "KEYFRAME_ON_CHANGE": "1",
                "KEYFRAME_CHANGE_PCT": "15", "KEYFRAME_CLICK_PCT": "3",
                "H264_FRAMES_IN_FLIGHT": "2", "FLUSH_FRAMES": "2",
                "UNMINIMIZE": "0", "BLANK_RECOVERY": "0",
            ]) { _, new in new }
        case .ultimate:
            values.merge([
                "ENABLE_H264": "1", "HIDPI": "0", "ENABLE_AAC": "1",
                "ADAPTIVE_BITRATE": "1", "ENABLE_UDP_MULTITRANSPORT": "1",
                "BITRATE": "25", "FPS": "60", "KEYFRAME_ON_CHANGE": "1",
                "KEYFRAME_CHANGE_PCT": "15", "KEYFRAME_CLICK_PCT": "3",
                "H264_FRAMES_IN_FLIGHT": "1", "FLUSH_FRAMES": "2",
                "UNMINIMIZE": "1", "BLANK_RECOVERY": "0",
            ]) { _, new in new }
        case .lan:
            values.merge([
                "ENABLE_H264": "1", "HIDPI": "1", "ENABLE_AAC": "0",
                "ADAPTIVE_BITRATE": "0", "ENABLE_UDP_MULTITRANSPORT": "0",
                "BITRATE": "50", "FPS": "60", "KEYFRAME_ON_CHANGE": "1",
                "KEYFRAME_CHANGE_PCT": "15", "KEYFRAME_CLICK_PCT": "3",
                "H264_FRAMES_IN_FLIGHT": "1", "FLUSH_FRAMES": "2",
                "UNMINIMIZE": "1", "BLANK_RECOVERY": "0",
            ]) { _, new in new }
        case .native:
            values.merge([
                "ENABLE_H264": "0", "HIDPI": "1", "ENABLE_AAC": "0",
                "ADAPTIVE_BITRATE": "0", "ENABLE_UDP_MULTITRANSPORT": "0",
                "BITRATE": "", "FPS": "12", "KEYFRAME_ON_CHANGE": "0",
                "UNMINIMIZE": "1", "BLANK_RECOVERY": "1", "STATS_ENDPOINT": "0",
            ]) { _, new in new }
        case .fast:
            values.merge([
                "ENABLE_H264": "1", "HIDPI": "0", "ENABLE_AAC": "0",
                "ADAPTIVE_BITRATE": "0", "ENABLE_UDP_MULTITRANSPORT": "1",
                "BITRATE": "50", "FPS": "60", "KEYFRAME_ON_CHANGE": "0",
                "H264_FRAMES_IN_FLIGHT": "1", "UNMINIMIZE": "0",
                "BLANK_RECOVERY": "0",
            ]) { _, new in new }
        case .fourK, .fourKText:
            values.merge([
                "ENABLE_H264": "1", "HIDPI": "0", "CAPTURE_SIZE": "3840x2160",
                "ENABLE_AAC": "0", "ADAPTIVE_BITRATE": "1", "ENABLE_UDP_MULTITRANSPORT": "0",
                "BITRATE": self == .fourKText ? "100" : "60", "FPS": "60", "KEYFRAME_ON_CHANGE": "0",
                "H264_FRAMES_IN_FLIGHT": "2", "FLUSH_FRAMES": "2",
                "RESPONSIVE_CAPTURE": "1", "CAPTURE_NV12": "1",
                "UNMINIMIZE": "0", "BLANK_RECOVERY": "0",
            ]) { _, new in new }
        }
        return values
    }

    func matches(_ config: [String: String]) -> Bool {
        settings.allSatisfy { key, value in
            if key == "H264_MAX_UNACKED_FRAMES" {
                return UInt32(SettingsModel.pacingLimit(in: config)) == UInt32(value)
            }
            if ["CAPTURE_NV12", "ENABLE_LOSSY_AUDIO", "PREFER_HEVC", "HEVC_HIGH_SPEED", "H264_MAIN_PROFILE"].contains(key) {
                return SettingsModel.settingEnabled(key, in: config) == (value == "1")
            }
            return config[key, default: Self.settingFallback(key)] == value
        }
    }

    static func settingFallback(_ key: String) -> String {
        switch key {
        case "RESPONSIVE_CAPTURE", "H264_MAIN_PROFILE": return "0"
        default: return ""
        }
    }
}

enum VideoCodecPreference: String, CaseIterable {
    case h264, hevc, bitmap

    init(config: [String: String]) {
        let extra = (config["EXTRA_FLAGS"] ?? "").split(whereSeparator: \.isWhitespace)
        if config["ENABLE_H264"] == "1" || extra.contains("--enable-h264") {
            self = config["PREFER_HEVC"] == "1" ? .hevc : .h264
        } else {
            self = .bitmap
        }
    }

    var title: String {
        switch self {
        case .h264: return "H.264 (AVC)"
        case .hevc: return "Prefer H.265 (HEVC) · Preview"
        case .bitmap: return "Bitmap / Legacy"
        }
    }
}

enum VirtualDisplayScaling: String, CaseIterable {
    case standard = "0"
    case retina = "1"
    case automatic = "auto"

    var title: String {
        switch self {
        case .standard: return "Standard (1×)"
        case .retina: return "Retina (2×)"
        case .automatic: return "Automatic · follow client"
        }
    }
}

// Draft model backing the tabbed Settings window (SettingsWindow.swift).
//
// Everything the old menu toggled lands in config.env as KEY=value, applied by
// re-exec'ing the LaunchAgent (`launchctl kickstart -k`). The menu wrote + kick-
// started on EVERY click (one server restart per toggle). This model instead
// loads config.env into an in-memory `draft`, lets the UI mutate the draft with
// NO disk write and NO restart, and applies everything at once on Apply (write
// the changed keys, then a single kickstart). Revert reloads from disk.
//
// Imperative actions (password, smart-card installer, camera extension, log/pane
// opens) are NOT part of the draft — they run immediately via the controller,
// exactly as before. Only declarative config lives in the draft.
final class SettingsModel: ObservableObject {
    unowned let controller: AppController

    /// Config exactly as last read from disk (all keys, GUI-managed or not).
    /// The draft compares against this verbatim; legacy-key back-compat (e.g.
    /// CAPTURE_PRIMARY) is handled by computed accessors, not by rewriting it.
    @Published private(set) var saved: [String: String]
    /// Working copy the UI edits; differs from `saved` exactly when dirty.
    @Published var draft: [String: String]
    /// Describes the completed action, independent of later server state.
    @Published private(set) var applySuccessMessage: String?
    @Published private(set) var applyError: String?
    @Published private(set) var restartRequired = false
    private let saveSettings: ([String: String]) throws -> Void
    private let performAction: (ServerAction, @escaping (ServerActionResult) -> Void) -> Void
    /// Cached at open + after Apply (NOT recomputed in the view body — it shells
    /// out to `launchctl`, which per-render would spawn a subprocess per keystroke).
    @Published private(set) var serverRunning = false
    @Published private(set) var serverStatusKnown = false
    /// Lifecycle work is serialized by AppController and reflected here so the
    /// SwiftUI window remains responsive and never lets Start/Stop be spammed.
    @Published private(set) var serverAction: ServerAction?
    @Published private(set) var serverActionResult: ServerActionResult?
    /// Which section the sidebar shows. Hoisted here (not local @State) so the
    /// main-menu "Section" items can navigate the window too.
    @Published var section: SettingsSection = .status
    @Published private var customCaptureSelected = false
    @Published private var fastFlushSelected = false
    @Published private(set) var personalPresets: [PersonalPreset] = []
    @Published var personalPresetID: UUID?
    @Published var personalPresetName = ""
    @Published private(set) var presetMessage: String?
    @Published private(set) var presetError: String?
    private let presetStore: PersonalPresetStore
    private var presetLoadFailed = false

    init(controller: AppController,
         initialConfig: [String: String]? = nil,
         saveSettings: (([String: String]) throws -> Void)? = nil,
         performAction: ((ServerAction, @escaping (ServerActionResult) -> Void) -> Void)? = nil,
         presetStore: PersonalPresetStore? = nil) {
        self.controller = controller
        self.presetStore = presetStore ?? PersonalPresetStore(
            url: controller.configURL.deletingLastPathComponent().appendingPathComponent("presets.json"))
        self.saveSettings = saveSettings ?? { [unowned controller] in try controller.saveConfig(changes: $0) }
        self.performAction = performAction ?? { [unowned controller] in controller.performServerAction($0, completion: $1) }
        if initialConfig == nil { controller.ensureConfigExists() }
        let cfg = initialConfig ?? controller.readConfig()
        self.saved = cfg
        self.draft = cfg
        self.serverRunning = controller.cachedServerRunning
        self.serverStatusKnown = initialConfig != nil
        do { personalPresets = try self.presetStore.load() }
        catch { presetLoadFailed = true; presetError = "Could not load presets: \(error.localizedDescription)" }
        if initialConfig == nil {
            // Resolve even if the user leaves Status before its first refresh.
            DispatchQueue.global(qos: .utility).async { [weak self, controller] in
                let running = controller.agentState().pid != nil
                DispatchQueue.main.async { self?.updateServerRunning(running) }
            }
        }
    }

    /// True when the draft diverges from the on-disk config, i.e. Apply has work.
    var isDirty: Bool { draft != saved }
    var serverBusy: Bool { serverAction != nil }

    var selectedProfile: PerformanceProfile? {
        PerformanceProfile.allCases.first { $0.matches(draft) }
    }

    var appliedProfile: PerformanceProfile? {
        PerformanceProfile.allCases.first { $0.matches(saved) }
    }

    struct ProfileChange: Equatable {
        let label: String
        let saved: String
        let pending: String
    }

    var pendingProfileChanges: [ProfileChange] {
        zip(Self.profileSummary(saved), Self.profileSummary(draft)).compactMap { before, after in
            guard before.value != after.value else { return nil }
            return ProfileChange(label: before.label, saved: before.value, pending: after.value)
        }
    }

    private static func profileSummary(_ config: [String: String]) -> [(label: String, value: String)] {
        let extra = config["EXTRA_FLAGS"] ?? ""
        func number(_ key: String, flag: String, fallback: String) -> String {
            if let value = config[key], !value.isEmpty { return value }
            return extraFlagValue(flag, in: extra) ?? fallback
        }
        func toggle(_ key: String, when available: Bool = true) -> String {
            available && settingEnabled(key, in: config) ? "On" : "Off"
        }
        let physicalSize = config["CAPTURE_SIZE"] ?? ""
        let preference = VideoCodecPreference(config: config)
        let video = preference != .bitmap
        let avc444 = settingEnabled("AVC444", in: config)
        let avc = avc444 ? "H.264 AVC444" : "H.264 AVC420"
        let codec = preference == .hevc ? "Prefer H.265 (HEVC) · \(avc) fallback" : avc
        let size = config["VIRTUAL_DISPLAY"] == "1"
            ? "Virtual display · " + formattedSize(virtualResolution(config))
            : physicalSize.isEmpty
                ? (config["HIDPI"] == "1" ? "Native Retina" : "Automatic")
                : formattedSize(physicalSize)
        let fps = number("FPS", flag: "--fps", fallback: video ? "60" : "15")
        let bitrate = number("BITRATE", flag: "--bitrate", fallback: "6")
        let pacing = UInt32(pacingLimit(in: config)) ?? 0
        let flush = flushSummary(config)
        let trailing = number("FLUSH_FRAMES", flag: "--flush-frames", fallback: "4")
        return [
            ("Capture size", size),
            ("Frame rate limit", "\(fps) fps"),
            ("Bitrate ceiling", video ? "\(bitrate) Mbps" : "Unavailable"),
            ("Video codec", video ? codec : "Bitmap / RemoteFX"),
            ("H.264 Main Profile", toggle("H264_MAIN_PROFILE", when: preference == .h264 && !avc444)),
            ("Prioritize HEVC encoding speed", toggle("HEVC_HIGH_SPEED", when: preference == .hevc)),
            ("Adaptive bitrate", toggle("ADAPTIVE_BITRATE", when: video)),
            ("Capture mode", video && !avc444 && settingEnabled("CAPTURE_NV12", in: config) ? "NV12" : "Standard"),
            ("Responsive capture", toggle("RESPONSIVE_CAPTURE", when: video)),
            ("Encoder queue", video ? number("H264_FRAMES_IN_FLIGHT", flag: "--h264-frames-in-flight", fallback: "2") : "Unavailable"),
            ("Trailing frames", video ? "\(trailing) · \(flush)" : "Unavailable"),
            ("Keyframe interval", video ? number("KEYFRAME_INTERVAL", flag: "--keyframe-interval", fallback: "2.0") + " s" : "Unavailable"),
            ("Keyframes on screen changes", toggle("KEYFRAME_ON_CHANGE", when: video)),
            ("TCP video pacing", video && pacing > 0 ? "\(pacing) frames" : "Off"),
            ("UDP network offer", toggle("ENABLE_UDP_MULTITRANSPORT")),
            ("Video over UDP", toggle("UDP_MIGRATE_EGFX", when: video)),
            ("Audio format", settingEnabled("ENABLE_AAC", in: config) ? "AAC when supported" : "PCM"),
            ("Preferred audio capture", settingEnabled("AUDIO_CORE_TAP", in: config) ? "Core Audio Tap" : "ScreenCaptureKit"),
            ("Loss-resilient UDP audio", toggle("ENABLE_LOSSY_AUDIO")),
            ("Restore minimized windows", toggle("UNMINIMIZE")),
            ("Blank screen recovery", toggle("BLANK_RECOVERY")),
            ("Live performance statistics", toggle("STATS_ENDPOINT")),
        ]
    }

    private static func formattedSize(_ size: String) -> String {
        size.replacingOccurrences(of: "x", with: " × ")
    }

    var profileVirtualDisplaySize: String? {
        guard bool("VIRTUAL_DISPLAY"), !string("CAPTURE_SIZE").isEmpty else { return nil }
        return Self.formattedSize(resolution)
    }

    var validationError: String? {
        if portNumber.isEmpty || !portNumber.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
            || UInt16(portNumber).map({ $0 > 0 }) != true {
            return "Port must be a whole number from 1 to 65535."
        }
        let statsPort = string("STATS_PORT").trimmingCharacters(in: .whitespaces)
        if !statsPort.isEmpty,
           (!statsPort.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) || UInt16(statsPort).map({ $0 > 0 }) != true) {
            return "Statistics port must be a whole number from 1 to 65535, or empty for 40245."
        }
        let invalid = allowedIPTokens.filter {
            IPv4Address($0) == nil && IPv6Address($0) == nil
        }
        if !invalid.isEmpty { return "Invalid IP address: \(invalid.joined(separator: ", "))" }
        for (key, label) in [("FPS", "Frame rate"), ("H264_FRAMES_IN_FLIGHT", "Encoder queue depth")] {
            let value = draft[key] ?? ""
            if !value.isEmpty, UInt32(value).map({ $0 > 0 }) != true {
                return "\(label) must be a positive whole number."
            }
        }
        if !bitrateInput.isEmpty,
           UInt32(bitrateInput).map({ (1...2147).contains($0) }) != true {
            return "Bitrate must be whole-number Mbps from 1 to 2147 (VideoToolbox's numeric range), or empty for 6 Mbps."
        }
        if fastFlushEnabled && fastFlushInterval.isEmpty {
            return "Enter a fast-flush interval from 8 to 1000 ms, or turn Fast flush off."
        }
        let interval = fastFlushInterval
        if !interval.isEmpty, UInt64(interval).map({ (8...1000).contains($0) }) != true {
            return "Fast-flush interval must be a whole number from 8 to 1000 ms."
        }
        if UInt32(tcpPacingLimit) == nil {
            return "TCP frame limit must be a whole number from 0 to 4294967295. Use 0 to turn pacing off."
        }
        if !bool("VIRTUAL_DISPLAY"), let size = draft["CAPTURE_SIZE"], !size.isEmpty,
           !Self.validCaptureSize(size) {
            return "Resolution must use even dimensions from 200 to 8192, e.g. 2560x1440."
        }
        if !bool("VIRTUAL_DISPLAY") && customCaptureSelected && string("CAPTURE_SIZE").isEmpty {
            return "Enter a custom resolution, e.g. 2560x1600."
        }
        if draft.values.contains(where: { $0.rangeOfCharacter(from: .newlines) != nil }) {
            return "Each setting must fit on one line."
        }
        return nil
    }

    func reload() {
        let cfg = controller.readConfig()
        saved = cfg
        draft = cfg
        customCaptureSelected = false
        fastFlushSelected = false
    }

    func revert() { draft = saved; customCaptureSelected = false; fastFlushSelected = false; applyError = nil }

    /// A failed write leaves the entire draft intact and never restarts the server.
    func apply() {
        guard serverStatusKnown, !serverBusy, validationError == nil, isDirty || restartRequired else { return }
        applyError = nil
        applySuccessMessage = nil
        if isDirty {
            var candidate = draft
            if candidate["ALLOW_IP"] != nil {
                candidate["ALLOW_IP"] = allowedIPTokens.joined(separator: ",")
            }
            let changes = candidate.filter { saved[$0.key] != $0.value }
            do {
                try saveSettings(changes)
            } catch {
                applyError = "Could not save settings: \(error.localizedDescription)"
                return
            }
            saved = candidate
            draft = candidate
        } else if !restartRequired {
            return
        }
        if serverRunning || restartRequired {
            restartRequired = true
            beginServerAction(serverRunning ? .restart : .start, marksSettingsApplied: true)
        } else {
            applySuccessMessage = "Settings saved — start the server to use them"
        }
    }

    func beginServerAction(_ action: ServerAction, marksSettingsApplied: Bool = false) {
        guard serverStatusKnown, !serverBusy else { return }
        if !marksSettingsApplied { applySuccessMessage = nil }
        serverAction = action
        serverActionResult = nil
        performAction(action) { [weak self] result in
            guard let self else { return }
            self.serverAction = nil
            self.serverActionResult = result
            self.serverRunning = result.running
            if marksSettingsApplied {
                if result.success {
                    self.restartRequired = false
                    self.applyError = nil
                    self.applySuccessMessage = action == .restart
                        ? "Settings saved — server restarted" : "Settings saved — server started"
                } else {
                    self.applyError = "Settings saved, but not activated. \(result.message) Retry Apply."
                }
            } else if result.success && (action == .start || action == .restart) {
                self.restartRequired = false
                self.applyError = nil
            }
        }
    }

    /// Keep the Apply footer's cached state aligned with the Status pane's
    /// background sampler without shelling out during SwiftUI body evaluation.
    func updateServerRunning(_ running: Bool) {
        guard !serverBusy else { return }
        serverRunning = running
        serverStatusKnown = true
    }

    // MARK: - Typed value access + SwiftUI bindings

    private static let managedSwitches = [
        "CAPTURE_NV12": "--capture-nv12",
        "ALT_BACKTICK_SWITCH": "--alt-backtick-switch",
        "ALT_SPACE_SPOTLIGHT": "--alt-space-spotlight",
        "ALT_Q_QUIT": "--alt-q-quit",
        "REVERSE_SCROLL": "--reverse-scroll",
        "ENABLE_LOSSY_AUDIO": "--enable-lossy-audio",
        "AUDIO_CORE_TAP": "--audio-core-tap",
        "ENABLE_MICROPHONE_REDIRECTION": "--enable-microphone-redirection",
        "NETWORK_AUTODETECT": "--network-autodetect",
        "RICH_CLIPBOARD": "--no-rich-clipboard",
    ]

    static func settingEnabled(_ key: String, in config: [String: String], default def: Bool = false) -> Bool {
        if let value = config[key] { return value == "1" }
        guard let flag = managedSwitches[key] else { return def }
        let hasFlag = (config["EXTRA_FLAGS"] ?? "").split(whereSeparator: { $0.isWhitespace }).contains { $0 == flag }
        return key == "RICH_CLIPBOARD" ? !hasFlag : hasFlag
    }

    func bool(_ key: String, default def: Bool = false) -> Bool {
        Self.settingEnabled(key, in: draft, default: def)
    }

    func string(_ key: String, default def: String = "") -> String { draft[key] ?? def }

    func setBool(_ key: String, _ value: Bool) {
        draft[key] = value ? "1" : "0"
        if let flag = Self.managedSwitches[key] {
            let extra = string("EXTRA_FLAGS")
            let cleaned = extra.split(whereSeparator: { $0.isWhitespace })
                .filter { $0 != flag && !$0.hasPrefix(flag + "=") }
                .joined(separator: " ")
            if cleaned != extra { draft["EXTRA_FLAGS"] = cleaned }
        }
        // Honor the control the user touched: disabling H.264 must not be
        // undone by the dependent UDP-video setting during normalization.
        if key == "ENABLE_H264", !value {
            setFastFlushEnabled(false)
            if draft["UDP_MIGRATE_EGFX"] == "1" { draft["UDP_MIGRATE_EGFX"] = "0" }
        }
        normalize()
    }

    func setString(_ key: String, _ value: String) {
        draft[key] = value
        normalize()
    }

    func boolBinding(_ key: String, default def: Bool = false) -> Binding<Bool> {
        Binding(get: { self.bool(key, default: def) }, set: { self.setBool(key, $0) })
    }

    var videoCodecPreference: VideoCodecPreference { VideoCodecPreference(config: draft) }

    func setVideoCodecPreference(_ preference: VideoCodecPreference) {
        cleanExtraFlags(preference == .bitmap ? ["--enable-h264", "--avc444"] : ["--enable-h264"])
        if preference != .bitmap {
            draft["PREFER_HEVC"] = preference == .hevc ? "1" : "0"
        }
        setBool("ENABLE_H264", preference != .bitmap)
    }

    func stringBinding(_ key: String, default def: String = "") -> Binding<String> {
        Binding(get: { self.string(key, default: def) }, set: { self.setString(key, $0) })
    }

    // MARK: - Dependent-key constraints (mirror the old menu auto-enable logic)

    // Turning a PARENT off is always authoritative — it resets its dependent
    // child, never the reverse (a child requirement must not re-enable a parent
    // the user just switched off). Enabling a mode forces its parent on in the
    // setter that owns that intent (setPrimaryMode), not here. Each branch mutates
    // only when the value would actually change, so an unrelated toggle never
    // appends spurious keys, and a legacy CAPTURE_PRIMARY=1 config is left intact
    // until the user touches the display settings.
    private func normalize() {
        let mode = draft["PRIMARY_MODE"] ?? ""
        let modeActive = mode != "" && mode != "none"
        // Virtual display off => no primary-screen takeover (reset the mode +
        // retire the legacy capture flag). No "force VD on" branch: setPrimaryMode
        // already enables VD when a mode is chosen, so this can't fight a VD-off.
        if (draft["VIRTUAL_DISPLAY"] ?? "0") != "1" {
            if modeActive { draft["PRIMARY_MODE"] = "none" }
            if draft["CAPTURE_PRIMARY"] == "1" { draft["CAPTURE_PRIMARY"] = "0" }
        }
        // No headless mode => clear the lock/unlock pair. Both only run inside the
        // headless session watcher, so without a mode the server ignores them
        // (with a startup warning) and a stale ON would silently re-arm the moment
        // a mode is picked again. `primaryMode` honors a legacy CAPTURE_PRIMARY=1.
        if primaryMode == "none" {
            if draft["LOCK_ON_DISCONNECT"] == "1" { draft["LOCK_ON_DISCONNECT"] = "0" }
            if draft["AUTO_UNLOCK"] == "1" { draft["AUTO_UNLOCK"] = "0" }
        }
        // Tunnel off => clear the video-migrate child. Tunnel on + migrate on =>
        // ensure H.264 (the migrate toggle is UI-disabled until the tunnel is on,
        // so this never has to re-enable the tunnel itself).
        if (draft["ENABLE_UDP_MULTITRANSPORT"] ?? "0") != "1" {
            if draft["UDP_MIGRATE_EGFX"] == "1" { draft["UDP_MIGRATE_EGFX"] = "0" }
        } else if (draft["UDP_MIGRATE_EGFX"] ?? "0") == "1" {
            draft["ENABLE_H264"] = "1"
        }
        if (draft["ENABLE_H264"] ?? "0") != "1", draft["AVC444"] == "1" {
            draft["AVC444"] = "0"
        }
    }

    // MARK: - Network bind (loopback <-> all interfaces, port preserved)

    var bindDisplay: String { string("BIND", default: "127.0.0.1:3390") }

    var portNumber: String {
        guard let colon = bindDisplay.lastIndex(of: ":") else { return "" }
        return String(bindDisplay[bindDisplay.index(after: colon)...])
    }

    func setPortNumber(_ port: String) {
        // Preserve the exact host, including bracketed IPv6 and explicit LAN IPs.
        let host = bindDisplay.lastIndex(of: ":").map { String(bindDisplay[..<$0]) }
            ?? "127.0.0.1"
        setString("BIND", "\(host):\(port)")
    }

    var allowNetwork: Bool { bindDisplay.hasPrefix("0.0.0.0") }

    func setAllowNetwork(_ on: Bool) {
        let port = portNumber
        setString("BIND", "\(on ? "0.0.0.0" : "127.0.0.1"):\(port)")
    }

    var allowedIPTokens: [String] {
        string("ALLOW_IP")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var allowedIPDisplay: String { string("ALLOW_IP") }

    var appliedAllowedIPDisplay: String {
        let values = (saved["ALLOW_IP"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? "Any authenticated client" : values.joined(separator: ", ")
    }

    func setAllowedIPs(_ value: String) {
        setString("ALLOW_IP", value)
    }

    // MARK: - Personal presets

    var selectedPersonalPreset: PersonalPreset? {
        personalPresets.first { $0.id == personalPresetID }
    }

    func selectPersonalPreset(_ id: UUID?) {
        personalPresetID = id
        personalPresetName = selectedPersonalPreset?.name ?? ""
        presetMessage = nil
        presetError = nil
    }

    func savePersonalPreset(replace: Bool = false) {
        guard validationError == nil else { presetError = validationError; return }
        if replace && selectedPersonalPreset == nil { return }
        var values = Dictionary(uniqueKeysWithValues: PersonalPreset.allowedKeys.map { ($0, draft[$0] ?? PerformanceProfile.settingFallback($0)) })
        // Materialize legacy flags so a preset does not depend on EXTRA_FLAGS.
        values["FPS"] = frameRate
        values["BITRATE"] = bitrateMbps
        values["H264_FRAMES_IN_FLIGHT"] = encoderQueueDepth
        values["FLUSH_INTERVAL_MS"] = fastFlushInterval
        values["H264_MAX_UNACKED_FRAMES"] = tcpPacingLimit
        for key in Self.presetSwitches { values[key] = bool(key) ? "1" : "0" }
        let id = replace ? personalPresetID! : UUID()
        let preset = PersonalPreset(id: id,
            name: personalPresetName.trimmingCharacters(in: .whitespacesAndNewlines), settings: values)
        var updated = personalPresets.filter { $0.id != id }
        updated.append(preset)
        persistPresets(updated, selected: id, message: "Preset saved. Server settings are unchanged until Apply.")
    }

    func renamePersonalPreset() {
        guard var preset = selectedPersonalPreset else { return }
        preset.name = personalPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = personalPresets.map { $0.id == preset.id ? preset : $0 }
        persistPresets(updated, selected: preset.id, message: "Preset renamed.")
    }

    func deletePersonalPreset() {
        guard let id = personalPresetID else { return }
        persistPresets(personalPresets.filter { $0.id != id }, selected: nil, message: "Preset deleted. Current settings are unchanged.")
    }

    private func persistPresets(_ values: [PersonalPreset], selected: UUID?, message: String) {
        guard !presetLoadFailed else {
            presetError = "Preset storage could not be read. Fix presets.json and reopen Settings before saving."
            return
        }
        do {
            try presetStore.save(values)
            personalPresets = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            personalPresetID = selected
            personalPresetName = selectedPersonalPreset?.name ?? ""
            presetError = nil
            presetMessage = message
        } catch { presetError = error.localizedDescription; presetMessage = nil }
    }

    func loadPersonalPreset() {
        guard let preset = selectedPersonalPreset else { return }
        customCaptureSelected = false
        fastFlushSelected = false
        for key in PersonalPreset.allowedKeys.subtracting(Self.presetSwitches)
            .subtracting(["H264_MAX_UNACKED_FRAMES", "TCP_VIDEO_BACKPRESSURE"]) {
            draft[key] = preset.settings[key] ?? PerformanceProfile.settingFallback(key)
        }
        for key in Self.presetSwitches {
            if let value = preset.settings[key] { draft[key] = value }
        }
        setTCPPacingLimit(Self.pacingLimit(in: preset.settings))
        setFrameRate(preset.settings["FPS"] ?? "")
        setBitrate(preset.settings["BITRATE"] ?? "")
        setEncoderQueueDepth(preset.settings["H264_FRAMES_IN_FLIGHT"] ?? "")
        clearLegacyVideoProfileFlags()
        normalize()
        presetError = nil
        presetMessage = "Preset loaded into draft. Review settings, then Apply."
    }

    // MARK: - Performance profiles

    private static let presetSwitches = [
        "CAPTURE_NV12", "REVERSE_SCROLL", "ALT_Q_QUIT", "ALT_BACKTICK_SWITCH",
        "ALT_SPACE_SPOTLIGHT", "ENABLE_LOSSY_AUDIO", "AUDIO_CORE_TAP",
    ]

    func applyProfile(_ profile: PerformanceProfile) {
        customCaptureSelected = false
        fastFlushSelected = false
        for (key, value) in profile.settings { draft[key] = value }
        setTCPPacingLimit(profile.settings["H264_MAX_UNACKED_FRAMES"] ?? "0")
        if let depth = profile.settings["H264_FRAMES_IN_FLIGHT"] { setEncoderQueueDepth(depth) }
        if let fps = profile.settings["FPS"] { setFrameRate(fps) }
        if let bitrate = profile.settings["BITRATE"], !bitrate.isEmpty {
            setBitrate(bitrate)
        }
        clearLegacyVideoProfileFlags()
        normalize()
    }

    private func clearLegacyVideoProfileFlags() {
        cleanExtraFlags([
            "--flush-interval-ms", "--width", "--height", "--hidpi",
            "--enable-h264", "--avc444", "--adaptive-bitrate",
            "--enable-aac", "--enable-udp-multitransport", "--udp-migrate-egfx",
        ])
        if !bool("VIRTUAL_DISPLAY") {
            cleanExtraFlags(["--no-client-resolution"])
        }
    }

    static func pacingLimit(in config: [String: String]) -> String {
        if let limit = config["H264_MAX_UNACKED_FRAMES"], !limit.isEmpty { return limit }
        if let legacy = config["TCP_VIDEO_BACKPRESSURE"] { return legacy == "1" ? "3" : "0" }
        return extraFlagValue("--h264-max-unacked-frames", in: config["EXTRA_FLAGS"] ?? "") ?? "0"
    }

    var tcpPacingLimit: String { Self.pacingLimit(in: draft) }
    var tcpPacingEnabled: Bool { (UInt32(tcpPacingLimit) ?? 0) > 0 }

    func setTCPPacingLimit(_ value: String) {
        let limit = value.trimmingCharacters(in: .whitespaces)
        draft["H264_MAX_UNACKED_FRAMES"] = limit
        // Preserve the on/off choice when a user returns to the older server.
        draft["TCP_VIDEO_BACKPRESSURE"] = (UInt32(limit) ?? 0) > 0 ? "1" : "0"
        cleanExtraFlags(["--h264-max-unacked-frames"])
    }

    func setTCPPacingEnabled(_ enabled: Bool) {
        if enabled == tcpPacingEnabled { return }
        setTCPPacingLimit(enabled ? "3" : "0")
    }

    var savedTCPPacingSummary: String {
        guard saved["ENABLE_H264"] == "1" else { return "Requires H.264" }
        let limit = UInt32(Self.pacingLimit(in: saved)) ?? 0
        return limit == 0 ? "Off" : "\(limit) unacknowledged frames"
    }

    /// A stored empty key explicitly overrides old EXTRA_FLAGS values.
    var fastFlushInterval: String {
        if let value = draft["FLUSH_INTERVAL_MS"] { return value }
        return Self.extraFlagValue("--flush-interval-ms", in: string("EXTRA_FLAGS")) ?? ""
    }
    var fastFlushEnabled: Bool { fastFlushSelected || !fastFlushInterval.isEmpty }

    func setFastFlushEnabled(_ enabled: Bool) {
        let previous = fastFlushInterval
        fastFlushSelected = enabled
        draft["FLUSH_INTERVAL_MS"] = enabled ? (previous.isEmpty ? "10" : previous) : ""
        cleanExtraFlags(["--flush-interval-ms"])
    }

    func setFastFlushInterval(_ value: String) {
        fastFlushSelected = true
        draft["FLUSH_INTERVAL_MS"] = value.trimmingCharacters(in: .whitespaces)
        cleanExtraFlags(["--flush-interval-ms"])
    }

    static let capturePresets = ["1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160"]
    var captureResolutionChoice: String {
        if customCaptureSelected { return "custom" }
        let size = string("CAPTURE_SIZE")
        if !size.isEmpty { return Self.capturePresets.contains(size) ? size : "custom" }
        return bool("HIDPI") ? "hidpi" : "auto"
    }

    func setCaptureResolutionChoice(_ value: String) {
        customCaptureSelected = value == "custom"
        if value == "auto" || value == "hidpi" {
            draft["CAPTURE_SIZE"] = ""
            draft["HIDPI"] = value == "hidpi" ? "1" : "0"
        } else {
            draft["HIDPI"] = "0"
            draft["CAPTURE_SIZE"] = value == "custom" ? "2560x1600" : value
        }
        cleanExtraFlags(["--width", "--height", "--hidpi", "--no-client-resolution"])
    }

    func setCustomCaptureSize(_ value: String) {
        customCaptureSelected = true
        draft["CAPTURE_SIZE"] = value.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func validCaptureSize(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return false }
        return (200...8192).contains(width) && (200...8192).contains(height)
            && width % 2 == 0 && height % 2 == 0
    }

    private func cleanExtraFlags(_ flags: [String]) {
        let original = string("EXTRA_FLAGS")
        let cleaned = flags.reduce(original) { Self.strippingFlag($1, from: $0) }
        if cleaned != original { draft["EXTRA_FLAGS"] = cleaned }
    }

    var savedCaptureSummary: String {
        if saved["VIRTUAL_DISPLAY"] == "1" { return "Virtual display (see Display settings)" }
        let size = saved["CAPTURE_SIZE"] ?? ""
        return !size.isEmpty ? size : saved["HIDPI"] == "1" ? "Native Retina" : "Automatic / client size"
    }
    var savedFlushSummary: String { Self.flushSummary(saved) }

    private static func flushSummary(_ config: [String: String]) -> String {
        let value = config["FLUSH_INTERVAL_MS"]
            ?? extraFlagValue("--flush-interval-ms", in: config["EXTRA_FLAGS"] ?? "") ?? ""
        return value.isEmpty ? "Stable (capture cadence)" : "Fast flush · \(value) ms"
    }

    // MARK: - Primary-screen mode

    /// Effective mode, honoring a legacy `CAPTURE_PRIMARY=1` config that predates
    /// `PRIMARY_MODE` (so the picker reflects reality without rewriting the file).
    var primaryMode: String {
        let m = draft["PRIMARY_MODE"] ?? ""
        if !m.isEmpty { return m }
        return draft["CAPTURE_PRIMARY"] == "1" ? "capture" : "none"
    }

    /// Choosing a mode makes `PRIMARY_MODE` authoritative and retires the legacy
    /// `CAPTURE_PRIMARY` boolean, so the server never sees a conflicting pair.
    func setPrimaryMode(_ mode: String) {
        draft["PRIMARY_MODE"] = mode
        if mode != "none" { draft["VIRTUAL_DISPLAY"] = "1" }
        if draft["CAPTURE_PRIMARY"] == "1" { draft["CAPTURE_PRIMARY"] = "0" }
        normalize()
    }

    // MARK: - Virtual-display resolution

    var virtualDisplayScaling: VirtualDisplayScaling {
        if let value = draft["VD_HIDPI"] {
            return VirtualDisplayScaling(rawValue: value.lowercased()) ?? .standard
        }
        let flag = "--virtual-display-hidpi"
        let extra = string("EXTRA_FLAGS")
        if Self.extraFlagValue(flag, in: extra) == "auto" { return .automatic }
        return extra.split(whereSeparator: { $0.isWhitespace }).contains { $0 == flag || $0 == flag + "=on" }
            ? .retina : .standard
    }

    func setVirtualDisplayScaling(_ scaling: VirtualDisplayScaling) {
        draft["VD_HIDPI"] = scaling.rawValue
        cleanExtraFlags(["--virtual-display-hidpi"])
    }

    var resolution: String { Self.virtualResolution(draft) }

    var fixedVirtualResolution: Bool {
        if let value = draft["VD_FIXED_SIZE"] { return value == "1" }
        return string("EXTRA_FLAGS").split(whereSeparator: { $0.isWhitespace })
            .contains("--no-client-resolution")
    }

    func setFixedVirtualResolution(_ fixed: Bool) {
        draft["VD_FIXED_SIZE"] = fixed ? "1" : "0"
        cleanExtraFlags(["--no-client-resolution"])
    }

    private static func virtualResolution(_ config: [String: String]) -> String {
        "\(config["VD_WIDTH"] ?? "1920")x\(config["VD_HEIGHT"] ?? "1080")"
    }
    func setResolution(_ wxh: String) {
        let parts = wxh.split(separator: "x")
        guard parts.count == 2 else { return }
        draft["VD_WIDTH"] = String(parts[0])
        draft["VD_HEIGHT"] = String(parts[1])
        normalize()
    }

    var frameRate: String {
        if let fps = draft["FPS"], !fps.isEmpty { return fps }
        return Self.extraFlagValue("--fps", in: string("EXTRA_FLAGS")) ?? ""
    }

    func setFrameRate(_ fps: String) {
        draft["FPS"] = fps
        let extra = string("EXTRA_FLAGS")
        let cleaned = Self.strippingFlag("--fps", from: extra)
        if cleaned != extra { draft["EXTRA_FLAGS"] = cleaned }
        normalize()
    }

    var encoderQueueDepth: String {
        draft["H264_FRAMES_IN_FLIGHT"]
            ?? Self.extraFlagValue("--h264-frames-in-flight", in: string("EXTRA_FLAGS"))
            ?? ""
    }

    func setEncoderQueueDepth(_ depth: String) {
        draft["H264_FRAMES_IN_FLIGHT"] = depth.trimmingCharacters(in: .whitespaces)
        cleanExtraFlags(["--h264-frames-in-flight"])
    }

    // MARK: - H.264 bitrate ceiling (Mbit/s)

    /// Effective ceiling: the BITRATE key if set, else a `--bitrate N` left in
    /// EXTRA_FLAGS (back-compat with hand-edited configs), else the default (6).
    var bitrateMbps: String {
        if let b = draft["BITRATE"], !b.isEmpty { return b }
        if let n = Self.extraFlagValue("--bitrate", in: string("EXTRA_FLAGS")) { return n }
        return "6"
    }

    /// Keep an explicitly cleared editor empty while the effective ceiling
    /// falls back to the server's default. Legacy flags remain editable.
    var bitrateInput: String {
        if let value = draft["BITRATE"] { return value }
        return Self.extraFlagValue("--bitrate", in: string("EXTRA_FLAGS")) ?? ""
    }

    /// Set the ceiling via BITRATE and strip any `--bitrate N` from EXTRA_FLAGS so
    /// the two can never disagree (the server would otherwise take the last one).
    func setBitrate(_ mbps: String) {
        draft["BITRATE"] = mbps.trimmingCharacters(in: .whitespaces)
        let extra = string("EXTRA_FLAGS")
        let cleaned = Self.strippingFlag("--bitrate", from: extra)
        if cleaned != extra { draft["EXTRA_FLAGS"] = cleaned }
        normalize()
    }

    private static func extraFlagValue(_ flag: String, in extra: String) -> String? {
        let tokens = extra.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (index, token) in tokens.enumerated() {
            if token.hasPrefix(flag + "=") { return String(token.dropFirst(flag.count + 1)) }
            if token == flag, index + 1 < tokens.count { return tokens[index + 1] }
        }
        return nil
    }

    private static func strippingFlag(_ flag: String, from extra: String) -> String {
        let tokens = extra.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var kept: [String] = []
        var index = 0
        while index < tokens.count {
            if tokens[index] == flag {
                index += 1
                if index < tokens.count, !tokens[index].hasPrefix("--") { index += 1 }
            } else if tokens[index].hasPrefix(flag + "=") {
                index += 1
            } else {
                kept.append(tokens[index])
                index += 1
            }
        }
        return kept.joined(separator: " ")
    }

    // MARK: - Ctrl->Cmd exclude list (NO_REMAP_APPS)

    func excludeList() -> [String] {
        string("NO_REMAP_APPS")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func setExcludeList(_ apps: [String]) {
        var seen = Set<String>()
        let deduped = apps.filter { !$0.isEmpty && seen.insert($0).inserted }
        setString("NO_REMAP_APPS", deduped.joined(separator: ","))
    }

    func isExcluded(_ bundle: String) -> Bool { excludeList().contains(bundle) }

    func toggleExclude(_ bundle: String, _ on: Bool) {
        var list = excludeList()
        if on {
            if !list.contains(bundle) { list.append(bundle) }
        } else {
            list.removeAll { $0 == bundle }
        }
        setExcludeList(list)
    }

    /// Pick any .app and add its bundle id to the exclude list (draft-only; the
    /// change applies with the next Apply). Reads the id off the bundle so the
    /// user never types it.
    func addExcludeApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to keep Ctrl unmapped in"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url)?.bundleIdentifier else { return }
        var list = excludeList()
        list.append(bundle)
        setExcludeList(list)
    }

    // MARK: - Remote-desktop preset (draft-only)

    /// Stage the recommended "remote into my Mac" config in the draft (headless
    /// virtual display + detach the physical panel + H.264 + app-switcher HUD).
    /// The user reviews and hits Apply; unlike the old menu preset it does not
    /// self-install/start — Start on the tray does that.
    func applyRemoteDesktopPreset() {
        draft["VIRTUAL_DISPLAY"] = "1"
        draft["PRIMARY_MODE"] = "detach"
        draft["ENABLE_H264"] = "1"
        draft["APP_SWITCHER_HUD"] = "1"
        if (draft["VD_WIDTH"] ?? "").isEmpty { draft["VD_WIDTH"] = "1920" }
        if (draft["VD_HEIGHT"] ?? "").isEmpty { draft["VD_HEIGHT"] = "1080" }
        normalize()
    }
}
