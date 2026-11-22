import XCTest
import ControllerCore
@testable import macrdptray

final class SettingsModelTests: XCTestCase {
    private var controller: AppController!
    override func setUp() { controller = AppController() }
    override func tearDown() { controller = nil }

    func testTCPPacingEditsCanonicalLimitAndMatchesEffectiveConfig() throws {
        let original = """
        ENABLE_H264=1
        H264_MAX_UNACKED_FRAMES=0
        TCP_VIDEO_BACKPRESSURE=1
        EXTRA_FLAGS="--h264-max-unacked-frames 20 --fps 60"
        """
        var persisted = original
        let model = SettingsModel(controller: controller, initialConfig: ConfigurationFile.parse(original),
            saveSettings: { persisted = try ConfigurationFile.merging(changes: $0, into: persisted) })
        XCTAssertFalse(model.tcpPacingEnabled)
        XCTAssertEqual(model.savedTCPPacingSummary, "Off")
        XCTAssertFalse(model.isDirty)
        model.setTCPPacingEnabled(true)
        XCTAssertEqual(model.tcpPacingLimit, "3")
        for value in ["-1", "2.5", "4294967296", "invalid"] {
            model.setTCPPacingLimit(value)
            XCTAssertNotNil(model.validationError)
            model.apply()
            XCTAssertEqual(persisted, original)
        }
        model.setTCPPacingLimit("4")
        XCTAssertNil(model.validationError)
        model.apply()
        XCTAssertEqual(model.savedTCPPacingSummary, "4 unacknowledged frames")
        XCTAssertEqual(ConfigurationFile.parse(persisted)["H264_MAX_UNACKED_FRAMES"], "4")
        XCTAssertEqual(ConfigurationFile.parse(persisted)["EXTRA_FLAGS"], "--fps 60")
        model.setTCPPacingEnabled(false)
        XCTAssertEqual(model.tcpPacingLimit, "0")
        XCTAssertEqual(model.draft["TCP_VIDEO_BACKPRESSURE"], "0")
        model.revert()
        XCTAssertEqual(model.tcpPacingLimit, "4")
        model.applyProfile(.stable)
        XCTAssertFalse(model.tcpPacingEnabled)
        XCTAssertEqual(model.selectedProfile, .stable)
        XCTAssertEqual(SettingsModel.pacingLimit(in: ["TCP_VIDEO_BACKPRESSURE": "1"]), "3")
        XCTAssertEqual(SettingsModel.pacingLimit(in: ["EXTRA_FLAGS": "--h264-max-unacked-frames=6"]), "6")
    }

