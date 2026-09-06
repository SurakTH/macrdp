import AppKit
import Network
import SwiftUI

/// The live-verified launcher presets, expressed as config.env keys so the
/// installed app and the terminal launchers select the same runtime behavior.
/// Network exposure is deliberately not part of a performance profile; the
/// user enables LAN access separately and sees the existing security warning.
enum PerformanceProfile: String, CaseIterable, Identifiable {
    case ultimate, lan, native, fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultimate: return "Ultimate"
        case .lan: return "LAN Max"
        case .native: return "Native"
        case .fast: return "Fast"
        }
    }

    var detail: String {
        switch self {
        case .ultimate:
            return "Best overall balance: AVC420 at 60 FPS, 25 Mbps adaptive, UDP offered, AAC."
        case .lan:
            return "Highest live-verified LAN quality: HiDPI AVC420, 60 FPS, 50 Mbps, stable TCP and PCM."
        case .native:
            return "Sharpest text and UI: HiDPI bitmap/RemoteFX at a stable 12 FPS."
        case .fast:
            return "Lowest latency: AVC420 at 60 FPS, 50 Mbps and a minimal one-frame pipeline."
        }
    }

    var settings: [String: String] {
        var values = [
            "AVC444": "0",
            "MAP_CTRL_TO_CMD": "1",
            "ALT_TAB_SWITCH": "1",
            "UDP_MIGRATE_EGFX": "0",
            "KEYFRAME_INTERVAL": "2.0",
            "KEYFRAME_CHANGE_PCT": "20",
            "KEYFRAME_CLICK_PCT": "5",
            "H264_FRAMES_IN_FLIGHT": "2",
            "FLUSH_FRAMES": "4",
            "STATS_ENDPOINT": "1",
        ]
        switch self {
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
        }
        return values
    }

    func matches(_ config: [String: String]) -> Bool {
        settings.allSatisfy { config[$0.key, default: ""] == $0.value }
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

    init(controller: AppController,
         initialConfig: [String: String]? = nil,
         saveSettings: (([String: String]) throws -> Void)? = nil,
         performAction: ((ServerAction, @escaping (ServerActionResult) -> Void) -> Void)? = nil) {
        self.controller = controller
        self.saveSettings = saveSettings ?? { [unowned controller] in try controller.saveConfig(changes: $0) }
        self.performAction = performAction ?? { [unowned controller] in controller.performServerAction($0, completion: $1) }
        if initialConfig == nil { controller.ensureConfigExists() }
        let cfg = initialConfig ?? controller.readConfig()
        self.saved = cfg
        self.draft = cfg
        self.serverRunning = controller.cachedServerRunning
        self.serverStatusKnown = initialConfig != nil
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

    var validationError: String? {
        if portNumber.isEmpty || !portNumber.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
            || UInt16(portNumber).map({ $0 > 0 }) != true {
            return "Port must be a whole number from 1 to 65535."
        }
        let invalid = allowedIPTokens.filter {
            IPv4Address($0) == nil && IPv6Address($0) == nil
        }
        if !invalid.isEmpty { return "Invalid IP address: \(invalid.joined(separator: ", "))" }
        for (key, label) in [("FPS", "Frame rate"), ("BITRATE", "Bitrate")] {
            let value = draft[key] ?? ""
            if !value.isEmpty, UInt32(value).map({ $0 > 0 }) != true {
                return "\(label) must be a positive whole number."
            }
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
    }

    func revert() { draft = saved; applyError = nil }

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

    func bool(_ key: String, default def: Bool = false) -> Bool {
        (draft[key] ?? (def ? "1" : "0")) == "1"
    }

    func string(_ key: String, default def: String = "") -> String { draft[key] ?? def }

    func setBool(_ key: String, _ value: Bool) {
        draft[key] = value ? "1" : "0"
        // Honor the control the user touched: disabling H.264 must not be
        // undone by the dependent UDP-video setting during normalization.
        if key == "ENABLE_H264", !value {
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

    // MARK: - Performance profiles

    func applyProfile(_ profile: PerformanceProfile) {
        for (key, value) in profile.settings { draft[key] = value }
        if let fps = profile.settings["FPS"] { setFrameRate(fps) }
        if let bitrate = profile.settings["BITRATE"], !bitrate.isEmpty {
            setBitrate(bitrate)
        }
        normalize()
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

    var resolution: String {
        "\(string("VD_WIDTH", default: "1920"))x\(string("VD_HEIGHT", default: "1080"))"
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

    // MARK: - H.264 bitrate ceiling (Mbit/s)

    /// Effective ceiling: the BITRATE key if set, else a `--bitrate N` left in
    /// EXTRA_FLAGS (back-compat with hand-edited configs), else the default (6).
    var bitrateMbps: String {
        if let b = draft["BITRATE"], !b.isEmpty { return b }
        if let n = Self.extraFlagValue("--bitrate", in: string("EXTRA_FLAGS")) { return n }
        return "6"
    }

    /// Set the ceiling via BITRATE and strip any `--bitrate N` from EXTRA_FLAGS so
    /// the two can never disagree (the server would otherwise take the last one).
    func setBitrate(_ mbps: String) {
        draft["BITRATE"] = mbps
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
