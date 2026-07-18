#if os(macOS)
import Foundation
import CoreGraphics
import ImageIO
import StickerCore

/// Конвертация кадров ядра (BGRA, straight alpha) в CGImage и декодирование
/// превью-кадров (png/jpg). ImageIO живёт только в UI-слое — ядро остаётся
/// переносимым.
enum ImageConversion {

    /// RawFrame (BGRA, non-premultiplied) → CGImage без копий формата:
    /// CGImage умеет kCGImageAlphaFirst + byteOrder32Little напрямую.
    static func cgImage(from frame: RawFrame) -> CGImage? {
        let bytesPerRow = frame.width * 4
        guard frame.pixels.count >= bytesPerRow * frame.height else { return nil }
        guard let provider = CGDataProvider(data: Data(frame.pixels) as CFData) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: frame.width,
                       height: frame.height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// PNG/JPEG-байты превью-кадра → CGImage.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Превью-кадр → BGRA-буфер для хромакея/пипетки. Кадры превью непрозрачны
    /// (кий применяется только к исходникам без альфы), поэтому premultiply
    /// в CGContext ничего не искажает.
    static func decodeBGRA(_ data: Data, width: Int, height: Int) -> [UInt8]? {
        guard let image = decode(data) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }

    /// BGRA-буфер → CGImage (straight alpha).
    static func cgImage(fromBGRA pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        cgImage(from: RawFrame(width: width, height: height, pixels: pixels))
    }
}
#endif
