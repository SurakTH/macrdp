import Foundation
import CoreFoundation

struct LiveStats {
    let videoActive: Bool?
    var hasActiveVideo: Bool { videoActive != false && width > 0 && height > 0 }
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
    let uptimeMs: Double?
    let generation: Int?
    let queuedFrames: Double?
    let payloadBytes: Double?
    let encodeCount: Double?
    let encodeTotalUs: Double?
    let retainedEncodeSubmissions: Double?
    let deferred: Double?
    let errors: Double?
    let encodePrepared: Double?
    let encodePrepareTotalUs: Double?
    let captureSuperseded: Double?
    let tcpBackpressure: Double?
    let encoderSubmissionErrors: Double?
    let videoShippingErrors: Double?
    var hasVideoDiagnostics: Bool {
        encodePrepared != nil || captureSuperseded != nil || tcpBackpressure != nil
            || encoderSubmissionErrors != nil || videoShippingErrors != nil
    }
    let ackSamples: Int?
    let ackSampleMs: Double?
    let ackRttMs: Double?
    let ackQueueMs: Double?

    static func decode(_ data: Data) -> LiveStats? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["width"] is NSNumber, o["fps"] is NSNumber else { return nil }
        func number(_ key: String) -> Double? {
            guard let n = o[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let value = n.doubleValue
            return value.isFinite && value >= 0 ? value : nil
        }
        func int(_ key: String) -> Int { (o[key] as? NSNumber)?.intValue ?? 0 }
        return LiveStats(videoActive: o["video_active"] as? Bool, processId: int("process_id"), width: int("width"), height: int("height"),
            bitrateBps: int("bitrate_bps"), ceilingBps: int("ceiling_bps"),
            rttMs: int("rtt_ms"), queueMs: int("queue_delay_ms"), fps: int("fps"),
            frames: int("frames_sent"), adaptive: (o["adaptive"] as? NSNumber)?.boolValue ?? false,
            uptimeMs: number("uptime_ms"), generation: number("video_generation").flatMap { $0 < Double(Int.max) ? Int($0) : nil },
            queuedFrames: number("video_frames_queued"), payloadBytes: number("video_payload_bytes"),
            encodeCount: number("encode_completed"), encodeTotalUs: number("encode_total_us"),
            retainedEncodeSubmissions: number("encode_retained_submitted"),
            deferred: number("encode_deferred"), errors: number("encode_output_errors"),
            encodePrepared: number("encode_prepared"), encodePrepareTotalUs: number("encode_prepare_total_us"),
            captureSuperseded: number("capture_superseded"), tcpBackpressure: number("encode_tcp_backpressure"),
            encoderSubmissionErrors: number("encode_submit_errors"), videoShippingErrors: number("video_ship_errors"),
            ackSamples: number("ack_samples").flatMap { $0 < Double(Int.max) ? Int($0) : nil }, ackSampleMs: number("ack_sample_uptime_ms"),
            ackRttMs: number("ack_rtt_ms"), ackQueueMs: number("ack_queue_ms"))
    }
}

struct PerformanceSample: Identifiable {
    let id = UUID()
    let time: Date
    let fps: Double
    let mbps: Double
    let encodeMs: Double?
    let retainedEncodeRate: Double?
    let queueMs: Double?
    let ackRttMs: Double?
    let deferred: Double
    let errors: Double
    let prepareMs: Double?
    let captureSuperseded: Double?
    let tcpBackpressure: Double?
    let encoderSubmissionErrors: Double?
    let videoShippingErrors: Double?
}

struct PerformanceHistory {
    private(set) var samples: [PerformanceSample] = []
    private var previous: LiveStats?
    private var previousTime: Date?
    var latest: PerformanceSample? { samples.last }

    mutating func reset() {
        samples.removeAll()
        previous = nil
        previousTime = nil
    }

