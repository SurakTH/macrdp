import XCTest
@testable import macrdptray

final class PerformanceTelemetryTests: XCTestCase {
    func testVideoDiagnosticsShowIntervalDeltasAndHandleOlderServers() throws {
        var history = PerformanceHistory()
        let oldServer = try snapshot()
        XCTAssertFalse(oldServer.hasVideoDiagnostics)
        history.record(oldServer)
        let baseline = try snapshot([
            "uptime_ms": 3000, "encode_prepared": 10, "encode_prepare_total_us": 25_000,
            "capture_superseded": 2, "encode_tcp_backpressure": 5,
            "encode_submit_errors": 1, "video_ship_errors": 4,
        ])
        XCTAssertTrue(baseline.hasVideoDiagnostics)
        history.record(baseline)
        XCTAssertNil(history.latest?.prepareMs)
        history.record(try snapshot([
            "uptime_ms": 5000, "encode_prepared": 20, "encode_prepare_total_us": 55_000,
            "capture_superseded": 6, "encode_tcp_backpressure": 14,
            "encode_submit_errors": 1, "video_ship_errors": 5,
        ]))
        let latest = try XCTUnwrap(history.latest)
        XCTAssertEqual(latest.prepareMs, 3)
        XCTAssertEqual(latest.captureSuperseded, 4)
        XCTAssertEqual(latest.tcpBackpressure, 9)
        XCTAssertEqual(latest.encoderSubmissionErrors, 0)
        XCTAssertEqual(latest.videoShippingErrors, 1)
    }

    private func snapshot(_ updates: [String: Any] = [:]) throws -> LiveStats {
        var values: [String: Any] = [
            "process_id": 42, "width": 1920, "height": 1080, "fps": 60,
            "video_generation": 1, "uptime_ms": 1000,
            "video_frames_queued": 100, "video_payload_bytes": 1_000_000,
            "encode_completed": 100, "encode_total_us": 200_000,
            "encode_deferred": 0, "encode_output_errors": 0,
            "ack_samples": 1, "ack_sample_uptime_ms": 1000, "ack_rtt_ms": 12, "ack_queue_ms": 3,
        ]
        values.merge(updates) { _, value in value }
        return try XCTUnwrap(LiveStats.decode(JSONSerialization.data(withJSONObject: values)))
    }

    func testAvailabilityDistinguishesStoppedDisabledAndWaitingForVideo() throws {
        XCTAssertEqual(PerformanceAvailability.resolve(checked: false, running: false, telemetryEnabled: false, live: nil), .checking)
        XCTAssertEqual(PerformanceAvailability.resolve(checked: true, running: false, telemetryEnabled: true, live: nil), .stopped)
        XCTAssertEqual(PerformanceAvailability.resolve(checked: true, running: true, telemetryEnabled: false, live: nil), .disabled)
        XCTAssertEqual(PerformanceAvailability.resolve(checked: true, running: true, telemetryEnabled: true, live: nil), .unavailable)
        let oldServer = try snapshot()
        let idleServer = try snapshot(["video_active": false])
        XCTAssertEqual(PerformanceAvailability.resolve(checked: true, running: true, telemetryEnabled: true, live: idleServer), .waitingForVideo)
        XCTAssertEqual(PerformanceAvailability.resolve(checked: true, running: false, telemetryEnabled: false, live: oldServer), .streaming)

        var history = PerformanceHistory()
        let now = Date()
        history.record(oldServer, at: now)
        history.record(try snapshot(["uptime_ms": 3000, "video_frames_queued": 140]), at: now.addingTimeInterval(2))
        XCTAssertNotNil(history.latest)
        history.record(idleServer, at: now.addingTimeInterval(4))
        XCTAssertNil(history.latest)
    }

    func testConnectionEndpointParserHandlesIPv6AndLoopback() {
        XCTAssertEqual(establishedRDPHost(in: "p10\nn127.0.0.1:40245->127.0.0.1:50000\nn[::1]:3390->[::1]:51000", localPort: 3390), "::1")
        XCTAssertEqual(establishedRDPHost(in: "p11\nn192.168.1.10:3390->192.168.1.5:51000", localPort: 3390), "192.168.1.5")
        XCTAssertNil(establishedRDPHost(in: "p11\nn192.168.1.10:51000->192.168.1.5:3390", localPort: 3390))
    }

