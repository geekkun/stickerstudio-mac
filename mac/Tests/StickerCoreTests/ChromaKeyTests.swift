import XCTest
@testable import StickerCore

final class ChromaKeyTests: XCTestCase {

    /// BGRA-буфер размером w*h, залитый одним цветом.
    func makeFrame(w: Int, h: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = b
            px[i + 1] = g
            px[i + 2] = r
            px[i + 3] = a
        }
        return px
    }

    func defaultKey() -> KeySettings {
        var k = KeySettings()
        k.enabled = true
        k.screenColor = .green
        k.gain = 100
        return k
    }

    func testSolidScreenColorBecomesTransparent() {
        let w = 16, h = 16
        var px = makeFrame(w: w, h: h, r: 0, g: 255, b: 0)
        ChromaKey.apply(toBGRA: &px, width: w, height: h, stride: w * 4, settings: defaultKey())
        for i in stride(from: 3, to: px.count, by: 4) {
            XCTAssertEqual(px[i], 0, "зелёный фон должен полностью исчезнуть")
        }
    }

    func testDistinctForegroundStaysOpaque() {
        let w = 16, h = 16
        // Красный максимально далёк от зелёного ключа в UV.
        var px = makeFrame(w: w, h: h, r: 220, g: 40, b: 40)
        ChromaKey.apply(toBGRA: &px, width: w, height: h, stride: w * 4, settings: defaultKey())
        // Центральный пиксель (края могут чуть смягчаться пером).
        let center = ((h / 2) * w + w / 2) * 4
        XCTAssertEqual(px[center + 3], 255, "красный передний план должен остаться непрозрачным")
    }

    func testDisabledKeyLeavesBufferUntouched() {
        let w = 8, h = 8
        var px = makeFrame(w: w, h: h, r: 0, g: 255, b: 0)
        let original = px
        var k = defaultKey()
        k.enabled = false
        ChromaKey.apply(toBGRA: &px, width: w, height: h, stride: w * 4, settings: k)
        XCTAssertEqual(px, original)
    }

    func testGreenEdgeIsDespilled() {
        let w = 16, h = 16
        // Левая половина — зелёный экран, правая — белый объект.
        var px = makeFrame(w: w, h: h, r: 255, g: 255, b: 255)
        for y in 0..<h {
            for x in 0..<(w / 2) {
                let i = (y * w + x) * 4
                px[i] = 0
                px[i + 1] = 255
                px[i + 2] = 0
            }
        }
        ChromaKey.apply(toBGRA: &px, width: w, height: h, stride: w * 4, settings: defaultKey())
        // Фоновая половина прозрачна, объектная - нет.
        let bg = ((h / 2) * w + 2) * 4
        let fg = ((h / 2) * w + w - 3) * 4
        XCTAssertEqual(px[bg + 3], 0)
        XCTAssertGreaterThan(px[fg + 3], 200)
    }

    func testShrinkReducesMaskGrowExpandsIt() {
        let w = 24, h = 24

        func alphaSum(shrinkGrow: Int) -> Int {
            // Белый квадрат 8x8 в центре зелёного поля.
            var px = makeFrame(w: w, h: h, r: 0, g: 255, b: 0)
            for y in 8..<16 {
                for x in 8..<16 {
                    let i = (y * w + x) * 4
                    px[i] = 255
                    px[i + 1] = 255
                    px[i + 2] = 255
                }
            }
            var k = defaultKey()
            k.shrinkGrow = shrinkGrow
            ChromaKey.apply(toBGRA: &px, width: w, height: h, stride: w * 4, settings: k)
            var sum = 0
            for i in stride(from: 3, to: px.count, by: 4) { sum += Int(px[i]) }
            return sum
        }

        let neutral = alphaSum(shrinkGrow: 0)
        let shrunk = alphaSum(shrinkGrow: -100)
        let grown = alphaSum(shrinkGrow: 100)
        XCTAssertLessThan(shrunk, neutral)
        XCTAssertGreaterThan(grown, neutral)
    }

    func testProtectTransparentColorsExtendsForegroundRGB() {
        let w = 8, h = 8
        // Непрозрачный красный слева, полностью прозрачный зелёный справа.
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if x < 4 {
                    px[i] = 0; px[i + 1] = 0; px[i + 2] = 255; px[i + 3] = 255
                } else {
                    px[i] = 0; px[i + 1] = 255; px[i + 2] = 0; px[i + 3] = 0
                }
            }
        }
        ChromaKey.protectTransparentColors(px: &px, w: w, h: h, stride: w * 4, radius: 1)
        // Первый прозрачный столбец у границы должен получить цвет foreground (красный).
        let i = (4 * w + 4) * 4
        XCTAssertEqual(px[i + 2], 255, "RGB под кромкой должен продолжать foreground")
        XCTAssertEqual(px[i + 3], 0, "alpha не меняется")
        // Дальний прозрачный столбец обнуляется.
        let far = (4 * w + 7) * 4
        XCTAssertEqual(px[far + 1], 0)
    }
}
