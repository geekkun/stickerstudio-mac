import XCTest
@testable import StickerCore

final class EBMLPatcherTests: XCTestCase {

    func testPatchesFloatDuration() {
        // 44 89 84 <float32 6.0 = 40 C0 00 00>
        var data: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3,
                             0x44, 0x89, 0x84, 0x40, 0xC0, 0x00, 0x00, 0x55]
        XCTAssertEqual(EBMLPatcher.patch(&data), .applied)
        XCTAssertEqual(Array(data[7...10]), [0x3F, 0x80, 0x00, 0x00])
        XCTAssertEqual(data[11], 0x55, "байт после поля не должен быть тронут")
        XCTAssertEqual(EBMLPatcher.patch(&data), .alreadyPatched)
    }

    func testPatchesDoubleDuration() {
        // 44 89 88 <float64 6.0 = 40 18 00 00 00 00 00 00>
        var data: [UInt8] = [0x00, 0x44, 0x89, 0x88,
                             0x40, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x77]
        XCTAssertEqual(EBMLPatcher.patch(&data), .applied)
        XCTAssertEqual(Array(data[4...11]), [0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(data[12], 0x77)
        XCTAssertEqual(EBMLPatcher.patch(&data), .alreadyPatched)
    }

    func testLegacyFallbackForUnknownSizeByte() {
        // Неизвестный size-байт (0x83) — легаси-путь пишет 84 3F 80 00 начиная с size-байта.
        var data: [UInt8] = [0x44, 0x89, 0x83, 0x01, 0x02, 0x03, 0x04]
        XCTAssertEqual(EBMLPatcher.patch(&data), .applied)
        XCTAssertEqual(Array(data[2...5]), [0x84, 0x3F, 0x80, 0x00])
        XCTAssertEqual(EBMLPatcher.patch(&data), .alreadyPatched)
    }

    func testNotFoundWhenNoDurationId() {
        var data: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(EBMLPatcher.patch(&data), .notFound)
    }

    func testNotFoundWhenTruncated() {
        var data: [UInt8] = [0x44, 0x89, 0x84]
        XCTAssertEqual(EBMLPatcher.patch(&data), .notFound)
    }
}
