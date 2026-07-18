import Foundation

/// Цвет ключа без привязки к UI-фреймворку.
public struct RGBColor: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let green = RGBColor(r: 0, g: 255, b: 0)
}

public struct KeySettings: Equatable, Sendable {
    public var enabled = false
    public var screenColor = RGBColor.green
    /// Сила удаления, 0...200 (100 по умолчанию).
    public var gain = 100
    /// Поджать (−) или расширить (+) края маски, -100...100.
    public var shrinkGrow = 0

    public init() {}
}

/// Неразрушающее состояние правок; значение целиком служит снапшотом для undo.
public struct EditState: Equatable, Sendable {
    /// В координатах ОРИГИНАЛА; .empty = кропа нет.
    public var cropRect = PixelRect.empty
    public var cutStart: Double = 0
    public var cutEnd: Double = 0
    public var key = KeySettings()
    /// Пересчитать в 30 fps (решение юзера на экспорте).
    public var fps30 = false

    public init() {}

    public var cutDuration: Double { cutEnd - cutStart }
}
