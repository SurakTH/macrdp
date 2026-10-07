import XCTest
@testable import macrdptray

final class SettingsModelTests: XCTestCase {
    private var controller: AppController!
    override func setUp() { controller = AppController() }
    override func tearDown() { controller = nil }

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
        XCTAssertEqual(model.bitrateMbps, "25")
        XCTAssertEqual(model.draft["FLUSH_FRAMES"], "2")
        XCTAssertEqual(model.draft["H264_FRAMES_IN_FLIGHT"], "1")
        XCTAssertEqual(model.draft["ENABLE_UDP_MULTITRANSPORT"], "0")
        XCTAssertFalse(model.fastFlushEnabled)
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
