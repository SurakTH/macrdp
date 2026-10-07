import AppKit
import SwiftUI
import Network

// The tabbed Settings window opened by "Show macrdp Controller…". A SwiftUI view hosted
// in a plain NSWindow (the status-bar item stays AppKit). While the window is
// open the app switches to a .regular activation policy so it behaves like a
// real app (Dock icon + reliable focus + a working Edit menu for the text
// fields); it drops back to .accessory (menu-bar-only) when the window closes.

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    private let onClose: () -> Void

    init(controller: AppController, onClose: @escaping () -> Void) {
        self.model = SettingsModel(controller: controller)
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 740, height: 650)
        window.title = "macrdp Controller Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty else { return true }
        let a = NSAlert()
        a.messageText = "Discard unsaved changes?"
        a.informativeText = "Some settings haven't been applied yet. Close and discard them?"
        a.addButton(withTitle: "Discard")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose()
    }
}

// MARK: - Controller wiring

extension AppController {
    /// Open (or bring forward) the Settings window.
    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(controller: self) { [weak self] in
                self?.settingsWindowController = nil
            }
        }
        settingsWindowController?.show()
    }

    /// Open the Settings window (if needed) and navigate it to a section — the
    /// action behind the main-menu "Section" items.
    @objc func selectSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let s = SettingsSection(rawValue: raw) else { return }
        showSettings()
        settingsWindowController?.model.section = s
    }

    /// A minimal main menu so the standard editing shortcuts (Cmd+C/V/X/Z/A) work
    /// in the window's text fields and Cmd+W/Cmd+Q behave. Set once at launch; it
    /// only shows while the app is .regular (the Settings window open).
    func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About macrdp Controller", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide macrdp Controller", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit macrdp Controller", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // Section menu — the same categories as the sidebar, navigable from the
        // menu bar (⌘1…⌘8). Each item drives SettingsModel.section.
        let sectionItem = NSMenuItem()
        main.addItem(sectionItem)
        let sectionMenu = NSMenu(title: "Section")
        for (i, s) in SettingsSection.allCases.enumerated() {
            let mi = NSMenuItem(
                title: s.title, action: #selector(selectSection(_:)),
                keyEquivalent: i < 9 ? String(i + 1) : "")
            mi.target = self
            mi.representedObject = s.rawValue
            sectionMenu.addItem(mi)
        }
        sectionItem.submenu = sectionMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = main
    }
}

// MARK: - Sections

/// The settings categories — shown all-at-once in the sidebar AND as a "Section"
/// menu in the main menu bar (each drives `SettingsModel.section`).
enum SettingsSection: String, CaseIterable, Identifiable {
    case status, connection, video, audio, display, input, redirection, advanced, permissions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: return "Status"
        case .connection: return "Connection"
        case .video: return "Video"
        case .audio: return "Audio"
        case .display: return "Display"
        case .input: return "Input"
        case .redirection: return "Redirection"
        case .advanced: return "Advanced"
        case .permissions: return "Permissions"
        }
    }
    var icon: String {
        switch self {
        case .status: return "gauge.medium"
        case .connection: return "network"
        case .video: return "video"
        case .audio: return "speaker.wave.2"
        case .display: return "display"
        case .input: return "keyboard"
        case .redirection: return "arrow.left.arrow.right"
        case .advanced: return "gearshape.2"
        case .permissions: return "lock.shield"
        }
    }
}

