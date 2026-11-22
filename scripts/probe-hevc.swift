// Run with swift scripts/probe-hevc.swift on macOS.
// Encodes a synthetic frame locally, without screen capture or an RDP connection.
import Foundation
import VideoToolbox

func check(_ status: OSStatus, _ operation: String) {
    guard status == noErr else { fatalError("\(operation) failed with OSStatus \(status)") }
}

func probe(width: Int, height: Int) {
    var session: VTCompressionSession?
    let hardware = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
    check(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
        codecType: kCMVideoCodecType_HEVC, encoderSpecification: hardware as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
        refcon: nil, compressionSessionOut: &session), "create hardware encoder")
    guard let session else { fatalError("missing encoder") }
    defer { VTCompressionSessionInvalidate(session) }
    check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue), "real time")
    check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), "disable reordering")
    check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber), "frame rate")

    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
    check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer), "create input")
    guard let buffer else { fatalError("missing input") }
    check(CVPixelBufferLockBaseAddress(buffer, []), "lock input")
    guard let pixels = CVPixelBufferGetBaseAddress(buffer) else { fatalError("missing pixels") }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        memset(pixels.advanced(by: y * stride), (y / 32).isMultiple(of: 2) ? 255 : 0, width * 4)
    }
    check(CVPixelBufferUnlockBaseAddress(buffer, []), "unlock input")
    let done = DispatchSemaphore(value: 0)
    check(VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: .zero,
        duration: CMTime(value: 1, timescale: 60), frameProperties: nil, infoFlagsOut: nil) { status, flags, sample in
        check(status, "encode callback")
        guard !flags.contains(.frameDropped), let sample, let format = sample.formatDescription,
              CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC,
              sample.totalSampleSize > 0 else { fatalError("missing HEVC output") }
        print("\(width)x\(height): \(sample.totalSampleSize) bytes of hardware-encoded HEVC")
        done.signal()
    }, "submit")
    check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "flush encoder")
    guard done.wait(timeout: .now() + 5) == .success else { fatalError("output timed out") }
}

probe(width: 1920, height: 1080)
probe(width: 3840, height: 2160)