    func testNewOptionsReadLegacyFlagsAndStayInDraftUntilApply() {
        var writes: [[String: String]] = []
        let model = SettingsModel(controller: controller, initialConfig: [
            "ENABLE_H264": "1",
            "VIRTUAL_DISPLAY": "1",
            "EXTRA_FLAGS": "--virtual-display-hidpi auto --network-autodetect --no-rich-clipboard --stretch",
        ], saveSettings: { writes.append($0) })
        XCTAssertEqual(model.virtualDisplayScaling, .automatic)
        XCTAssertTrue(model.bool("NETWORK_AUTODETECT"))
        XCTAssertFalse(model.bool("RICH_CLIPBOARD"))
        model.setVirtualDisplayScaling(.retina)
        model.setBool("NETWORK_AUTODETECT", false)
        model.setBool("RICH_CLIPBOARD", true)
        model.setBool("CAPTURE_NV12", true)
        model.setBool("ALT_SPACE_SPOTLIGHT", true)
        XCTAssertTrue(writes.isEmpty)
        model.apply()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0]["VD_HIDPI"], "1")
        XCTAssertEqual(writes[0]["NETWORK_AUTODETECT"], "0")
        XCTAssertEqual(writes[0]["RICH_CLIPBOARD"], "1")
        XCTAssertEqual(writes[0]["CAPTURE_NV12"], "1")
        XCTAssertEqual(writes[0]["ALT_SPACE_SPOTLIGHT"], "1")
        XCTAssertEqual(writes[0]["EXTRA_FLAGS"], "--stretch")
        XCTAssertFalse(model.bool("NETWORK_AUTODETECT"))
        XCTAssertTrue(model.bool("RICH_CLIPBOARD"))
    }

    func testFourKPreviewStagesVideoAndStableCanRestoreItsDefaults() {
        var initial = PerformanceProfile.stable.settings
        initial.merge(["VIRTUAL_DISPLAY": "1", "VD_WIDTH": "2560", "VD_HEIGHT": "1440",
                       "BIND": "127.0.0.1:4390",
                       "EXTRA_FLAGS": "--avc444 --enable-h264 --enable-udp-multitransport --stretch"]) { _, new in new }
        let model = SettingsModel(controller: controller, initialConfig: initial)
        model.applyProfile(.fourK)
        XCTAssertEqual(model.selectedProfile, .fourK)
        XCTAssertTrue(model.bool("CAPTURE_NV12"))
        XCTAssertTrue(model.bool("RESPONSIVE_CAPTURE"))
        XCTAssertEqual(model.frameRate, "60")
        XCTAssertEqual(model.captureResolutionChoice, "3840x2160")
        XCTAssertEqual(model.bitrateMbps, "60")
        XCTAssertEqual(model.encoderQueueDepth, "2")
        XCTAssertFalse(model.fastFlushEnabled)
        XCTAssertFalse(model.tcpPacingEnabled)
        XCTAssertEqual(model.resolution, "2560x1440")
        XCTAssertEqual(model.bindDisplay, "127.0.0.1:4390")
        XCTAssertEqual(model.draft["EXTRA_FLAGS"], "--stretch")
        let preview = model.draft
        model.applyProfile(.fourKText)
        XCTAssertEqual(model.selectedProfile, .fourKText)
        XCTAssertEqual(model.bitrateMbps, "100")
        XCTAssertEqual(model.draft, preview.merging(["BITRATE": "100"]) { _, new in new })
        model.applyProfile(.stable)
        XCTAssertEqual(model.selectedProfile, .stable)
        XCTAssertEqual(model.captureResolutionChoice, "1920x1080")
        XCTAssertEqual(model.encoderQueueDepth, "2")
        XCTAssertFalse(model.bool("CAPTURE_NV12"))
    }

    func testPerformanceProfilesPreviewEffectiveChangesAndPreserveShortcuts() {
        var initial = PerformanceProfile.stable.settings
        initial["MAP_CTRL_TO_CMD"] = "0"
        initial["EXTRA_FLAGS"] = "--alt-tab-switch"
        let model = SettingsModel(controller: controller, initialConfig: initial)
        XCTAssertEqual(model.selectedProfile, .stable)
        XCTAssertTrue(model.pendingProfileChanges.isEmpty)
        model.applyProfile(.fourKText)
        XCTAssertEqual(model.selectedProfile, .fourKText)
        XCTAssertEqual(model.draft["MAP_CTRL_TO_CMD"], "0")
        XCTAssertNil(model.draft["ALT_TAB_SWITCH"])
        XCTAssertEqual(model.draft["EXTRA_FLAGS"], "--alt-tab-switch")
        XCTAssertTrue(model.pendingProfileChanges.contains(.init(
            label: "Capture size", saved: "1920 × 1080", pending: "3840 × 2160")))
        XCTAssertTrue(model.pendingProfileChanges.contains(.init(
            label: "Bitrate ceiling", saved: "60 Mbps", pending: "100 Mbps")))
        XCTAssertNil(model.profileVirtualDisplaySize)
        model.revert()
        XCTAssertTrue(model.pendingProfileChanges.isEmpty)

        initial.merge(["VIRTUAL_DISPLAY": "1", "VD_WIDTH": "2560", "VD_HEIGHT": "1440"]) { _, new in new }
        let virtual = SettingsModel(controller: controller, initialConfig: initial)
        virtual.applyProfile(.fourKText)
        XCTAssertEqual(virtual.profileVirtualDisplaySize, "2560 × 1440")
        XCTAssertFalse(virtual.pendingProfileChanges.contains { $0.label == "Capture size" })
    }

    func testLegacyAndNewPersonalPresetsPreservePacingAndIndependentSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PersonalPresetStore(url: folder.appendingPathComponent("presets.json"))
        let legacy = PersonalPreset(name: "Old", settings: ["ENABLE_H264": "1", "TCP_VIDEO_BACKPRESSURE": "1"])
        try store.save([legacy])
        let model = SettingsModel(controller: controller, initialConfig: [
            "ENABLE_H264": "1", "VD_HIDPI": "auto", "VIRTUAL_DISPLAY": "1",
            "EXTRA_FLAGS": "--h264-max-unacked-frames=8 --network-autodetect",
            "ALT_SPACE_SPOTLIGHT": "1", "RICH_CLIPBOARD": "0",
        ], presetStore: store)
        model.selectPersonalPreset(legacy.id)
        model.loadPersonalPreset()
        XCTAssertEqual(model.tcpPacingLimit, "3")
        XCTAssertTrue(model.bool("ALT_SPACE_SPOTLIGHT"))
        XCTAssertEqual(model.virtualDisplayScaling, .automatic)
        model.setTCPPacingLimit("5")
        model.setBool("CAPTURE_NV12", true)
        model.personalPresetName = "New"
        model.savePersonalPreset()
        model.applyProfile(.stable)
        XCTAssertFalse(model.bool("CAPTURE_NV12"))
        model.loadPersonalPreset()
        XCTAssertEqual(model.tcpPacingLimit, "5")
        XCTAssertTrue(model.bool("CAPTURE_NV12"))
        XCTAssertTrue(model.bool("NETWORK_AUTODETECT"))
        XCTAssertFalse(model.bool("RICH_CLIPBOARD"))
        XCTAssertEqual(model.virtualDisplayScaling, .automatic)
    }

    func testPersonalPresetSaveLoadRenameDeleteAndDraftIsolation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PersonalPresetStore(url: folder.appendingPathComponent("presets.json"))
        var initial = PerformanceProfile.stable.settings
        initial.merge(["BIND": "0.0.0.0:4400", "ALLOW_IP": "192.168.1.2", "VIRTUAL_DISPLAY": "1", "VD_WIDTH": "2560"]) { _, v in v }
        var saves = 0
        var actions = 0
        let model = SettingsModel(controller: controller, initialConfig: initial,
            saveSettings: { _ in saves += 1 }, performAction: { _, _ in actions += 1 }, presetStore: store)
        model.setFastFlushInterval("10")
        model.personalPresetName = "My setup"
        model.savePersonalPreset()
        let id = try XCTUnwrap(model.personalPresetID)
        XCTAssertEqual(try store.load().count, 1)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(actions, 0)
        model.applyProfile(.native)
        model.loadPersonalPreset()
        XCTAssertEqual(model.fastFlushInterval, "10")
        XCTAssertEqual(model.draft["ENABLE_H264"], "1")
        XCTAssertEqual(model.draft["CAPTURE_SIZE"], "1920x1080")
        XCTAssertEqual(model.draft["BIND"], "0.0.0.0:4400")
        XCTAssertEqual(model.draft["VIRTUAL_DISPLAY"], "1")
        XCTAssertEqual(model.draft["VD_WIDTH"], "2560")
        model.revert()
        XCTAssertEqual(model.draft, initial)
        model.personalPresetName = "Renamed"
        model.renamePersonalPreset()
        XCTAssertEqual(try store.load().first?.name, "Renamed")
        XCTAssertEqual(model.personalPresetID, id)
        model.deletePersonalPreset()
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(model.draft, initial)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(actions, 0)
    }

    func testPresetFailureDoesNotLoseStoredListOrOverwriteCorruptStorage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("presets.json")
        try Data("broken".utf8).write(to: url)
        let model = SettingsModel(controller: controller, initialConfig: PerformanceProfile.stable.settings,
                                  presetStore: PersonalPresetStore(url: url))
        model.personalPresetName = "New"
        model.savePersonalPreset()
        XCTAssertNotNil(model.presetError)
        XCTAssertTrue(model.personalPresets.isEmpty)
        XCTAssertEqual(try String(contentsOf: url), "broken")
    }

    func testTypedBitrateAboveOldLimitPersistsAndRejectsEncoderOverflow() {
        var writes: [[String: String]] = []
        var actions = 0
        let model = SettingsModel(controller: controller,
            initialConfig: ["ENABLE_H264": "1", "BITRATE": "50", "EXTRA_FLAGS": "--bitrate=25 --fps 60"],
            saveSettings: { writes.append($0) }, performAction: { _, _ in actions += 1 })
        model.setBitrate(" 150 ")
        XCTAssertEqual(model.bitrateInput, "150")
        XCTAssertEqual(model.bitrateMbps, "150")
        XCTAssertEqual(model.draft["EXTRA_FLAGS"], "--fps 60")
        XCTAssertNil(model.validationError)
        model.apply()
        XCTAssertEqual(writes.last?["BITRATE"], "150")
        XCTAssertEqual(actions, 0)
        for invalid in ["0", "-1", "1.5", "2148", "4294967295", "invalid"] {
            model.setBitrate(invalid)
            XCTAssertNotNil(model.validationError)
            model.apply()
        }
        XCTAssertEqual(writes.count, 1)
        model.setBitrate("2147")
        XCTAssertNil(model.validationError)
        model.setBitrate("")
        XCTAssertEqual(model.bitrateInput, "")
        XCTAssertEqual(model.bitrateMbps, "6")
        XCTAssertNil(model.validationError)
        model.apply()
        XCTAssertEqual(writes.last?["BITRATE"], "")
        XCTAssertEqual(actions, 0)
    }

    func testEncoderQueueDepthEditsLegacyFlagAndPersists() {
        var saved: [String: String] = [:]
        let model = SettingsModel(controller: controller,
            initialConfig: ["ENABLE_H264": "1", "EXTRA_FLAGS": "--h264-frames-in-flight=1 --stretch"],
            saveSettings: { saved = $0 })
        XCTAssertEqual(model.encoderQueueDepth, "1")
        model.setEncoderQueueDepth("0")
        XCTAssertNotNil(model.validationError)
        model.setEncoderQueueDepth("2")
        XCTAssertNil(model.validationError)
        XCTAssertEqual(model.draft["EXTRA_FLAGS"], "--stretch")
        model.apply()
        XCTAssertEqual(saved["H264_FRAMES_IN_FLIGHT"], "2")
        model.setEncoderQueueDepth("")
        XCTAssertNil(model.validationError)
    }

    private func result(_ success: Bool, running: Bool) -> ServerActionResult {
        ServerActionResult(success: success, message: success ? "Running" : "Start failed",
                           running: running, repaired: false, needsPermissionAttention: false)
    }

    func testFailedSaveRetainsDraftAndNeverRestarts() {
        var actions = 0
        let model = SettingsModel(controller: controller, initialConfig: ["FPS": "30"],
            saveSettings: { _ in throw CocoaError(.fileWriteNoPermission) },
            performAction: { _, _ in actions += 1 })
        model.updateServerRunning(true)
        model.setString("FPS", "60")
        model.apply()
        XCTAssertEqual(model.saved["FPS"], "30")
        XCTAssertEqual(model.draft["FPS"], "60")
        XCTAssertTrue(model.isDirty)
        XCTAssertNotNil(model.applyError)
        XCTAssertNil(model.applySuccessMessage)
        XCTAssertEqual(actions, 0)
    }

    func testMultipleEditsSaveOnceBeforeOneRestart() {
        var events: [String] = []
        var changes: [String: String] = [:]
        let model = SettingsModel(controller: controller, initialConfig: ["FPS": "30", "OTHER": "keep"],
            saveSettings: { changes = $0; events.append("save") },
            performAction: { action, done in
                XCTAssertEqual(action, .restart)
                events.append("restart")
                done(self.result(true, running: true))
            })
        model.updateServerRunning(true)
        model.setString("FPS", "60")
        model.setAllowedIPs(" 192.168.1.2, ::1, ")
        model.apply()
        XCTAssertEqual(events, ["save", "restart"])
        XCTAssertEqual(changes, ["FPS": "60", "ALLOW_IP": "192.168.1.2,::1"])
        XCTAssertFalse(model.isDirty)
        XCTAssertNotNil(model.applySuccessMessage)
        XCTAssertFalse(model.restartRequired)
    }

    func testRestartFailureCanRetryWithoutRewritingSettings() {
        var saves = 0
        var actions: [ServerAction] = []
        let model = SettingsModel(controller: controller, initialConfig: [:],
            saveSettings: { _ in saves += 1 },
            performAction: { action, done in
                actions.append(action)
                done(self.result(actions.count > 1, running: actions.count > 1))
            })
        model.updateServerRunning(true)
        model.setString("FPS", "60")
        model.apply()
        XCTAssertTrue(model.restartRequired)
        XCTAssertNotNil(model.applyError)
        XCTAssertNil(model.applySuccessMessage)
        XCTAssertFalse(model.isDirty)
        model.apply()
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(actions, [.restart, .start])
        XCTAssertFalse(model.restartRequired)
        XCTAssertNil(model.applyError)
        XCTAssertNotNil(model.applySuccessMessage)
    }

    func testStoppedServerOnlySavesAndNoOpDoesNothing() {
        var saves = 0
        let model = SettingsModel(controller: controller, initialConfig: [:],
            saveSettings: { _ in saves += 1 },
            performAction: { _, _ in XCTFail("Must not start a stopped server") })
        model.apply()
        XCTAssertEqual(saves, 0)
        model.applyProfile(.lan)
        model.apply()
        XCTAssertEqual(saves, 1)
        XCTAssertNotNil(model.applySuccessMessage)
    }

    func testInvalidAllowlistDoesNotSaveOrRestart() {
        let model = SettingsModel(controller: controller, initialConfig: [:],
            saveSettings: { _ in XCTFail("Invalid settings were saved") },
            performAction: { _, _ in XCTFail("Invalid settings started a server") })
        model.setAllowedIPs("192.168.1.0/24")
        model.apply()
        XCTAssertNotNil(model.validationError)
        XCTAssertTrue(model.isDirty)
    }

    func testProfileKeepsNetworkAndCanBeCustomized() {
        let model = SettingsModel(controller: controller,
            initialConfig: ["BIND": "127.0.0.1:4400", "ALLOW_IP": "192.168.1.2"])
        for profile in PerformanceProfile.allCases {
            model.applyProfile(profile)
            XCTAssertEqual(model.selectedProfile, profile)
            XCTAssertEqual(model.draft["BIND"], "127.0.0.1:4400")
            XCTAssertEqual(model.draft["ALLOW_IP"], "192.168.1.2")
        }
        model.setBitrate("17")
        XCTAssertNil(model.selectedProfile)
        XCTAssertEqual(model.bitrateMbps, "17")
        model.setAllowNetwork(true)
        XCTAssertEqual(model.bindDisplay, "0.0.0.0:4400")
    }

    func testFastFlushIsIndependentAndProfilesRestoreStableCadence() {
        let initial = PerformanceProfile.ultimate.settings
        let model = SettingsModel(controller: controller, initialConfig: initial)
        XCTAssertFalse(model.fastFlushEnabled)
        model.setFastFlushEnabled(true)
        XCTAssertTrue(model.fastFlushEnabled)
        XCTAssertEqual(model.draft["FLUSH_INTERVAL_MS"], "10")
        for (key, value) in initial where key != "FLUSH_INTERVAL_MS" {
            XCTAssertEqual(model.draft[key], value)
        }
        model.setFastFlushEnabled(false)
        XCTAssertEqual(model.draft["FLUSH_INTERVAL_MS"], "")
        for profile in PerformanceProfile.allCases {
            model.setFastFlushEnabled(true)
            model.applyProfile(profile)
            XCTAssertFalse(model.fastFlushEnabled)
            XCTAssertEqual(model.selectedProfile, profile)
        }
    }

    func testFastFlushReadsLegacyValueAndClearsItAuthoritatively() {
        let model = SettingsModel(controller: controller, initialConfig: [
            "BIND": "127.0.0.1:3390", "ENABLE_H264": "1",
            "EXTRA_FLAGS": "--flush-interval-ms=12 --fps 60"])
        XCTAssertTrue(model.fastFlushEnabled)
        XCTAssertEqual(model.fastFlushInterval, "12")
        model.setFastFlushEnabled(false)
        XCTAssertFalse(model.fastFlushEnabled)
        XCTAssertEqual(model.draft["FLUSH_INTERVAL_MS"], "")
        XCTAssertEqual(model.draft["EXTRA_FLAGS"], "--fps 60")
        model.revert()
        XCTAssertEqual(model.fastFlushInterval, "12")
        model.setFastFlushInterval("10")
        XCTAssertEqual(model.fastFlushInterval, "10")
    }

    func testInvalidFlushValuesBlockApplyWithoutSavingOrRestarting() {
        var saves = 0
        var restarts = 0
        let model = SettingsModel(controller: controller,
            initialConfig: ["BIND": "127.0.0.1:3390", "ENABLE_H264": "1"],
            saveSettings: { _ in saves += 1 }, performAction: { _, _ in restarts += 1 })
        model.updateServerRunning(true)
        for value in ["", "7", "1001", "1.5", "bad"] {
            model.setFastFlushInterval(value)
            XCTAssertTrue(model.fastFlushEnabled) // editor stays visible while empty
            XCTAssertNotNil(model.validationError)
            model.apply()
        }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(restarts, 0)
        for value in ["8", "10", "1000"] {
            model.setFastFlushInterval(value)
            XCTAssertNil(model.validationError)
        }
    }

    func testPhysicalCaptureSelectionClearsLegacyPinsAndRetainsNetwork() {
        let model = SettingsModel(controller: controller, initialConfig: [
            "BIND": "192.168.137.2:3390", "EXTRA_FLAGS": "--width=1920 --height 1080 --hidpi --no-client-resolution --fps 60"])
        model.setCaptureResolutionChoice("2560x1440")
        XCTAssertEqual(model.captureResolutionChoice, "2560x1440")
        XCTAssertEqual(model.draft["CAPTURE_SIZE"], "2560x1440")
        XCTAssertEqual(model.draft["HIDPI"], "0")
        XCTAssertEqual(model.draft["EXTRA_FLAGS"], "--fps 60")
        XCTAssertEqual(model.bindDisplay, "192.168.137.2:3390")
        model.setCaptureResolutionChoice("hidpi")
        XCTAssertEqual(model.draft["CAPTURE_SIZE"], "")
        XCTAssertEqual(model.draft["HIDPI"], "1")
        model.setCaptureResolutionChoice("auto")
        XCTAssertEqual(model.captureResolutionChoice, "auto")
    }

    func testCustomResolutionValidationAndVirtualDisplayIndependence() {
        let model = SettingsModel(controller: controller, initialConfig: ["BIND": "127.0.0.1:3390"])
        model.setCaptureResolutionChoice("custom")
        model.setCustomCaptureSize("")
        XCTAssertEqual(model.captureResolutionChoice, "custom")
        XCTAssertNotNil(model.validationError)
        for size in ["bad", "199x1080", "8194x1080", "1919x1080"] {
            model.setCustomCaptureSize(size)
            XCTAssertNotNil(model.validationError)
        }
        model.setCustomCaptureSize("2560X1600")
        XCTAssertNil(model.validationError)
        XCTAssertEqual(model.draft["CAPTURE_SIZE"], "2560x1600")
        model.setBool("VIRTUAL_DISPLAY", true)
        model.setResolution("1920x1080")
        XCTAssertEqual(model.draft["CAPTURE_SIZE"], "2560x1600")
        XCTAssertEqual(model.draft["VD_WIDTH"], "1920")
        model.revert()
        XCTAssertEqual(model.captureResolutionChoice, "auto")
    }

    func testStableProfileIsTheAcceptedVideoSettingsWithFastFlushOff() {
        let model = SettingsModel(controller: controller, initialConfig: ["BIND": "0.0.0.0:3390"])
        model.setFastFlushInterval("8")
        model.applyProfile(.stable)
        XCTAssertEqual(model.selectedProfile, .stable)
        XCTAssertEqual(model.draft["CAPTURE_SIZE"], "1920x1080")
        XCTAssertEqual(model.frameRate, "60")
        XCTAssertEqual(model.bitrateMbps, "60")
        XCTAssertEqual(model.draft["FLUSH_FRAMES"], "2")
        XCTAssertEqual(model.draft["H264_FRAMES_IN_FLIGHT"], "2")
        XCTAssertEqual(model.draft["ENABLE_UDP_MULTITRANSPORT"], "0")
        XCTAssertFalse(model.fastFlushEnabled)
        XCTAssertFalse(model.bool("RESPONSIVE_CAPTURE"))
        XCTAssertFalse(model.bool("CAPTURE_NV12"))
        XCTAssertEqual(model.bindDisplay, "0.0.0.0:3390")
    }

    func testDisablingParentSettingsKeepsThemDisabled() {
        let model = SettingsModel(controller: controller, initialConfig: [:])
        model.setBool("ENABLE_UDP_MULTITRANSPORT", true)
        model.setBool("UDP_MIGRATE_EGFX", true)
        model.setBool("AVC444", true)
        XCTAssertTrue(model.bool("ENABLE_H264"))
        model.setFastFlushInterval("7")
        model.setBool("ENABLE_H264", false)
        XCTAssertFalse(model.fastFlushEnabled)
        XCTAssertFalse(model.bool("ENABLE_H264"))
        XCTAssertFalse(model.bool("UDP_MIGRATE_EGFX"))
        XCTAssertFalse(model.bool("AVC444"))
        model.setPrimaryMode("shield")
        XCTAssertTrue(model.bool("VIRTUAL_DISPLAY"))
        model.setBool("VIRTUAL_DISPLAY", false)
        XCTAssertEqual(model.primaryMode, "none")
    }

    func testInvalidNumbersAreRejectedAndAutomaticFrameRateIsAllowed() {
        let model = SettingsModel(controller: controller, initialConfig: [:])
        for value in ["0", "-1", "abc", "2.5", "4294967296"] {
            model.setString("FPS", value)
            XCTAssertNotNil(model.validationError, value)
        }
        model.setString("FPS", "")
        XCTAssertNil(model.validationError)
        model.setString("FPS", "24")
        XCTAssertNil(model.validationError)
        model.setBitrate("0")
        XCTAssertNotNil(model.validationError)
    }

    func testCustomBitrateRemovesLegacyOverridesButKeepsOtherFlags() {
        let model = SettingsModel(controller: controller,
            initialConfig: ["EXTRA_FLAGS": "--stretch\t--bitrate=8 --bitrate 12 --unminimize"])
        XCTAssertEqual(model.bitrateMbps, "8")
        model.setBitrate("17")
        XCTAssertEqual(model.string("EXTRA_FLAGS"), "--stretch --unminimize")
        XCTAssertEqual(model.bitrateMbps, "17")
        model.setString("EXTRA_FLAGS", "--bitrate=9 --stretch")
        model.applyProfile(.ultimate)
        XCTAssertEqual(model.bitrateMbps, "25")
        XCTAssertEqual(model.string("EXTRA_FLAGS"), "--stretch")
    }

    func testFrameRateReflectsLegacyFlagsAndClearingChoosesAutomatic() {
        let model = SettingsModel(controller: controller,
            initialConfig: ["EXTRA_FLAGS": "--fps=24 --stretch"])
        XCTAssertEqual(model.frameRate, "24")
        model.setFrameRate("")
        XCTAssertEqual(model.frameRate, "")
        XCTAssertEqual(model.string("EXTRA_FLAGS"), "--stretch")
        model.setString("EXTRA_FLAGS", "--fps=24 --stretch")
        model.applyProfile(.lan)
        XCTAssertEqual(model.frameRate, "60")
        XCTAssertEqual(model.string("EXTRA_FLAGS"), "--stretch")
    }

    func testStartingAfterSavingDoesNotClaimServerWasRestarted() {
        let model = SettingsModel(controller: controller, initialConfig: [:],
            saveSettings: { _ in }, performAction: { _, done in done(self.result(true, running: true)) })
        model.setFrameRate("30")
        model.apply()
        XCTAssertEqual(model.applySuccessMessage, "Settings saved — start the server to use them")
        model.beginServerAction(.start)
        XCTAssertNil(model.applySuccessMessage)
        XCTAssertTrue(model.serverRunning)
    }

    func testApplyRestartMessageIsClearedByStop() {
        let model = SettingsModel(controller: controller, initialConfig: [:],
            saveSettings: { _ in }, performAction: { action, done in
                done(self.result(true, running: action != .stop))
            })
        model.updateServerRunning(true)
        model.setFrameRate("30")
        model.apply()
        XCTAssertEqual(model.applySuccessMessage, "Settings saved — server restarted")
        model.beginServerAction(.stop)
        XCTAssertNil(model.applySuccessMessage)
        XCTAssertFalse(model.serverRunning)
    }

    func testPortEditingPreservesHostAndNetworkTogglePreservesPort() {
        for host in ["127.0.0.1", "0.0.0.0", "192.168.1.2", "[::1]", "[::]"] {
            let model = SettingsModel(controller: controller, initialConfig: ["BIND": "\(host):3390"])
            model.setPortNumber("4400")
            XCTAssertEqual(model.bindDisplay, "\(host):4400")
            XCTAssertNil(model.validationError)
            model.setAllowNetwork(true)
            XCTAssertEqual(model.bindDisplay, "0.0.0.0:4400")
            model.setAllowNetwork(false)
            XCTAssertEqual(model.bindDisplay, "127.0.0.1:4400")
        }
    }

    func testInvalidPortsPreventApplyAndRemainEditable() {
        let model = SettingsModel(controller: controller, initialConfig: [:],
            saveSettings: { _ in XCTFail("Invalid port must not be saved") },
            performAction: { _, _ in XCTFail("Invalid port must not restart") })
        XCTAssertEqual(model.portNumber, "3390")
        for port in ["", "0", "65536", "-1", "abc", "33.90", " 4400", "+4400"] {
            model.setPortNumber(port)
            XCTAssertEqual(model.portNumber, port)
            XCTAssertNotNil(model.validationError)
            model.apply()
        }
        model.setPortNumber("")
        model.setAllowNetwork(true)
        XCTAssertEqual(model.portNumber, "")
        for port in ["1", "4400", "65535"] {
            model.setPortNumber(port)
            XCTAssertNil(model.validationError)
        }
    }

    func testPortApplySavesBindAndRestartsOnce() {
        var changes: [String: String] = [:]
        var restarts = 0
        let model = SettingsModel(controller: controller, initialConfig: ["BIND": "127.0.0.1:3390"],
            saveSettings: { changes = $0 }, performAction: { action, done in
                XCTAssertEqual(action, .restart)
                restarts += 1
                done(self.result(true, running: true))
            })
        model.updateServerRunning(true)
        model.setPortNumber("4400")
        model.apply()
        XCTAssertEqual(changes, ["BIND": "127.0.0.1:4400"])
        XCTAssertEqual(restarts, 1)
        XCTAssertFalse(model.isDirty)
    }

    func testBusyApplyDoesNotWriteAgain() {
        var saves = 0
        let model = SettingsModel(controller: controller, initialConfig: [:],
            saveSettings: { _ in saves += 1 }, performAction: { _, _ in })
        model.updateServerRunning(true)
        model.setString("FPS", "30")
        model.apply()
        model.setString("FPS", "60")
        model.apply()
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(model.saved["FPS"], "30")
        XCTAssertEqual(model.draft["FPS"], "60")
    }
}