    mutating func record(_ live: LiveStats?, at time: Date = Date()) {
        guard let live, live.hasActiveVideo else { reset(); return }
        defer { previous = live; previousTime = time }
        guard let before = previous, let beforeTime = previousTime,
              live.processId == before.processId, live.generation == before.generation,
              live.width == before.width, live.height == before.height,
              let frames = live.queuedFrames, let oldFrames = before.queuedFrames,
              let bytes = live.payloadBytes, let oldBytes = before.payloadBytes,
              frames >= oldFrames, bytes >= oldBytes else { samples.removeAll(); return }
        let elapsed = live.uptimeMs.flatMap { now in before.uptimeMs.map { (now - $0) / 1000 } }
            ?? time.timeIntervalSince(beforeTime)
        guard elapsed >= 0.25 && elapsed <= 6 else { samples.removeAll(); return }
        func delta(_ now: Double?, _ old: Double?) -> Double? {
            guard let now, let old, now >= old else { return nil }
            return now - old
        }
        func averageMilliseconds(count: Double?, totalMicros: Double?) -> Double? {
            guard let count, count > 0, let totalMicros else { return nil }
            return totalMicros / count / 1000
        }
        let average = averageMilliseconds(count: delta(live.encodeCount, before.encodeCount),
            totalMicros: delta(live.encodeTotalUs, before.encodeTotalUs))
        let preparation = averageMilliseconds(count: delta(live.encodePrepared, before.encodePrepared),
            totalMicros: delta(live.encodePrepareTotalUs, before.encodePrepareTotalUs))
        let ackAge = live.uptimeMs.flatMap { now in live.ackSampleMs.map { now - $0 } }
        let freshAck = (live.ackSamples ?? 0) > (before.ackSamples ?? 0)
            && ackAge.map { $0 >= 0 && $0 <= 5000 } == true
        samples.append(PerformanceSample(time: time, fps: (frames - oldFrames) / elapsed,
            mbps: (bytes - oldBytes) * 8 / elapsed / 1_000_000,
            encodeMs: average,
            retainedEncodeRate: delta(live.retainedEncodeSubmissions, before.retainedEncodeSubmissions).map { $0 / elapsed },
            queueMs: freshAck ? live.ackQueueMs : nil,
            ackRttMs: freshAck ? live.ackRttMs : nil,
            deferred: delta(live.deferred, before.deferred) ?? 0,
            errors: delta(live.errors, before.errors) ?? 0,
            prepareMs: preparation,
            captureSuperseded: delta(live.captureSuperseded, before.captureSuperseded),
            tcpBackpressure: delta(live.tcpBackpressure, before.tcpBackpressure),
            encoderSubmissionErrors: delta(live.encoderSubmissionErrors, before.encoderSubmissionErrors),
            videoShippingErrors: delta(live.videoShippingErrors, before.videoShippingErrors)))
        samples.removeAll { time.timeIntervalSince($0.time) > 60 }
        if samples.count > 30 { samples.removeFirst(samples.count - 30) }
    }
}


enum PerformanceAvailability: Equatable {
    case checking, stopped, disabled, unavailable, waitingForVideo, streaming

    static func resolve(checked: Bool, running: Bool, telemetryEnabled: Bool, live: LiveStats?) -> Self {
        if let live { return live.hasActiveVideo ? .streaming : .waitingForVideo }
        if !checked { return .checking }
        if !running { return .stopped }
        return telemetryEnabled ? .unavailable : .disabled
    }

    var message: String {
        switch self {
        case .checking: return "Checking server and telemetry…"
        case .stopped: return "The managed server is stopped. Start it in Status, then connect from Windows."
        case .disabled: return "Live statistics are off in the saved settings. Enable them in Advanced and Apply."
        case .unavailable: return "The server is running, but telemetry could not be read. Check the statistics port and server logs."
        case .waitingForVideo: return "Telemetry is available. Connect with an H.264 client to see video metrics."
        case .streaming: return "Live · refreshes every 2 seconds"
        }
    }
}


/// Extract the remote host only from selected TCP endpoint fields (lsof -Fn).
func establishedRDPHost(in output: String, localPort: UInt16) -> String? {
    for line in output.split(whereSeparator: \.isNewline) where line.first == "n" {
        guard let arrow = line.range(of: "->"),
              line[..<arrow.lowerBound].hasSuffix(":\(localPort)") else { continue }
        let endpoint = line[arrow.upperBound...]
        guard let colon = endpoint.lastIndex(of: ":") else { continue }
        let host = String(endpoint[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if !host.isEmpty { return host }
    }
    return nil
}