// MARK: - Root view

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // All categories visible at once (System-Settings-style sidebar).
                List(SettingsSection.allCases, selection: Binding(
                    get: { model.section },
                    set: { if let s = $0 { model.section = s } })) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
                .listStyle(.sidebar)
                .frame(width: 176)

                Divider()

                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                status
                Spacer()
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty || model.serverBusy)
                Button("Apply") { model.apply() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled((!model.isDirty && !model.restartRequired) || model.validationError != nil || model.serverBusy || !model.serverStatusKnown)
            }
            .padding(12)
        }
        .frame(minWidth: 660, minHeight: 560)
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .status: StatusView(model: model)
        case .connection: ConnectionTab(model: model)
        case .video: VideoTab(model: model)
        case .audio: AudioTab(model: model)
        case .display: DisplayTab(model: model)
        case .input: InputTab(model: model)
        case .redirection: RedirectionTab(model: model)
        case .advanced: AdvancedTab(model: model)
        case .permissions: PermissionsTab(model: model)
        }
    }

    @ViewBuilder private var status: some View {
        if !model.serverStatusKnown {
            Label("Checking server status…", systemImage: "clock")
                .font(.callout).foregroundColor(.secondary)
        } else if let error = model.validationError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundColor(.red)
        } else if let action = model.serverAction {
            Label(action.progressTitle, systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundColor(.secondary)
        } else if let error = model.applyError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isDirty {
            Label(model.serverRunning ? "Unsaved changes — Apply to save and restart" : "Unsaved changes — Apply to save",
                  systemImage: "pencil.circle")
                .font(.callout).foregroundColor(.secondary)
        } else if let message = model.applySuccessMessage {
            Label(message,
                  systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundColor(.secondary)
        } else {
            Text(model.serverRunning ? "Server running" : "Server stopped")
                .font(.callout).foregroundColor(.secondary)
        }
    }
}

// MARK: - Tabs

