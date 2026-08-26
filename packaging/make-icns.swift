import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make-icns <source.png> <output.icns>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = CGImageSourceCreateWithURL(sourceURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fputs("could not decode source image\n", stderr)
    exit(1)
}

func renderPNG(size: Int) -> Data? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    context.interpolationQuality = .high
    context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: size, height: size))

    guard let rendered = context.makeImage() else {
        return nil
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        return nil
    }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else {
        return nil
    }
    return data as Data
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { bytes in
        data.append(contentsOf: bytes)
    }
}

// Standard 1x and Retina ICNS element types, matching a complete macOS
// AppIcon.iconset without asking iconutil to re-package the generated PNGs.
let representations: [(type: String, size: Int)] = [
    ("icp4", 16),
    ("ic11", 32),
    ("icp5", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024),
]

var elements: [(type: String, png: Data)] = []
for representation in representations {
    guard let png = renderPNG(size: representation.size) else {
        fputs("could not render \(representation.size)x\(representation.size) PNG\n", stderr)
        exit(1)
    }
    elements.append((representation.type, png))
}

let totalLength = 8 + elements.reduce(0) { $0 + 8 + $1.png.count }
guard totalLength <= Int(UInt32.max) else {
    fputs("generated icon is too large\n", stderr)
    exit(1)
}

var icns = Data("icns".utf8)
appendBigEndian(UInt32(totalLength), to: &icns)
for element in elements {
    icns.append(Data(element.type.utf8))
    appendBigEndian(UInt32(element.png.count + 8), to: &icns)
    icns.append(element.png)
}

do {
    try icns.write(to: outputURL, options: .atomic)
} catch {
    fputs("could not write ICNS: \(error)\n", stderr)
    exit(1)
}