    func testRatesUseActualCounterDeltasAndServerClockAndIdleIsZero() throws {
        var history = PerformanceHistory()
        let start = Date(timeIntervalSince1970: 100)
        history.record(try snapshot(), at: start)
        XCTAssertNil(history.latest)
        history.record(try snapshot([
            "uptime_ms": 3000, "video_frames_queued": 180, "video_payload_bytes": 2_000_000,
            "encode_completed": 180, "encode_total_us": 520_000,
            "encode_deferred": 4, "encode_output_errors": 1,
            "ack_samples": 2, "ack_sample_uptime_ms": 2900,
        ]), at: start.addingTimeInterval(2.5))
        let sample = try XCTUnwrap(history.latest)
        XCTAssertEqual(sample.fps, 40)
        XCTAssertEqual(sample.mbps, 4)
        XCTAssertEqual(sample.encodeMs, 4)
        XCTAssertEqual(sample.queueMs, 3)
        XCTAssertEqual(sample.deferred, 4)
        XCTAssertEqual(sample.errors, 1)
        history.record(try snapshot([
            "uptime_ms": 5000, "video_frames_queued": 180, "video_payload_bytes": 2_000_000,
            "encode_completed": 180, "encode_total_us": 520_000,
        ]), at: start.addingTimeInterval(4))
        XCTAssertEqual(history.latest?.fps, 0)
        XCTAssertNil(history.latest?.encodeMs)
    }

    func testUnchangedAckLeavesAGapUntilNextAcknowledgement() throws {
        var history = PerformanceHistory()
        history.record(try snapshot())
        history.record(try snapshot([
            "uptime_ms": 3000, "ack_samples": 2, "ack_sample_uptime_ms": 2950, "ack_queue_ms": 800,
        ]))
        XCTAssertEqual(history.latest?.queueMs, 800)
        history.record(try snapshot([
            "uptime_ms": 5000, "ack_samples": 2, "ack_sample_uptime_ms": 2950, "ack_queue_ms": 800,
        ]))
        XCTAssertNil(history.latest?.queueMs)
        XCTAssertNil(history.latest?.ackRttMs)
        history.record(try snapshot([
            "uptime_ms": 7000, "ack_samples": 3, "ack_sample_uptime_ms": 6950, "ack_queue_ms": 2,
        ]))
        XCTAssertEqual(history.latest?.queueMs, 2)
        XCTAssertEqual(history.samples.first?.queueMs, 800)
    }

    func testRestartReconnectMissingDataAndLongGapsResetRates() throws {
        var history = PerformanceHistory()
        let start = Date()
        history.record(try snapshot(), at: start)
        history.record(try snapshot(["uptime_ms": 3000, "video_frames_queued": 200]), at: start.addingTimeInterval(2))
        XCTAssertNotNil(history.latest)
        history.record(try snapshot(["process_id": 99, "uptime_ms": 5000]), at: start.addingTimeInterval(4))
        XCTAssertNil(history.latest)
        history.record(try snapshot(["process_id": 99, "video_generation": 2, "uptime_ms": 7000]), at: start.addingTimeInterval(6))
        XCTAssertNil(history.latest)
        history.record(try snapshot(["process_id": 99, "video_generation": 2, "uptime_ms": 17000]), at: start.addingTimeInterval(16))
        XCTAssertNil(history.latest)
        history.record(nil)
        XCTAssertTrue(history.samples.isEmpty)
        XCTAssertNil(LiveStats.decode(Data("{}".utf8)))
        let legacy = try XCTUnwrap(LiveStats.decode(Data("{\"width\":1920,\"fps\":60}".utf8)))
        XCTAssertNil(legacy.queuedFrames)
        history.record(legacy)
        history.record(legacy)
        XCTAssertNil(history.latest)
    }

    func testStaleAckIsUnknownAndHistoryIsBounded() throws {
        var history = PerformanceHistory()
        let start = Date()
        for i in 0...60 {
            history.record(try snapshot([
                "uptime_ms": 1000 + i * 2000,
                "video_frames_queued": 100 + i,
            ]), at: start.addingTimeInterval(Double(i * 2)))
        }
        XCTAssertNil(history.latest?.queueMs)
        XCTAssertNil(history.latest?.ackRttMs)
        XCTAssertEqual(history.samples.count, 30)
        XCTAssertTrue(history.samples.allSatisfy { $0.fps >= 0 })
    }

    func testReusedCaptureRateSupportsOlderServersAndCounterResets() throws {
        var history = PerformanceHistory()
        history.record(try snapshot())
        history.record(try snapshot(["uptime_ms": 3000, "encode_retained_submitted": 20]))
        XCTAssertNil(history.latest?.retainedEncodeRate)
        history.record(try snapshot(["uptime_ms": 5000, "encode_retained_submitted": 28]))
        XCTAssertEqual(history.latest?.retainedEncodeRate, 4)
        history.record(try snapshot(["uptime_ms": 7000, "encode_retained_submitted": 28]))
        XCTAssertEqual(history.latest?.retainedEncodeRate, 0)
        history.record(try snapshot(["uptime_ms": 9000, "encode_retained_submitted": 1]))
        XCTAssertNil(history.latest?.retainedEncodeRate)
    }
}
