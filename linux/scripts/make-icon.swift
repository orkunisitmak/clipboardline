// Package the existing macOS artwork into a Windows ICO; no new artwork.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == 1024, image.height == 1024 else { fatalError("Expected the shared 1024px PNG") }
let sizes = [16, 24, 32, 48, 64, 128, 256]
let frames: [Data] = sizes.map { size in
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG frame encoding failed") }
    return data as Data
}
var output = Data()
func u16(_ value: Int) { output.append(contentsOf: [UInt8(value & 255), UInt8((value >> 8) & 255)]) }
func u32(_ value: Int) { output.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
u16(0); u16(1); u16(sizes.count)
var offset = 6 + 16 * sizes.count
for (size, frame) in zip(sizes, frames) {
    output.append(contentsOf: [UInt8(size & 255), UInt8(size & 255), 0, 0])
    u16(1); u16(32); u32(frame.count); u32(offset)
    offset += frame.count
}
for frame in frames { output.append(frame) }
try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
