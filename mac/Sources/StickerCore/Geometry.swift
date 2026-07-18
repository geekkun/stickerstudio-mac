import Foundation

/// Целочисленный прямоугольник в пиксельных координатах (аналог System.Drawing.Rectangle).
public struct PixelRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public static let empty = PixelRect(x: 0, y: 0, width: 0, height: 0)

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Ограничения Telegram-видеостикера и превью.
public enum VideoLimits {
    public static let maxInputSeconds: Double = 180
    public static let maxCutSeconds: Double = 6
    public static let minCutSeconds: Double = 0.5
    public static let stickerSide = 512
}

/// Одна геометрия для export и точного preview. Crop всегда считается в
/// координатах оригинала, scale выполняется только после chroma key.
public struct StickerFrameGeometry: Sendable {
    public var crop: PixelRect = .empty
    public var outputSize = PixelSize(width: 0, height: 0)
    /// ffmpeg-фильтр до хромакея (crop) или пустая строка.
    public var preKeyFilter = ""
    /// ffmpeg-фильтр после хромакея (scale + setsar).
    public var postKeyFilter = ""
}

public enum FrameGeometry {
    public static func create(info: ProbeInfo?, cropRect: PixelRect) -> StickerFrameGeometry {
        var g = StickerFrameGeometry()
        guard let info = info else { return g }

        if !cropRect.isEmpty {
            let cx = max(0, min(cropRect.x, info.width - 2))
            let cy = max(0, min(cropRect.y, info.height - 2))
            let cw = max(2, min(cropRect.width, info.width - cx))
            let ch = max(2, min(cropRect.height, info.height - cy))
            g.crop = PixelRect(x: cx, y: cy, width: cw, height: ch)
            g.outputSize = PixelSize(width: VideoLimits.stickerSide,
                                     height: VideoLimits.stickerSide)
            g.preKeyFilter = "crop=\(cw):\(ch):\(cx):\(cy)"
        } else {
            var w: Int
            var h: Int
            if info.width >= info.height {
                w = VideoLimits.stickerSide
                h = even(Double(info.height) * Double(VideoLimits.stickerSide) / Double(info.width))
            } else {
                h = VideoLimits.stickerSide
                w = even(Double(info.width) * Double(VideoLimits.stickerSide) / Double(info.height))
            }
            g.crop = .empty
            g.outputSize = PixelSize(width: w, height: h)
            g.preKeyFilter = ""
        }

        g.postKeyFilter = "scale=\(g.outputSize.width):\(g.outputSize.height):flags=lanczos,setsar=1"
        return g
    }

    static func even(_ value: Double) -> Int {
        var n = Int(value.rounded())
        if n % 2 != 0 { n -= 1 }
        return max(2, n)
    }
}