private struct ConnectionTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section("Performance profile") {
                Picker("Profile", selection: Binding(
                    get: { model.selectedProfile?.rawValue ?? "custom" },
                    set: { value in
                        if let profile = PerformanceProfile(rawValue: value) {
                            model.applyProfile(profile)
                        }
                    })) {
                    ForEach(PerformanceProfile.allCases) { profile in
                        Text(profile.title).tag(profile.rawValue)
                    }
                    if model.selectedProfile == nil {
                        Text("Custom").tag("custom")
                    }
                }
                .pickerStyle(.segmented)
                Text(model.selectedProfile?.detail
                    ?? "Custom settings. Choose a profile to stage its live-verified values, then Apply.")
                    .font(.caption).foregroundColor(.secondary)
                Text("Profiles change video, audio and shortcut settings only. Network access stays a separate choice below.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Network") {
                Toggle("Allow connections from the network", isOn: Binding(
                    get: { model.allowNetwork },
                    set: { on in
                        if on {
                            let a = NSAlert()
                            a.messageText = "Allow connections from the network?"
                            a.informativeText = "macrdp will listen on all interfaces (0.0.0.0), so other "
                                + "devices on your network can connect. Access still requires TLS and your "
                                + "macOS account password — enable only on a network you trust."
                            a.addButton(withTitle: "Allow")
                            a.addButton(withTitle: "Cancel")
                            NSApp.activate(ignoringOtherApps: true)
                            guard a.runModal() == .alertFirstButtonReturn else { return }
                        }
                        model.setAllowNetwork(on)
                    }))
                TextField("Port", text: Binding(
                    get: { model.portNumber }, set: { model.setPortNumber($0) }),
                    prompt: Text("3390"))
                Text("Default: 3390. Apply saves the new port and restarts a running server. Reconnect using the new address.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Text("Configured address")
                    Spacer()
                    Text(model.bindDisplay).foregroundColor(.secondary)
                }
                Text("Off = loopback only (127.0.0.1), reachable from this Mac only.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("Allowed client IPs", text: Binding(
                    get: { model.allowedIPDisplay },
                    set: { model.setAllowedIPs($0) }),
                    prompt: Text("Optional, e.g. 192.168.1.20, 192.168.1.21"))
                    .disabled(!model.allowNetwork)
                if let error = model.validationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.red)
                } else {
                    Text("Empty allows any authenticated client. Exact IPv4/IPv6 addresses only; loopback is always allowed.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section("Account") {
                Button(model.controller.hasKeychainPassword()
                    ? "Change Account Password…" : "Set Account Password…") {
                    model.controller.setPassword()
                }
                Text("Stored in your login Keychain; RDP clients authenticate against your Mac account.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Quick setup") {
                Button("Set Up Remote Desktop preset") { model.applyRemoteDesktopPreset() }
                Text("Stages a headless virtual display + detach the physical panel + H.264 + the "
                    + "app-switcher HUD. Review the Display/Video tabs, then Apply.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VideoTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section {
                Toggle("H.264 video (EGFX / AVC420)", isOn: model.boolBinding("ENABLE_H264"))
                Text("Streams the screen as H.264 — far less bandwidth than legacy bitmaps. "
                    + "Recommended. Clients without an H.264 decoder fall back automatically.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Frame rate") {
                TextField("FPS", text: Binding(get: { model.frameRate }, set: { model.setFrameRate($0) }),
                          prompt: Text("Automatic"))
                Text("Leave empty for automatic: 60 FPS with H.264, 15 FPS with bitmap video.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Bitrate") {
                Stepper(value: Binding(
                    get: { Int(model.bitrateMbps) ?? 6 },
                    set: { model.setBitrate(String($0)) }), in: 1...50) {
                    Text("Ceiling: \(model.bitrateMbps) Mbps")
                }
                .disabled(!model.bool("ENABLE_H264"))
                Toggle("Adaptive bitrate (lower under congestion)", isOn: model.boolBinding("ADAPTIVE_BITRATE"))
                    .disabled(!model.bool("ENABLE_H264"))
                Text("The ceiling is the maximum. With Adaptive on, the server drops below it "
                    + "under congestion (thin/lossy link) and climbs back when it clears; on a "
                    + "clean link it stays at the ceiling. H.264 only.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Capture resolution") {
                Picker("Physical screen", selection: Binding(
                    get: { model.captureResolutionChoice },
                    set: { model.setCaptureResolutionChoice($0) })) {
                    Text("Automatic — follow client").tag("auto")
                    Text("Native Retina").tag("hidpi")
                    ForEach(SettingsModel.capturePresets, id: \.self) { size in
                        Text(size.replacingOccurrences(of: "x", with: " × ")).tag(size)
                    }
                    Text("Custom…").tag("custom")
                }
                .disabled(model.bool("VIRTUAL_DISPLAY"))
                if model.captureResolutionChoice == "custom" {
                    TextField("Width × height", text: Binding(
                        get: { model.string("CAPTURE_SIZE") },
                        set: { model.setCustomCaptureSize($0) }), prompt: Text("2560x1600"))
                        .disabled(model.bool("VIRTUAL_DISPLAY"))
                }
                Text(model.bool("VIRTUAL_DISPLAY")
                    ? "Virtual-display resolution is configured in Display. Your physical-screen selection is retained."
                    : "1080p is the tested starting point for typing. Higher resolutions sharpen detail but increase load. Fixed sizes stay fixed when the client window changes.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Experimental") {
                Toggle("Fast flush (optional)", isOn: Binding(
                    get: { model.fastFlushEnabled },
                    set: { model.setFastFlushEnabled($0) }))
                    .disabled(!model.bool("ENABLE_H264"))
                if model.fastFlushEnabled {
                    TextField("Interval (ms)", text: Binding(
                        get: { model.fastFlushInterval },
                        set: { model.setFastFlushInterval($0) }), prompt: Text("10"))
                        .disabled(!model.bool("ENABLE_H264"))
                    HStack {
                        Text("Try:").foregroundColor(.secondary)
                        ForEach([8, 10, 12, 16], id: \.self) { interval in
                            Button("\(interval) ms") { model.setFastFlushInterval(String(interval)) }
                                .controlSize(.small)
                                .disabled(!model.bool("ENABLE_H264"))
                        }
                    }
                    Text("8–1000 ms. Lower values send the same trailing pictures closer together; capture FPS and bitrate stay the same.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Text("Off by default. May make typing feel faster, but can increase image artifacts. "
                    + "Turn off to restore stable video. Apply restarts a running server.")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("AVC444 diagnostics", isOn: model.boolBinding("AVC444"))
                    .disabled(!model.bool("ENABLE_H264"))
                Text("Known issue: tested mstsc clients render severe gray/pink color corruption. "
                    + "Use Ultimate or LAN Max for real work.")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AudioTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section {
                Toggle("AAC audio", isOn: model.boolBinding("ENABLE_AAC"))
                Text("Compresses forwarded audio as AAC-LC (~11× less bandwidth than PCM). Clients "
                    + "without AAC fall back to PCM. Adds ~40–50 ms latency, so it's off by default.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplayTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section("Virtual display") {
                Toggle("Headless virtual display", isOn: model.boolBinding("VIRTUAL_DISPLAY"))
                Text("Serves a headless display at the resolution below instead of mirroring the "
                    + "physical panel — the local Mac screen stays free.")
                    .font(.caption).foregroundColor(.secondary)
                Picker("Resolution", selection: Binding(
                    get: { model.resolution }, set: { model.setResolution($0) })) {
                    ForEach(AppController.resolutions, id: \.2) { w, h, label in
                        Text(label).tag("\(w)x\(h)")
                    }
                }
                .disabled(!model.bool("VIRTUAL_DISPLAY"))
            }
            Section("Primary screen (while connected)") {
                Picker("Physical panel", selection: Binding(
                    get: { model.primaryMode }, set: { model.setPrimaryMode($0) })) {
                    Text("Keep local screen on").tag("none")
                    Text("Detach — move apps to remote").tag("detach")
                    Text("Blank — keep apps on Mac (lockable)").tag("shield")
                    Text("Blank — keep apps on Mac (can't lock)").tag("capture")
                }
                .pickerStyle(.radioGroup)
                Text("Detach/Blank auto-enable the virtual display. “Blank (can't lock)” uses capture — "
                    + "while engaged the Mac CANNOT be locked. “Blank (lockable)” shields with a black "
                    + "window and stays lockable.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct InputTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section("Keyboard") {
                Picker("Layout", selection: model.stringBinding("KEYBOARD_LAYOUT", default: "")) {
                    ForEach(AppController.keyboardLayouts, id: \.0) { spec, label in
                        Text(label).tag(spec)
                    }
                }
                Text("Auto-detected from the client by default. Pick one to force it; the Mac's own "
                    + "input source is never changed.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Windows shortcuts") {
                Toggle("Remap Ctrl → Cmd (copy/paste etc.)", isOn: model.boolBinding("MAP_CTRL_TO_CMD"))
                if model.bool("MAP_CTRL_TO_CMD") {
                    ExcludeAppsView(model: model)
                }
            }
            Section("App switching") {
                Toggle("Option+Tab switches apps", isOn: model.boolBinding("ALT_TAB_SWITCH"))
                Toggle("App-switcher HUD overlay", isOn: model.boolBinding("APP_SWITCHER_HUD"))
                Toggle("Un-minimize on Cmd+Tab", isOn: model.boolBinding("UNMINIMIZE"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExcludeAppsView: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        let custom = model.excludeList().filter { bundle in
            !AppController.remapExcludeApps.contains { $0.0 == bundle }
        }
        Text("Keep Ctrl unmapped in these apps (e.g. editors with an embedded terminal, so Ctrl+C "
            + "stays SIGINT). Standalone terminals are auto-excluded.")
            .font(.caption).foregroundColor(.secondary)
        ForEach(AppController.remapExcludeApps, id: \.0) { bundle, label in
            Toggle(label, isOn: Binding(
                get: { model.isExcluded(bundle) },
                set: { model.toggleExclude(bundle, $0) }))
        }
        ForEach(custom, id: \.self) { bundle in
            Toggle(bundle, isOn: Binding(
                get: { model.isExcluded(bundle) },
                set: { model.toggleExclude(bundle, $0) }))
        }
        HStack {
            Button("Add app…") { model.addExcludeApp() }
            if !model.excludeList().isEmpty {
                Button("Clear list") { model.setExcludeList([]) }
            }
        }
    }
}

private struct RedirectionTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Text("The connecting client must also opt in to each redirection.")
                .font(.caption).foregroundColor(.secondary)
            Section("Drive") {
                Toggle("Drive redirection", isOn: model.boolBinding("ENABLE_DRIVE_REDIRECTION"))
                Text("The client's drive mounts on the Mac as a real volume (read-write).")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Smart card") {
                Toggle("Smart-card redirection", isOn: model.boolBinding("ENABLE_SMARTCARD_REDIRECTION"))
                Button("Install smart-card handler…") { model.controller.installSmartcardHandler() }
                Text("The handler must be installed once (needs admin + a USB trigger device).")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Camera") {
                Toggle("Camera redirection", isOn: model.boolBinding("ENABLE_CAMERA_REDIRECTION"))
                Button("Enable macrdp Camera…") { model.controller.enableCameraRedirection() }
                Text("Presents the client's webcam as a “macrdp Camera” in Photo Booth / Zoom / "
                    + "FaceTime. The system extension must be enabled once.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section("UDP multitransport (experimental)") {
                Toggle("Offer UDP multitransport", isOn: model.boolBinding("ENABLE_UDP_MULTITRANSPORT"))
                Toggle("Move video onto UDP (clean link only)", isOn: model.boolBinding("UDP_MIGRATE_EGFX"))
                    .disabled(!model.bool("ENABLE_UDP_MULTITRANSPORT"))
                Text("Moving video onto the reliable UDP tunnel helps on a clean, low-latency link, "
                    + "but under packet loss the picture can freeze until reconnect (audio stays on "
                    + "TCP). Auto-enables H.264. LAN/Wi-Fi only.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Diagnostics") {
                Toggle("Live statistics endpoint", isOn: model.boolBinding("STATS_ENDPOINT"))
                Text("Lets the Status tab show live video bitrate, link RTT and frame-rate. "
                    + "Loopback-only (127.0.0.1), read-only, no disk writes. Takes effect after Apply.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Extra flags") {
                TextField("Extra flags", text: model.stringBinding("EXTRA_FLAGS"), prompt: Text("e.g. --stretch"))
                Text("For options not covered by these controls. Use the Video tab to adjust frame rate and bitrate.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section {
                Button("Edit config.env directly…") { model.controller.editConfig() }
                Button("Open Logs") { model.controller.openLogs() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var screen: Bool?
    @State private var accessibility: Bool?

    var body: some View {
        Form {
            Text("macrdp needs these grants (owned by the server binary, not this controller). "
                + "Status is read from the server log.")
                .font(.caption).foregroundColor(.secondary)
            Section("Screen Recording") {
                permRow(granted: screen) { model.controller.openScreenRecording() }
            }
            Section("Accessibility") {
                permRow(granted: accessibility) { model.controller.openAccessibility() }
            }
            Button("Refresh status") { refresh() }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let ps = model.controller.permissionStatus()
        screen = ps.screen
        accessibility = ps.accessibility
    }

    @ViewBuilder private func permRow(granted: Bool?, open: @escaping () -> Void) -> some View {
        HStack {
            switch granted {
            case .some(true):
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundColor(.green)
            case .some(false):
                Label("Not granted", systemImage: "xmark.circle.fill").foregroundColor(.red)
            case .none:
                Label("Unknown — open to grant", systemImage: "questionmark.circle").foregroundColor(.secondary)
            }
            Spacer()
            Button("Open System Settings…", action: open)
        }
    }
}

// MARK: - Status (live, read-only)

/// Process-level stats sampled from `ps` (no server change needed).
struct ServerStats {
    let running: Bool
    let pid: Int
    let uptime: String
    let rssMB: Double
    let cpu: Double
    let memPct: Double
    static let stopped = ServerStats(running: false, pid: 0, uptime: "", rssMB: 0, cpu: 0, memPct: 0)
}

/// The currently-connected RDP client, from `lsof` (established TCP on the RDP
/// port) + the server log's fingerprint line.
struct ConnectionInfo {
    let connected: Bool
    let ip: String?
    let name: String?
    let build: String?
    static let none = ConnectionInfo(connected: false, ip: nil, name: nil, build: nil)
}

/// Live H.264 telemetry from the server's opt-in loopback stats endpoint.
struct LiveStats {
    let processId: Int
    let width: Int
    let height: Int
    let bitrateBps: Int
    let ceilingBps: Int
    let rttMs: Int
    let queueMs: Int
    let fps: Int
    let frames: Int
    let adaptive: Bool
}

private struct StatusView: View {
    @ObservedObject var model: SettingsModel
    @State private var stats: ServerStats = .stopped
    @State private var conn: ConnectionInfo = .none
    @State private var live: LiveStats?
    private var externalServer: Bool { !stats.running && (live?.processId ?? 0) > 0 }
    @State private var connectTarget = "—"
    @State private var copiedAddress = false
    // Only ticks while this pane is on screen (subscription cancels on disappear).
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Server") {
                row("Status", model.serverAction?.progressTitle
                    ?? (!model.serverStatusKnown ? "Checking…" : model.serverRunning
                        ? (stats.running ? "Running (pid \(stats.pid))" : "Running")
                        : "Stopped"))
                row("Profile", model.appliedProfile?.title ?? "Custom")
                row("Saved capture", model.savedCaptureSummary)
                row("Saved flush", model.savedFlushSummary)
                if externalServer, let pid = live?.processId {
                    Label("Terminal server detected (pid \(pid))", systemImage: "terminal")
                    Text("These controls manage the installed server. Stop the terminal test before starting it here. Live video statistics below belong to the terminal server.")
                        .font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    Text("Connect to")
                    Spacer()
                    Text(connectTarget).foregroundColor(.secondary).textSelection(.enabled)
                    Button(copiedAddress ? "Copied" : "Copy address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(connectTarget, forType: .string)
                        copiedAddress = true
                    }
                    .controlSize(.small)
                    .disabled(connectTarget == "—" || connectTarget.contains("<"))
                    .help("Copy the address to enter in your RDP client")
                }
                row("Allowed clients", model.appliedAllowedIPDisplay)
                if stats.running {
                    row("Uptime", stats.uptime.isEmpty ? "—" : stats.uptime)
                    row("Memory", String(format: "%.0f MB  (%.1f%% of RAM)", stats.rssMB, stats.memPct))
                    row("CPU", String(format: "%.1f%%", stats.cpu))
                }
                HStack {
                    Button(model.serverRunning ? "Restart Server" : "Start Server") {
                        model.beginServerAction(model.serverRunning ? .restart : .start)
                    }
                    .disabled(model.serverBusy || !model.serverStatusKnown || externalServer)
                    if model.serverRunning {
                        Button("Stop Server") {
                            model.beginServerAction(.stop)
                        }
                        .disabled(model.serverBusy || !model.serverStatusKnown)
                    }
                    Spacer()
                    Button("Repair Installation") { model.beginServerAction(.repair) }
                        .disabled(model.serverBusy || !model.serverStatusKnown || externalServer)
                        .help("Rebuild the LaunchAgent with the current macrdp.app path, then start it")
                }
                if model.serverBusy {
                    ProgressView().controlSize(.small)
                } else if let result = model.serverActionResult, !result.cancelled {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(result.message,
                              systemImage: result.success
                                ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundColor(result.success ? .secondary : .red)
                            .fixedSize(horizontal: false, vertical: true)
                        if result.needsPermissionAttention {
                            Button("Open Privacy Settings…") {
                                model.controller.openScreenRecording()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            Section("Connection") {
                if conn.connected {
                    row("Client", conn.name ?? "connected")
                    if let ip = conn.ip { row("Address", ip) }
                    if let b = conn.build { row("Windows build", b) }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(!model.serverStatusKnown ? "Checking server status…" : model.serverRunning ? "Waiting for an RDP client" : "Start the server to connect")
                        Text("In your RDP client, enter the address above and sign in with your Mac account.")
                            .font(.caption).foregroundColor(.secondary)
                        if !(model.saved["ALLOW_IP"] ?? "").isEmpty {
                            Text("Your client's IP must match Allowed clients above. You can edit the list in Connection settings.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Button("Connection Settings") { model.section = .connection }
                            .controlSize(.small)
                    }
                }
            }
            if conn.connected || externalServer {
                Section("Video telemetry") {
                    if let l = live {
                        if l.width > 0 && l.height > 0 { row("Session size", "\(l.width) × \(l.height)") }
                        row("Bitrate", bitrateText(l))
                        row("Capture FPS limit", "\(l.fps) fps")
                        if l.rttMs > 0 { row("Link RTT", "\(l.rttMs) ms") }
                        if l.adaptive { row("Standing queue", "\(l.queueMs) ms") }
                        row("Frames sent", "\(l.frames)")
                    } else {
                        Text("Turn on “Live statistics endpoint” in Advanced (then Apply) to see "
                            + "bitrate, link RTT and frame-rate here. Shown only over H.264.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        // Gather off the main thread — serverStats/currentConnection/liveStats each
        // shell out (launchctl/ps/lsof/nc); doing that on the main thread every 2 s
        // would jank the UI. Publish the results back on main.
        let controller = model.controller
        DispatchQueue.global(qos: .utility).async {
            let s = controller.serverStats()
            let c = controller.currentConnection()
            let l = (c.connected || !s.running) ? controller.liveStats() : nil
            let target = controller.connectionTarget()
            DispatchQueue.main.async {
                stats = s
                conn = c
                live = l
                if connectTarget != target { copiedAddress = false }
                connectTarget = target
                model.updateServerRunning(s.running)
            }
        }
    }

    private func bitrateText(_ l: LiveStats) -> String {
        let mbps = Double(l.bitrateBps) / 1_000_000
        if l.adaptive, l.ceilingBps > 0 {
            return String(format: "%.1f Mbps  (ceiling %.0f)", mbps, Double(l.ceilingBps) / 1_000_000)
        }
        return String(format: "%.1f Mbps", mbps)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text(value).foregroundColor(.secondary).textSelection(.enabled)
        }
    }
}

// MARK: - Stats gathering + About (controller-side, no server change)

/// Pull `client_name=…` / `client_build=…` style values out of a log line.
private func logCapture(_ line: String, _ pattern: String) -> String? {
    guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
    let m = String(line[r])
    if let eq = m.firstIndex(of: "=") { return String(m[m.index(after: eq)...]) }
    return m
}

extension AppController {
    /// Address to type into an RDP client. For an all-interface bind, resolve
    /// the active default-route interface so the UI shows a useful LAN address
    /// instead of the non-connectable 0.0.0.0 wildcard.
    func connectionTarget() -> String {
        let config = readConfig()
        let bind = config["BIND"] ?? "127.0.0.1:3390"
        let port = bind.split(separator: ":").last.map(String.init) ?? "3390"
        guard bind.hasPrefix("0.0.0.0:") else { return bind }
        // Prefer the interface actually routed to an allowed Windows client;
        // the internet default route may be on another LAN or a VPN.
        let clients = (config["ALLOW_IP"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { IPv4Address($0) != nil }
        let preferred = clients.lazy.compactMap { self.localLANAddress(to: $0) }.first
        return "\(preferred ?? localLANAddress() ?? "<Mac LAN IP>"):\(port)"
    }

    private func localLANAddress(to client: String = "default") -> String? {
        let route = run("/sbin/route", ["-n", "get", client])
        guard route.code == 0 else { return nil }
        let interface = route.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("interface:") }?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespaces)
        guard let interface, !interface.isEmpty else { return nil }
        let address = run("/usr/sbin/ipconfig", ["getifaddr", interface])
        guard address.code == 0 else { return nil }
        let value = address.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Live RSS / CPU / uptime of the server process (via `ps`).
    func serverStats() -> ServerStats {
        guard let pid = agentState().pid else { return .stopped }
        let out = run("/bin/ps", ["-o", "rss=,%cpu=,etime=,%mem=", "-p", String(pid)])
        let f = out.stdout.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard f.count >= 4 else {
            return ServerStats(running: true, pid: pid, uptime: "—", rssMB: 0, cpu: 0, memPct: 0)
        }
        return ServerStats(
            running: true, pid: pid, uptime: f[2],
            rssMB: (Double(f[0]) ?? 0) / 1024, cpu: Double(f[1]) ?? 0, memPct: Double(f[3]) ?? 0)
    }

    /// The connected RDP client, if any (established TCP on the RDP port via
    /// `lsof`, with client name/build best-effort from the server log).
    func currentConnection() -> ConnectionInfo {
        guard let pid = agentState().pid else { return .none }
        let port = (readConfig()["BIND"] ?? "127.0.0.1:3390").split(separator: ":").last.map(String.init) ?? "3390"
        let out = run("/usr/sbin/lsof", ["-nP", "-p", String(pid), "-iTCP", "-sTCP:ESTABLISHED"])
        var ip: String?
        for raw in out.stdout.split(separator: "\n") {
            let line = String(raw)
            guard let arrow = line.range(of: "->") else { continue }
            // The RDP client connection is the one whose LOCAL endpoint is the RDP
            // port (loopback helper channels have other local ports).
            guard line[..<arrow.lowerBound].hasSuffix(":\(port)") else { continue }
            let host = line[arrow.upperBound...].split(separator: ":").first.map(String.init)
            if let h = host, h != "127.0.0.1", h != "::1", !h.isEmpty { ip = h; break }
        }
        guard let clientIP = ip else { return .none }
        var name: String?
        var build: String?
        for line in logTail() where line.contains("client fingerprint client_name=") {
            name = logCapture(line, #"client_name=(\S+)"#)   // later lines win
            build = logCapture(line, #"client_build=(\d+)"#)
        }
        return ConnectionInfo(connected: true, ip: clientIP, name: name, build: build)
    }

    /// Live H.264 telemetry from the server's opt-in loopback stats endpoint
    /// (nil if it isn't enabled / not reachable). `nc` reads the single JSON line
    /// the endpoint writes on connect, then exits when the server closes; `</dev/null`
    /// so it never waits on stdin and `-w 1` caps it if the port isn't listening.
    func liveStats() -> LiveStats? {
        // The port is interpolated into a shell command below, and config.env is
        // user-editable — so validate it's a real port number (digits, 1…65535).
        // A non-numeric value can never reach the shell; it falls back to 40245.
        let raw = readConfig()["STATS_PORT"].flatMap { $0.isEmpty ? nil : $0 } ?? "40245"
        let port = UInt16(raw).flatMap { $0 == 0 ? nil : String($0) } ?? "40245"
        let out = run("/bin/bash", ["-c", "/usr/bin/nc -w 1 127.0.0.1 \(port) </dev/null 2>/dev/null"])
        guard let data = out.stdout.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func int(_ k: String) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }
        func bool(_ k: String) -> Bool { (o[k] as? NSNumber)?.boolValue ?? false }
        return LiveStats(
            processId: int("process_id"), width: int("width"), height: int("height"),
            bitrateBps: int("bitrate_bps"), ceilingBps: int("ceiling_bps"),
            rttMs: int("rtt_ms"), queueMs: int("queue_delay_ms"),
            fps: int("fps"), frames: int("frames_sent"), adaptive: bool("adaptive"))
    }

    /// The standard macOS About panel, populated with the app version + a short
    /// description + the live server status.
    @objc func showAbout() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let st = cachedAgentStateSnapshot
        let statusLine: String
        if let pid = st.pid { statusLine = "Server: running (pid \(pid))" }
        else if st.loaded { statusLine = "Server: installed, stopped" }
        else { statusLine = "Server: not installed" }
        let body = "Native RDP server for macOS.\n\n"
            + "RDP clients connect over TLS to your Mac and get the desktop with keyboard, "
            + "mouse, clipboard and audio — plus optional H.264 video, headless virtual "
            + "displays, and drive / smart-card / camera / USB redirection.\n\n"
            + statusLine + "\n\n"
            + "Maintained by SurakTH. Based on macrdp by Clint Canada and its contributors. "
            + "Fork-specific improvements were developed with assistance from OpenAI Codex "
            + "using GPT-5.6 Sol. Licensed under MIT OR Apache-2.0."
        let opts: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "macrdp Controller",
            .applicationVersion: version,
            .credits: NSAttributedString(
                string: body,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]),
        ]
        NSApp.orderFrontStandardAboutPanel(options: opts)
    }
}
