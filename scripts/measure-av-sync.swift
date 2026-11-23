import AVFoundation
import CoreVideo
import Foundation

struct MeasurementError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct Level {
    let time: Double
    let value: Double
}

func readLevels(
    asset: AVAsset, track: AVAssetTrack, settings: [String: Any],
    levels: (CMSampleBuffer) throws -> [Level]
) throws -> [Level] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw MeasurementError("Cannot decode the track.") }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? MeasurementError("Cannot read the recording.") }
    var result: [Level] = []
    while let sample = output.copyNextSampleBuffer() {
        result.append(contentsOf: try levels(sample))
    }
    guard reader.status == .completed else { throw reader.error ?? MeasurementError("Track ended early.") }
    return result
}

func brightness(_ sample: CMSampleBuffer, region: CGRect) throws -> [Level] {
    guard let image = CMSampleBufferGetImageBuffer(sample),
          CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else {
        throw MeasurementError("Cannot read a video frame.")
    }
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else {
        throw MeasurementError("Video decoder did not return a luma plane.")
    }
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let width = Double(CVPixelBufferGetWidthOfPlane(image, 0))
    let height = Double(CVPixelBufferGetHeightOfPlane(image, 0))
    let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
    var total = 0
    // Sample a fixed grid within the flash area, regardless of video resolution.
    for row in 0..<16 {
        let y = Int((region.minY + (Double(row) + 0.5) * region.height / 16) * height)
        for col in 0..<16 {
            let x = Int((region.minX + (Double(col) + 0.5) * region.width / 16) * width)
            total += Int(bytes[y * stride + x])
        }
    }
    return [Level(time: sample.presentationTimeStamp.seconds, value: Double(total) / (256 * 255))]
}

func audioLevels(_ sample: CMSampleBuffer) throws -> [Level] {
    guard let block = CMSampleBufferGetDataBuffer(sample),
          let format = sample.formatDescription,
          let layout = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          layout.mSampleRate > 0, layout.mChannelsPerFrame > 0 else {
        throw MeasurementError("Cannot read PCM audio.")
    }
    let channels = Int(layout.mChannelsPerFrame)
    let frames = CMSampleBufferGetNumSamples(sample)
    let bytes = frames * channels * MemoryLayout<Int16>.size
    guard bytes <= CMBlockBufferGetDataLength(block) else {
        throw MeasurementError("Audio buffer is incomplete.")
    }
    var pcm = [Int16](repeating: 0, count: frames * channels)
    let status = pcm.withUnsafeMutableBytes { buffer in
        bytes == 0 ? kCMBlockBufferNoErr : CMBlockBufferCopyDataBytes(
            block, atOffset: 0, dataLength: bytes, destination: buffer.baseAddress!
        )
    }
    guard status == kCMBlockBufferNoErr else { throw MeasurementError("Cannot copy PCM audio.") }
    let step = max(1, Int(layout.mSampleRate * 0.005))
    return stride(from: 0, to: frames, by: step).map { start in
        let window = pcm[start * channels..<min(start + step, frames) * channels]
        let sum = window.reduce(0.0) { total, sample in
            let value = Double(sample) / 32768
            return total + value * value
        }
        let center = Double(start) + Double(window.count / channels) / 2
        let time = sample.presentationTimeStamp.seconds + center / layout.mSampleRate
        return Level(time: time, value: sqrt(sum / Double(window.count)))
    }
}

func onsets(_ samples: [Level], minimumRange: Double, trigger: Double) throws -> [Double] {
    let samples = samples.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
    guard let low = samples.map(\.value).min(), let high = samples.map(\.value).max(),
          high - low >= minimumRange else {
        throw MeasurementError("The recording has no clear pulses in the selected track or region.")
    }
    let threshold = low + trigger * (high - low)
    var active = false
    var times: [Double] = []
    for sample in samples {
        if !active && sample.value >= threshold {
            active = true
            if let latest = times.last, sample.time - latest < 0.25 { continue }
            times.append(sample.time)
        } else if active && sample.value < low + (threshold - low) / 2 {
            active = false
        }
    }
    return times
}

do {
    let args = CommandLine.arguments
    guard (2...4).contains(args.count) else {
        throw MeasurementError("Usage: swift scripts/measure-av-sync.swift recording.mp4 [x,y,width,height] [pulse-count]")
    }
    let box = (args.count >= 3 ? args[2] : "0.25,0.25,0.5,0.5")
        .split(separator: ",").compactMap { Double($0) }
    guard box.count == 4, box.allSatisfy({ $0.isFinite && $0 >= 0 }),
          box[2] > 0, box[3] > 0, box[0] + box[2] <= 1, box[1] + box[3] <= 1 else {
        throw MeasurementError("Use a flash region inside the frame with coordinates from 0 to 1.")
    }
    guard let expected = args.count == 4 ? Int(args[3]) : 5, expected > 0 else {
        throw MeasurementError("The pulse count must be positive.")
    }
    let region = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
    let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
    guard let video = try await asset.loadTracks(withMediaType: .video).first,
          let audio = try await asset.loadTracks(withMediaType: .audio).first else {
        throw MeasurementError("The recording needs both video and system audio.")
    }
    let videoLevels = try readLevels(
        asset: asset, track: video,
        settings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    ) { try brightness($0, region: region) }
    let soundLevels = try readLevels(
        asset: asset, track: audio,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ],
        levels: audioLevels
    )
    let flashes = try onsets(videoLevels, minimumRange: 0.15, trigger: 0.5)
    let beeps = try onsets(soundLevels, minimumRange: 0.01, trigger: 0.25)
    guard flashes.count == expected, beeps.count == expected else {
        throw MeasurementError("Expected \(expected) pulses. Found \(flashes.count) flashes and \(beeps.count) beeps.")
    }
    let delays = zip(flashes, beeps).map { ($1 - $0) * 1000 }
    let sorted = delays.sorted()
    let median = (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
    for (index, delay) in delays.enumerated() {
        print(String(format: "Pulse %d  audio minus video: %+.1f ms", index + 1, delay))
    }
    print(String(format: "Median audio minus video: %+.1f ms", median))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
