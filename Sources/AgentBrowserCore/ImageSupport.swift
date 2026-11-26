import CoreGraphics
import Darwin
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers

enum ImageSupport {
    static func makeImage(data: Data, width: Int, height: Int, bytesPerRow: Int? = nil) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let row = bytesPerRow ?? width * 4
        guard data.count >= row * height else { return nil }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: row,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func imageFromIOSurface(
        id: UInt32,
        port: UInt32 = 0,
        width: Int,
        height: Int
    ) -> CGImage? {
        // The global-ID lookup is preferred: it yields the surface object the
        // producer meant to share. A surface from another process can still
        // arrive only as a Mach send right, so fall back to the port and
        // release the right after the lookup.
        var surface = IOSurfaceLookup(id)
        if surface == nil, port != 0 {
            surface = IOSurfaceLookupFromMachPort(port)
        }
        if port != 0 {
            mach_port_deallocate(mach_task_self_, port)
        }
        guard let surface else { return nil }
        let options = IOSurfaceLockOptions.readOnly
        let lockResult = IOSurfaceLock(surface, options, nil)
        guard lockResult == 0 else { return nil }
        defer { IOSurfaceUnlock(surface, options, nil) }
        let surfaceWidth = Int(IOSurfaceGetWidth(surface))
        let surfaceHeight = Int(IOSurfaceGetHeight(surface))
        let sourceRow = Int(IOSurfaceGetBytesPerRow(surface))
        let copyWidth = min(width, surfaceWidth)
        let copyHeight = min(height, surfaceHeight)
        guard copyWidth > 0, copyHeight > 0 else { return nil }
        let base = IOSurfaceGetBaseAddress(surface)
        var data = Data(count: copyWidth * copyHeight * 4)
        data.withUnsafeMutableBytes { destination in
            guard let destination = destination.baseAddress else { return }
            for row in 0..<copyHeight {
                memcpy(
                    destination.advanced(by: row * copyWidth * 4),
                    base.advanced(by: row * sourceRow),
                    copyWidth * 4
                )
            }
        }
        return makeImage(data: data, width: copyWidth, height: copyHeight)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A cheap content hash over the rendered pixels. It is the comparison a
    /// `wait` until `change` makes between the last capture and the current
    /// composition.
    static func hash(_ image: CGImage) -> UInt64 {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                hash ^= UInt64(bytes[index])
                hash = hash &* 0x100000001b3
                index += 1
            }
        }
        return hash
    }

    static func averageLuminance(_ image: CGImage, at point: CGPoint) -> Double {
        guard let data = image.dataProvider?.data as Data? else { return 0.5 }
        let x = max(0, min(image.width - 1, Int(point.x)))
        let y = max(0, min(image.height - 1, Int(point.y)))
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 3 < data.count else { return 0.5 }
        return data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let red = Double(bytes[offset]) / 255
            let green = Double(bytes[offset + 1]) / 255
            let blue = Double(bytes[offset + 2]) / 255
            return 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
    }
}
