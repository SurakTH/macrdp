import AppKit
import ControllerCore
import Darwin
import UniformTypeIdentifiers

enum ServerAction: Equatable {
    case start
    case restart
    case stop
    case repair

    var progressTitle: String {
        switch self {
        case .start: return "Starting…"
        case .restart: return "Restarting…"
        case .stop: return "Stopping…"
        case .repair: return "Repairing…"
        }
    }
}

struct ServerActionResult {
    let success: Bool
    let message: String
    let running: Bool
    let repaired: Bool
    let needsPermissionAttention: Bool
    let cancelled: Bool

    init(
        success: Bool,
        message: String,
        running: Bool,
        repaired: Bool,
        needsPermissionAttention: Bool,
        cancelled: Bool = false
    ) {
        self.success = success
        self.message = message
        self.running = running
        self.repaired = repaired
        self.needsPermissionAttention = needsPermissionAttention
        self.cancelled = cancelled
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private struct StartupLogMarker {
    let main: UInt64
    let stderr: UInt64
}

// macrdp Controller: a menu-bar app that controls the macrdp LaunchAgent
// (label io.github.surakth.macrdp by default in this fork)
// and toggles flags in config.env. It is a *controller* — quitting it leaves
// the server running under launchd. It needs no TCC grants of its own (it only
// runs `launchctl`, opens URLs, and edits files in the user's own Library);
// the Screen Recording / Accessibility grants belong to the macrdp binary.

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Lazy so the controller can be instantiated for the headless --install-agent
    // path without touching the status bar (which needs a GUI app context).
    lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    /// The server's LaunchAgent label, derived from this controller's own bundle
    /// id by stripping the ".controller" suffix — so whatever BUNDLE_PREFIX the
    /// app was built with, the controller drives the matching agent. Falls back
    /// to the default prefix for unbundled `swift run` during development.
    let label: String = {
        if let bid = Bundle.main.bundleIdentifier, bid.hasSuffix(".controller") {
            return String(bid.dropLast(".controller".count))
        }
        return "io.github.surakth.macrdp"
    }()

    var uid: String { String(getuid()) }
    var domain: String { "gui/\(uid)" }
    var service: String { "gui/\(uid)/\(label)" }

    var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    var configURL: URL { home.appendingPathComponent("Library/Application Support/macrdp/config.env") }
    var logURL: URL { home.appendingPathComponent("Library/Logs/macrdp.log") }
    // The server owns + rotates macrdp.log itself; stderr (panics, pre-logging
    // startup errors) goes to a small separate file.
    var errLogURL: URL { home.appendingPathComponent("Library/Logs/macrdp.err.log") }
    var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }

    var timer: Timer?
    private let lifecycleQueue = DispatchQueue(label: "io.github.surakth.macrdp.controller.lifecycle",
                                               qos: .userInitiated)
    private(set) var activeServerAction: ServerAction?
    private var cachedAgentState: (loaded: Bool, pid: Int?) = (false, nil)
    private var glyphRefreshInFlight = false
    var cachedServerRunning: Bool { cachedAgentState.pid != nil }
    var cachedAgentStateSnapshot: (loaded: Bool, pid: Int?) { cachedAgentState }

