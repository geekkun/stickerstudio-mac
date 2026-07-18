import Foundation

/// Telegram проверяет длительность видеостикера по полю Duration в контейнере
/// WebM/EBML. После кодирования находим это поле (id `44 89`) и записываем
/// валидное значение `1.0` — клиенты Telegram принимают такой стикер длиной
/// до 6 секунд.
public enum EBMLPatcher {
    static let legacy: [UInt8] = [0x84, 0x3F, 0x80, 0x00]
    static let float1: [UInt8] = [0x3F, 0x80, 0x00, 0x00]
    static let double1: [UInt8] = [0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    public enum Result: Equatable {
        case notFound
        case applied
        case alreadyPatched
    }

    @discardableResult
    public static func patch(_ data: inout [UInt8]) -> Result {
        var idx = -1
        var i = 0
        while i + 1 < data.count {
            if data[i] == 0x44 && data[i + 1] == 0x89 {
                idx = i
                break
            }
            i += 1
        }
        if idx < 0 || idx + 6 > data.count { return .notFound }

        let sizeByte = data[idx + 2]

        if sizeByte == 0x84 {
            if startsWith(data, offset: idx + 3, pattern: float1, count: 3) {
                return .alreadyPatched
            }
            if idx + 3 + 4 > data.count { return .notFound }
            for j in 0..<4 { data[idx + 3 + j] = float1[j] }
            return .applied
        }

        if sizeByte == 0x88 && idx + 3 + 8 <= data.count {
            if startsWith(data, offset: idx + 3, pattern: double1, count: 4) {
                return .alreadyPatched
            }
            for j in 0..<8 { data[idx + 3 + j] = double1[j] }
            return .applied
        }

        if startsWith(data, offset: idx + 2, pattern: legacy, count: 4) {
            return .alreadyPatched
        }
        for j in 0..<4 { data[idx + 2 + j] = legacy[j] }
        return .applied
    }

    static func startsWith(_ data: [UInt8], offset: Int, pattern: [UInt8], count: Int) -> Bool {
        if offset + count > data.count { return false }
        for i in 0..<count where data[offset + i] != pattern[i] {
            return false
        }
        return true
    }
}
