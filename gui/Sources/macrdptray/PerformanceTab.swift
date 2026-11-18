import SwiftUI
import Charts

struct PerformanceTab: View {
    @ObservedObject var model: SettingsModel
    @State private var history = PerformanceHistory()
    @State private var live: LiveStats?
    @State private var process = ServerStats.stopped
    @State private var updated: Date?
    @State private var pending = false
    @State private var visible = false
    @State private var epoch = UUID()
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var availability: PerformanceAvailability {
        .resolve(checked: updated != nil, running: process.running,
                 telemetryEnabled: model.saved["STATS_ENDPOINT"] == "1", live: live)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Performance").font(.title2.bold())
                        Text(availability == .streaming ? availability.message : "Local video diagnostics")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Refresh", action: refresh).disabled(pending)
                }
                if let live, availability == .streaming {
                    HStack {
                        Label("\(live.width) × \(live.height)", systemImage: "display")
                        Spacer()
                        Text("Capture limit: \(live.fps) FPS").foregroundColor(.secondary)
                    }
                    if live.queuedFrames == nil {
                        Text("This server provides older telemetry. Update the server to see measured rates and encode time.")
                            .foregroundColor(.secondary)
                    } else if history.latest == nil {
                        Text("Collecting the first interval… Rates appear after the next sample.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        metric("Video FPS · queued", value(history.latest?.fps, unit: "fps"), icon: "film")
                        metric("Video payload rate", value(history.latest?.mbps, unit: "Mbps"), icon: "arrow.up.right")
                        metric("Encoder completion", value(history.latest?.encodeMs, unit: "ms"), icon: "cpu")
                        metric("ACK queue delay", value(history.latest?.queueMs, unit: "ms"), icon: "tray.full")
                    }
                    if let latest = history.latest {
                        GroupBox("Video FPS · last 60 seconds") {
                            Chart(history.samples) { point in
                                LineMark(x: .value("Time", point.time), y: .value("FPS", point.fps))
                                    .foregroundStyle(.blue)
                            }
                            .chartYScale(domain: 0...max(Double(live.fps), history.samples.map(\.fps).max() ?? 1, 1))
                            .frame(height: 125)
                        }
                        GroupBox("ACK queue delay · last 60 seconds") {
                            if history.samples.contains(where: { $0.queueMs != nil }) {
                                Chart(history.samples) { point in
                                    if let queue = point.queueMs {
                                        PointMark(x: .value("Time", point.time), y: .value("Delay (ms)", queue))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .chartXScale(domain: latest.time.addingTimeInterval(-60)...latest.time)
                                .chartYScale(domain: 0...max(history.samples.compactMap(\.queueMs).max() ?? 1, 10))
                                .frame(height: 110)
                            } else {
                                Text("Waiting for fresh client acknowledgements")
                                    .foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                            }
                        }
                    }
                    GroupBox("Current interval") {
                        VStack(spacing: 8) {
                            row("Encoder target", String(format: "%.1f Mbps%@", Double(live.bitrateBps) / 1_000_000,
                                live.adaptive ? " · adaptive" : ""))
                            row("Frame ACK round trip", value(history.latest?.ackRttMs, unit: "ms"))
                            if live.retainedEncodeSubmissions != nil {
                                row("Reused captures", value(history.latest?.retainedEncodeRate, unit: "frames/s"))
                                    .help("Encoder submissions that reused a captured image for flush, repaint, or retry.")
                            }
                            row("Captures deferred", history.latest.map { String(format: "%.0f", $0.deferred) } ?? "—")
                            row("Encoder output errors", history.latest.map { String(format: "%.0f", $0.errors) } ?? "—")
                            if process.running {
                                row("CPU / memory", String(format: "%.1f%% / %.0f MB", process.cpu, process.rssMB))
                            }
                        }.padding(4)
                    }
                    if live.hasVideoDiagnostics {
                        DisclosureGroup("Video diagnostics") {
                            VStack(spacing: 8) {
                                if live.encodePrepared != nil {
                                    row("AVC420 buffer preparation", value(history.latest?.prepareMs, unit: "ms"))
                                }
                                if live.captureSuperseded != nil {
                                    row("Older captures replaced", count(history.latest?.captureSuperseded))
                                }
                                if live.tcpBackpressure != nil {
                                    row("Submissions deferred by TCP pacing", count(history.latest?.tcpBackpressure))
                                }
                                if live.encoderSubmissionErrors != nil {
                                    row("Encoder submission errors", count(history.latest?.encoderSubmissionErrors))
                                }
                                if live.videoShippingErrors != nil {
                                    row("AVC420 frame dispatch errors", count(history.latest?.videoShippingErrors))
                                }
                            }.padding(.top, 8)
                        }
                    }
                    Text("Rates are measured between samples. Queued FPS counts logical H.264 frames handed to the transport, including trailing flush pictures; it does not measure client presentation. Payload rate excludes network headers, audio and retransmits. Encoder time runs from submission to callback. ACK timing is not key-to-screen latency. An idle desktop may report 0 FPS.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Label(availability.message, systemImage: "chart.xyaxis.line")
                        .padding(.vertical, 12)
                    if availability == .stopped {
                        Button("Go to Status") { model.section = .status }
                    } else if availability == .disabled || availability == .unavailable {
                        Button("Show Live Statistics Setting") { model.section = .advanced }
                    }
                    Text("If a terminal server uses a custom statistics port, set the same port in Advanced. This page reads local telemetry only; it does not change settings or restart the server.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let updated {
                    Text("Last checked: \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundColor(.secondary)
                }
            }.padding(22)
        }
        .onAppear { visible = true; refresh() }
        .onDisappear { visible = false; epoch = UUID(); pending = false }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        guard visible, !pending else { return }
        pending = true
        let requestEpoch = epoch
        let controller = model.controller
        DispatchQueue.global(qos: .utility).async {
            let next = controller.liveStats()
            let stats = controller.serverStats(processID: next.flatMap { $0.processId > 0 ? $0.processId : nil })
            DispatchQueue.main.async {
                guard visible, epoch == requestEpoch else { return }
                pending = false
                let now = Date()
                updated = now
                live = next
                process = stats
                history.record(next, at: now)
            }
        }
    }

    private func value(_ number: Double?, unit: String) -> String {
        number.map { String(format: "%.1f %@", $0, unit) } ?? "—"
    }

    private func count(_ number: Double?) -> String {
        number.map { String(format: "%.0f", $0) } ?? "—"
    }

    private func metric(_ title: String, _ text: String, icon: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon).font(.caption).foregroundColor(.secondary)
                Text(text).font(.title2.monospacedDigit().bold())
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func row(_ title: String, _ text: String) -> some View {
        HStack { Text(title); Spacer(); Text(text).foregroundColor(.secondary).monospacedDigit() }
    }
}