    /// The tabbed Settings window (SettingsWindow.swift); nil while closed.
    var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
        installMainMenu() // so the Settings window's text fields get edit shortcuts
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "macrdp Controller")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self          // menuNeedsUpdate rebuilds on every open
        statusItem.menu = menu
        rebuildMenu()
        refreshGlyph()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshGlyph()
        }
        // A Finder launch must visibly do something. The controller can stay a
        // menu-bar app after the window closes, but its initial launch opens the
        // Settings/Status window instead of appearing to do nothing.
        DispatchQueue.main.async { [weak self] in self?.showSettings() }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { showSettings() }
        return true
    }

    // MARK: - Agent state

    /// (loaded, pid). loaded=false means the agent isn't bootstrapped at all;
    /// pid=nil while loaded means installed but not currently running.
    func agentState() -> (loaded: Bool, pid: Int?) {
        let out = run("/bin/launchctl", ["print", service])
        guard out.code == 0 else { return (false, nil) }
        if let r = out.stdout.range(of: #"pid = (\d+)"#, options: .regularExpression) {
            let pid = out.stdout[r].split(separator: "=").last
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return (true, pid)
        }
        return (true, nil)
    }

    func refreshGlyph() {
        guard !glyphRefreshInFlight else { return }
        glyphRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let st = self.agentState()
            DispatchQueue.main.async {
                self.cachedAgentState = st
                self.glyphRefreshInFlight = false
                let running = st.pid != nil
                // Dim the menu-bar icon when the server isn't running so state
                // is glanceable without opening the menu.
                self.statusItem.button?.alphaValue = running ? 1.0 : 0.4
                self.statusItem.button?.toolTip = running
                    ? "macrdp Controller: running (pid \(st.pid!))"
                    : (st.loaded
                        ? "macrdp Controller: stopped" : "macrdp Controller: not installed")
            }
        }
    }

    // MARK: - Server status (parsed from the log)

    /// Last ~32 KB of the server log split into lines (oldest first).
    func logTail() -> [String] {
        guard let h = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 32 * 1024
        try? h.seek(toOffset: size > window ? size - window : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Latest TCC grant state the server logged (nil = not seen in recent log).
    /// The server logs "<X> permission already granted" / "<X> permission NOT
    /// granted" at startup; we can't query another process's TCC directly.
    func permissionStatus() -> (screen: Bool?, accessibility: Bool?) {
        var screen: Bool?
        var ax: Bool?
        for line in logTail() { // later lines win → most recent startup
            if line.contains("Screen Recording permission already granted") { screen = true } else if line
                .contains("Screen Recording permission NOT granted") { screen = false }
            if line.contains("Accessibility permission already granted") { ax = true } else if line
                .contains("Accessibility permission NOT granted") { ax = false }
        }
        return (screen, ax)
    }

    /// Most recent error worth surfacing (auth failure / port in use / panic).
    func lastServerError() -> String? {
        for raw in logTail().reversed() {
            let line = raw.replacingOccurrences(
                of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
            if line.contains("authentication failed") { return "Login failed — check the account password" }
            if line.contains("Address already in use") { return "Port in use — another server is bound to :3390" }
            if line.contains("panicked") { return "Server crashed — see Open Logs" }
        }
        return nil
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let st = cachedAgentState
        let header: String
        if let action = activeServerAction { header = "macrdp Controller — \(action.progressTitle)" }
        else if !st.loaded { header = "macrdp Controller — not installed" }
        else if let pid = st.pid { header = "macrdp Controller — running (pid \(pid))" }
        else { header = "macrdp Controller — stopped" }
        let h = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        h.isEnabled = false
        menu.addItem(h)
        // Surface a server error (auth/port/crash) right under the header so a
        // silent crash-loop isn't invisible.
        if st.pid == nil, let err = lastServerError() {
            let e = NSMenuItem(title: "⚠️ \(err)", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        menu.addItem(.separator())

        // Show the tabbed Settings window (where all the config options now live).
        menu.addItem(item("Show macrdp Controller…", #selector(showSettings)))
        menu.addItem(.separator())

        let running = st.pid != nil
        if let action = activeServerAction {
            let busy = NSMenuItem(title: action.progressTitle, action: nil, keyEquivalent: "")
            busy.isEnabled = false
            menu.addItem(busy)
        } else if running {
            menu.addItem(item("Stop", #selector(stop)))
            menu.addItem(item("Restart", #selector(restart)))
        } else {
            // Start self-installs the LaunchAgent + onboards the password on
            // first run, so it's always actionable (no Terminal step needed).
            menu.addItem(item(st.loaded ? "Start" : "Start (first run sets up)", #selector(start)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Controller", #selector(quit)))
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    // MARK: - Actions

    @objc func start() {
        performMenuAction(.start)
    }

    @objc func stop() {
        performMenuAction(.stop)
    }

    @objc func restart() { performMenuAction(.restart) }

    @objc func repairInstallation() { performMenuAction(.repair) }

    private func performMenuAction(_ action: ServerAction) {
        performServerAction(action) { [weak self] result in
            guard let self else { return }
            if !result.success, !result.cancelled {
                self.alert(style: .critical, "Couldn't \(action == .stop ? "stop" : "start") macrdp",
                           result.message)
            } else if action == .repair {
                self.alert(style: .informational, "Installation repaired", result.message)
            } else if result.needsPermissionAttention {
                self.remindPermissions()
            }
        }
    }

    /// Run launchctl and startup verification away from AppKit's main thread.
    /// Password onboarding remains on the main thread because it presents an
    /// NSAlert; every potentially blocking lifecycle command runs serially here.
    func performServerAction(
        _ action: ServerAction,
        completion: @escaping (ServerActionResult) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeServerAction == nil else {
            completion(ServerActionResult(
                success: false,
                message: "Another server operation is already in progress.",
                running: cachedServerRunning,
                repaired: false,
                needsPermissionAttention: false))
            return
        }

        var serverApp: URL?
        if action != .stop {
            guard let located = locateServerApp() else {
                completion(ServerActionResult(
                    success: false,
                    message: "Move both macrdp.app and macrdp Controller.app into Applications, "
                        + "then try again.",
                    running: cachedServerRunning,
                    repaired: false,
                    needsPermissionAttention: false))
                return
            }
            serverApp = located
            if !hasKeychainPassword(), !promptAndStorePassword() {
                completion(ServerActionResult(
                    success: false, message: "Start cancelled.", running: cachedServerRunning,
                    repaired: false, needsPermissionAttention: false, cancelled: true))
                return
            }
        }

        activeServerAction = action
        rebuildMenu()
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            let result: ServerActionResult
            if action == .stop {
                result = self.stopServerNow()
            } else {
                result = self.startServerNow(serverApp: serverApp!, forceRepair: action == .repair)
            }
            DispatchQueue.main.async {
                self.activeServerAction = nil
                self.refreshGlyph()
                self.rebuildMenu()
                completion(result)
            }
        }
    }

    // MARK: - Headless entry (scripted/MDM deploy + testing)

    /// Runs the install logic without the GUI. `--print-paths` is side-effect
    /// free; `--install-agent` locates the server, writes + loads the agent
    /// (assumes the Keychain password is set separately for unattended deploys).
    func runHeadless(_ args: [String]) -> Int32 {
        if args.contains("--print-paths") {
            let serverApp = locateServerApp()
            let plistTarget = readLaunchAgentPlist().flatMap(LaunchAgentSpec.programPath(in:))
            let loadedTarget = registeredAgentProgramPath()
            print("label:      \(label)")
            print("bind:       \(readConfig()["BIND"] ?? "127.0.0.1:3390")")
            print("server app: \(serverApp?.path ?? "NOT FOUND")")
            print("plist target: \(plistTarget ?? "NOT INSTALLED")")
            print("loaded target: \(loadedTarget ?? "NOT LOADED")")
            print("plist:      \(plistURL.path)")
            print("config:     \(configURL.path)")
            print("log:        \(logURL.path)")
            print("password:   \(hasKeychainPassword() ? "set" : "MISSING")")
            if let serverApp {
                let spec = launchAgentSpec(serverApp: serverApp)
                let current = readLaunchAgentPlist()
                let loaded = agentState().loaded
                let needsRepair = spec.requiresRepair(
                    plist: current,
                    loadedProgramPath: loadedTarget,
                    isLoaded: loaded,
                    fileExists: FileManager.default.fileExists(atPath:)
                )
                print("agent:      \(needsRepair ? "NEEDS REPAIR" : "current")")
            }
            return 0
        }
        guard let serverApp = locateServerApp() else {
            FileHandle.standardError.write(Data(
                "error: macrdp.app not found next to the controller or in /Applications\n".utf8))
            return 1
        }
        let result = startServerNow(serverApp: serverApp, forceRepair: true)
        guard result.success else {
            FileHandle.standardError.write(Data("error: \(result.message)\n".utf8))
            return 1
        }
        print("installed: \(plistURL.path) -> \(serverApp.path)")
        print(result.message)
        if !hasKeychainPassword() {
            print("note: Keychain password not set — store it with:")
            print("  security add-generic-password -U -s macrdp -a \(NSUserName()) -w '<password>'")
        }
        return 0
    }

    // MARK: - Self-install

    /// Locate the server bundle (`macrdp.app`): next to this controller first
    /// (the usual case — both dragged into the same folder), then the standard
    /// install locations.
    func locateServerApp() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("macrdp.app"),
            URL(fileURLWithPath: "/Applications/macrdp.app"),
            home.appendingPathComponent("Applications/macrdp.app"),
        ]
        let fm = FileManager.default
        return candidates.first {
            fm.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/macrdp").path)
        }
    }

    func launchAgentSpec(serverApp: URL) -> LaunchAgentSpec {
        let bin = serverApp.appendingPathComponent("Contents/MacOS/macrdp").path
        return LaunchAgentSpec(
            label: label,
            serverBinaryPath: bin,
            configPath: configURL.path,
            stderrPath: errLogURL.path
        )
    }

    func readLaunchAgentPlist() -> [String: Any]? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    /// launchd caches the job definition at bootstrap time. Comparing only the
    /// plist on disk misses a manually replaced plist whose already-loaded job
    /// still points somewhere else, so reconciliation checks both views.
    func registeredAgentProgramPath() -> String? {
        let result = run("/bin/launchctl", ["print", service], timeout: 4)
        guard result.code == 0 else { return nil }
        for raw in result.stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("program = ") {
                return String(line.dropFirst("program = ".count))
            }
        }
        return nil
    }

    /// Atomically write the complete LaunchAgent contract. The caller unloads a
    /// stale registered job before replacing its plist, so launchd can never
    /// retain an old executable path after the apps move.
    func writeLaunchAgent(_ spec: LaunchAgentSpec) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: logURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: spec.propertyList, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private func stopServerNow() -> ServerActionResult {
        if !agentState().loaded {
            return ServerActionResult(
                success: true, message: "Server was already stopped.", running: false,
                repaired: false, needsPermissionAttention: false)
        }
        let stopped = unloadAgent()
        if let error = stopped {
            return ServerActionResult(
                success: false, message: error, running: agentState().pid != nil,
                repaired: false, needsPermissionAttention: false)
        }
        return ServerActionResult(
            success: true, message: "Server stopped.", running: false,
            repaired: false, needsPermissionAttention: false)
    }

    private func startServerNow(serverApp: URL, forceRepair: Bool) -> ServerActionResult {
        let logMarker = startupLogMarker()
        ensureConfigExists()
        let spec = launchAgentSpec(serverApp: serverApp)
        let existing = readLaunchAgentPlist()
        let previousProgram = existing.flatMap(LaunchAgentSpec.programPath(in:))
        let loadedState = agentState()
        let loadedProgram = loadedState.loaded ? registeredAgentProgramPath() : nil
        let requiresRepair = spec.requiresRepair(
            plist: existing,
            loadedProgramPath: loadedProgram,
            isLoaded: loadedState.loaded,
            fileExists: FileManager.default.fileExists(atPath:)
        )
        let shouldRepair = forceRepair || requiresRepair

        if shouldRepair {
            if let error = unloadAgent() {
                return ServerActionResult(
                    success: false, message: error, running: agentState().pid != nil,
                    repaired: false, needsPermissionAttention: false)
            }
            do {
                try writeLaunchAgent(spec)
            } catch {
                return ServerActionResult(
                    success: false,
                    message: "Couldn't write \(plistURL.path): \(error.localizedDescription)",
                    running: false, repaired: false, needsPermissionAttention: false)
            }
        }

        // A newly bootstrapped RunAtLoad job may already be starting. Use a
        // non-destructive kickstart in that case: `-k` would kill the fresh
        // process inside launchd's 10-second minimum-runtime window and trigger
        // a throttle delay. An already-loaded job is intentionally restarted.
        let wasLoaded = agentState().loaded
        if let error = loadAgent() {
            return ServerActionResult(
                success: false, message: error, running: false,
                repaired: shouldRepair, needsPermissionAttention: false)
        }

        let kickArgs = wasLoaded
            ? ["kickstart", "-k", service]
            : ["kickstart", service]
        let kick = run("/bin/launchctl", kickArgs, timeout: 8)
        guard kick.code == 0 else {
            return ServerActionResult(
                success: false,
                message: commandFailure("launchctl couldn't start the server", result: kick),
                running: false, repaired: shouldRepair, needsPermissionAttention: false)
        }

        guard let pid = waitForStableServer() else {
            let failure = serverStartupFailure(since: logMarker)
            return ServerActionResult(
                success: false, message: failure, running: false,
                repaired: shouldRepair,
                needsPermissionAttention: failure.contains("Screen Recording"))
        }

        let permissions = permissionStatus()
        let needsPermissionAttention = permissions.screen != true || permissions.accessibility != true
        var message = "Server is running (pid \(pid))."
        if shouldRepair {
            if let previousProgram, previousProgram != spec.serverBinaryPath {
                message += " Repaired the old LaunchAgent path to \(spec.serverBinaryPath)."
            } else {
                message += " LaunchAgent registration was repaired."
            }
        }
        if needsPermissionAttention {
            message += " macOS privacy permissions still need attention."
        }
        return ServerActionResult(
            success: true, message: message, running: true, repaired: shouldRepair,
            needsPermissionAttention: needsPermissionAttention)
    }

    /// Unregister the live job and wait until launchd has actually forgotten it;
    /// rewriting the plist without this step is exactly what left the released
    /// controller pointing at ~/Applications after the apps moved.
    private func unloadAgent() -> String? {
        guard agentState().loaded else { return nil }
        let result = run("/bin/launchctl", ["bootout", service], timeout: 8)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if !agentState().loaded { return nil }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if !agentState().loaded { return nil }
        return commandFailure("launchd wouldn't unload the existing server", result: result)
    }

    /// Bootstrap with bounded retries for launchd's documented EIO teardown
    /// race, then verify the job is registered before attempting kickstart.
    private func loadAgent() -> String? {
        if agentState().loaded { return nil }
        let enabled = run("/bin/launchctl", ["enable", service], timeout: 8)
        if enabled.code != 0 {
            return commandFailure("launchd couldn't enable the server", result: enabled)
        }
        var last = (code: Int32(1), stdout: "")
        for _ in 0..<5 {
            last = run("/bin/launchctl", ["bootstrap", domain, plistURL.path], timeout: 8)
            if agentState().loaded { return nil }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return commandFailure("launchd couldn't load the server", result: last)
    }

    /// Require a PID to remain present across two samples. This catches the
    /// common "kickstart returned success, process immediately crashed" case.
    private func waitForStableServer() -> Int? {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let pid = agentState().pid {
                Thread.sleep(forTimeInterval: 0.6)
                if agentState().pid != nil { return pid }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func commandFailure(
        _ prefix: String,
        result: (code: Int32, stdout: String)
    ) -> String {
        let detail = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.code == 124 { return "\(prefix): the command timed out." }
        return detail.isEmpty ? "\(prefix) (exit \(result.code))." : "\(prefix): \(detail)"
    }

    private func startupLogMarker() -> StartupLogMarker {
        StartupLogMarker(main: fileSize(logURL), stderr: fileSize(errLogURL))
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Read only output produced by the current start attempt. Old TCC or port
    /// errors must not be blamed for an unrelated future crash. If log rotation
    /// replaced the file during startup, read the new file from the beginning.
    private func textSince(_ offset: UInt64, in url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = offset <= size ? offset : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func serverStartupFailure(since marker: StartupLogMarker) -> String {
        let err = textSince(marker.stderr, in: errLogURL)
        if err.contains("NoShareableContent") || err.contains("declined TCC") {
            return "Screen Recording permission isn't granted to macrdp.app. Enable it in "
                + "System Settings → Privacy & Security, then start the server again."
        }
        let recent = textSince(marker.main, in: logURL)
        if recent.contains("Screen Recording permission NOT granted") {
            return "Screen Recording permission isn't granted to macrdp.app. Enable it in "
                + "System Settings → Privacy & Security, then start the server again."
        }
        if recent.contains("Address already in use") {
            return "Port 3390 is already in use by another process."
        }
        let state = run("/bin/launchctl", ["print", service], timeout: 4).stdout
        if let range = state.range(of: #"last exit code = [^\n]+"#, options: .regularExpression) {
            return "The server exited during startup (\(state[range])). Open Logs for details."
        }
        return "The server didn't stay running. Open Logs for the startup error."
    }

    // MARK: - Keychain password onboarding

    /// The server (run headless by launchd) reads its account password from the
    /// Keychain via the `security` CLI, so we write it the same way — keeping the
    /// item's access context as /usr/bin/security so no read-time prompt appears.
    func hasKeychainPassword() -> Bool {
        run("/usr/bin/security", ["find-generic-password", "-s", "macrdp", "-a", NSUserName()]).code == 0
    }

    @discardableResult
    func promptAndStorePassword() -> Bool {
        let a = NSAlert()
        a.messageText = "Enter your macOS account password"
        a.informativeText = "macrdp authenticates RDP clients against your Mac account and "
            + "starts headless via launchd, so the password is stored in your login Keychain. "
            + "It never leaves this Mac."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Account password for \(NSUserName())"
        a.accessoryView = field
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return false }
        let r = run("/usr/bin/security",
                    ["add-generic-password", "-U", "-s", "macrdp", "-a", NSUserName(),
                     "-w", field.stringValue])
        if r.code != 0 {
            alert(style: .critical, "Couldn't save password", "Keychain returned an error.")
            return false
        }
        return true
    }

    @objc func setPassword() { promptAndStorePassword() }

    func remindPermissions() {
        let a = NSAlert()
        a.messageText = "Grant macrdp two permissions"
        a.informativeText = "macrdp needs Screen Recording (to share the display) and "
            + "Accessibility (to forward keyboard/mouse). Enable macrdp.app in System "
            + "Settings → Privacy & Security, then it'll work."
        a.addButton(withTitle: "Open Privacy Settings")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openScreenRecording() }
    }

    func alert(style: NSAlert.Style, _ message: String, _ info: String) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = message
        a.informativeText = info
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        _ = a.runModal()
    }

    /// An attached USB device, for the smart-card trigger picker.
    struct UsbDevice {
        let vid: String // "0x2174" (4-digit lowercase hex)
        let pid: String // "0x2100"
        let label: String // human-readable name
    }

    /// Enumerate attached USB devices via `ioreg -a -r -c IOUSBHostDevice`, which
    /// emits an XML-plist array of device dicts (idVendor/idProduct as decimal
    /// ints, plus name strings). We deliberately use ioreg, NOT
    /// `system_profiler SPUSBDataType`: some USB-C devices (e.g. a Transcend
    /// ESD310C SSD — the dev trigger) are visible in ioreg but never appear in
    /// the SPUSBDataType tree, so a system_profiler-based picker silently misses
    /// them. install-ifd-handler.sh's hint dump already uses ioreg for the same
    /// reason. VID/PID are formatted as the 4-digit lowercase hex the bundle's
    /// Info.plist wants.
    func usbDevices() -> [UsbDevice] {
        let out = run("/usr/sbin/ioreg", ["-a", "-r", "-c", "IOUSBHostDevice"])
        guard out.code == 0, let data = out.stdout.data(using: .utf8),
              let list = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [[String: Any]] else { return [] }
        func hex4(_ any: Any?) -> String? {
            // idVendor/idProduct come as NSNumber; tolerate a string too.
            if let n = any as? Int { return String(format: "0x%04x", n & 0xFFFF) }
            if let s = any as? String, let n = Int(s) { return String(format: "0x%04x", n & 0xFFFF) }
            return nil
        }
        var devices: [UsbDevice] = []
        var seen = Set<String>()
        for it in list {
            guard let vid = hex4(it["idVendor"]), let pid = hex4(it["idProduct"]) else { continue }
            let name = (it["USB Product Name"] as? String)
                ?? (it["IORegistryEntryName"] as? String) ?? "USB device"
            let man = (it["USB Vendor Name"] as? String) ?? ""
            let label = (man.isEmpty || name.contains(man)) ? name : "\(name) (\(man))"
            // De-dupe identical VID/PID (e.g. two of the same stick) by key.
            let key = "\(vid):\(pid):\(label)"
            if seen.insert(key).inserted { devices.append(UsbDevice(vid: vid, pid: pid, label: label)) }
        }
        return devices
    }

    enum TriggerChoice {
        case cancel // abort the install
        case keepDefault // install, leave the bundle's baked-in trigger
        case device(vid: String, pid: String) // install, rebind to this device
    }

    /// Show a native popup of attached USB devices to use as the smart-card load
    /// trigger (macOS loads the IFD driver only on a USB hotplug whose VID/PID
    /// match the bundle). Returns the user's choice; "Keep default" leaves the
    /// trigger unchanged, a device rebinds it via IFD_VID/IFD_PID.
    func pickUsbTrigger() -> TriggerChoice {
        let devices = usbDevices()
        let a = NSAlert()
        a.messageText = "Choose the USB trigger device"
        a.informativeText = "macOS loads the smart-card driver only while a USB device with a "
            + "matching ID is plugged in. Pick the device you'll keep attached as the trigger "
            + "(any USB stick works), or choose \u{201C}Keep default trigger\u{201D} to leave it "
            + "unchanged."
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        popup.addItem(withTitle: "Keep default trigger")
        for d in devices { popup.addItem(withTitle: "\(d.label)  —  \(d.vid):\(d.pid)") }
        a.accessoryView = popup
        a.window.initialFirstResponder = popup
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return .cancel }
        let idx = popup.indexOfSelectedItem
        if idx <= 0 { return .keepDefault }
        let d = devices[idx - 1]
        return .device(vid: d.vid, pid: d.pid)
    }

    /// One-time privileged install of the smart-card IFD handler (the toggle only
    /// flips the server flag; the handler still has to be copied into the system
    /// drivers dir). Lets the user pick the USB trigger device from a popup
    /// (matching the CLI's select-usb-trigger.sh), passes it to the embedded
    /// installer as IFD_VID/IFD_PID, then runs it (it prompts for admin via its
    /// own GUI dialog).
    @objc func installSmartcardHandler() {
        func say(_ msg: String, _ info: String) {
            let a = NSAlert()
            a.messageText = msg
            a.informativeText = info
            a.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            _ = a.runModal()
        }
        guard let app = locateServerApp() else {
            say("macrdp.app not found", "Install macrdp.app first, then run this again.")
            return
        }
        let installer = app.appendingPathComponent("Contents/Resources/install-ifd-handler.sh").path
        guard FileManager.default.fileExists(atPath: installer) else {
            say("Installer not found",
                "This macrdp.app build doesn't bundle the smart-card handler installer.")
            return
        }
        var env: [String: String] = [:]
        var picked: String?
        switch pickUsbTrigger() {
        case .cancel: return
        case .keepDefault: break
        case let .device(vid, pid):
            env["IFD_VID"] = vid
            env["IFD_PID"] = pid
            picked = "\(vid):\(pid)"
        }
        let out = run("/bin/bash", [installer], env: env)
        if out.code == 0 {
            let trigger = picked.map { "the chosen trigger device (\($0))" } ?? "the USB trigger device"
            say("Smart-card handler installed",
                "Unplug/replug \(trigger) so macOS loads the driver, and make sure "
                    + "the connecting client redirects its smart card.")
        } else {
            say("Install failed",
                out.stdout.isEmpty
                    ? "The installer exited with code \(out.code)." : String(out.stdout.suffix(800)))
        }
    }

    // Standard 16:9 virtual-display resolutions, highest 1440p; default 1920×1080.
    static let resolutions: [(Int, Int, String)] = [
        (1280, 720, "1280 × 720"),
        (1600, 900, "1600 × 900"),
        (1920, 1080, "1920 × 1080 (1080p)"),
        (2560, 1440, "2560 × 1440 (1440p)"),
    ]

    /// (bundle id, menu label) curated shortcuts for the Ctrl→Cmd exclude list —
    /// common editors with an embedded terminal that can't be auto-detected.
    /// Anything else is added via "Add an app…" (which reads the bundle id off the
    /// chosen .app, so no need to know it).
    static let remapExcludeApps: [(String, String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"),
        ("com.microsoft.VSCodeInsiders", "VS Code — Insiders"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
    ]

    /// (config value, menu label) for the keyboard-layout picker. The empty
    /// value = no translation (positional keycodes / US ANSI). Values match the
    /// short names `--keyboard-layout` accepts.
    static let keyboardLayouts: [(String, String)] = [
        ("", "US / default (no translation)"),
        ("british", "British"),
        ("french", "French (AZERTY)"),
        ("german", "German (QWERTZ)"),
        ("swissgerman", "Swiss German"),
        ("spanish", "Spanish"),
        ("italian", "Italian"),
        ("portuguese", "Portuguese"),
        ("brazilian", "Portuguese (Brazil)"),
        ("dutch", "Dutch"),
        ("belgian", "Belgian"),
        ("swedish", "Swedish"),
        ("norwegian", "Norwegian"),
        ("danish", "Danish"),
        ("finnish", "Finnish"),
        ("russian", "Russian"),
        ("polish", "Polish"),
        ("czech", "Czech"),
        ("hungarian", "Hungarian"),
    ]

    @objc func editConfig() { ensureConfigExists(); NSWorkspace.shared.open(configURL) }
    @objc func openLogs() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }
        NSWorkspace.shared.open(logURL)
    }
    @objc func openScreenRecording() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
    @objc func openAccessibility() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    @objc func quit() { NSApp.terminate(nil) }

    func openURL(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    // MARK: - config.env IO

    func readConfig() -> [String: String] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [:] }
        var d: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            d[k] = v
        }
        return d
    }

    func writeConfig(key: String, value: String) {
        ensureConfigExists()
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        var found = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if k == key { lines[i] = "\(key)=\(value)"; found = true; break }
        }
        if !found { lines.append("\(key)=\(value)") }
        // Always end with exactly one trailing newline — a config file with no
        // final newline makes a downstream append concatenate onto the last
        // key (which silently corrupted VD_HEIGHT + a new key once).
        let body = lines.joined(separator: "\n")
        let out = body.hasSuffix("\n") ? body : body + "\n"
        try? out.write(to: configURL, atomically: true, encoding: .utf8)
    }

    func ensureConfigExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: configURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configURL.path) {
            let defaults = """
            BIND="127.0.0.1:3390"
            ALLOW_IP=""
            USE_KEYCHAIN=1
            ENABLE_H264=0
            ENABLE_AAC=0
            HIDPI=0
            UNMINIMIZE=0
            APP_SWITCHER_HUD=0
            ALT_TAB_SWITCH=0
            ENABLE_DRIVE_REDIRECTION=0
            ENABLE_SMARTCARD_REDIRECTION=0
            VIRTUAL_DISPLAY=0
            PRIMARY_MODE=none
            VD_WIDTH=1920
            VD_HEIGHT=1080
            EXTRA_FLAGS=""

            """
            try? defaults.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Process helper

    func run(
        _ path: String,
        _ args: [String],
        env: [String: String]? = nil,
        timeout: TimeInterval = 15
    )
        -> (code: Int32, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env = env, !env.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            p.environment = merged
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }

        // Drain concurrently so a verbose child can't fill the pipe and
        // deadlock. The deadline also prevents a wedged launchctl/security
        // invocation from leaving the Controller in a permanent busy state.
        let output = ProcessOutputBuffer()
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.store(pipe.fileHandleForReading.readDataToEndOfFile())
            readerDone.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        let timedOut = p.isRunning
        if timedOut {
            p.terminate()
            let terminateDeadline = Date().addingTimeInterval(0.5)
            while p.isRunning, Date() < terminateDeadline { usleep(25_000) }
            if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        _ = readerDone.wait(timeout: .now() + 1)
        return (timedOut ? 124 : p.terminationStatus, output.string())
    }
}

// Headless entry for scripted/MDM deploy + testing (no GUI, no status bar).
let cliArgs = CommandLine.arguments
if cliArgs.contains("--install-agent") || cliArgs.contains("--print-paths") {
    exit(AppController().runHeadless(cliArgs))
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
