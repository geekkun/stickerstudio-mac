import XCTest
@testable import StickerCore

final class FrameGeometryTests: XCTestCase {

    func makeInfo(width: Int, height: Int) -> ProbeInfo {
        var info = ProbeInfo()
        info.ok = true
        info.width = width
        info.height = height
        info.duration = 5
        info.fps = 30
        return info
    }

    func testCropGeometryScalesTo512() {
        let info = makeInfo(width: 1920, height: 1080)
        let g = FrameGeometry.create(info: info,
                                     cropRect: PixelRect(x: 100, y: 40, width: 900, height: 900))
        XCTAssertEqual(g.crop, PixelRect(x: 100, y: 40, width: 900, height: 900))
        XCTAssertEqual(g.outputSize, PixelSize(width: 512, height: 512))
        XCTAssertEqual(g.preKeyFilter, "crop=900:900:100:40")
        XCTAssertEqual(g.postKeyFilter, "scale=512:512:flags=lanczos,setsar=1")
    }

    func testCropIsClampedToSourceBounds() {
        let info = makeInfo(width: 640, height: 480)
        let g = FrameGeometry.create(info: info,
                                     cropRect: PixelRect(x: 600, y: 460, width: 300, height: 300))
        XCTAssertLessThanOrEqual(g.crop.x + g.crop.width, 640)
        XCTAssertLessThanOrEqual(g.crop.y + g.crop.height, 480)
        XCTAssertGreaterThanOrEqual(g.crop.width, 2)
    }

    func testNoCropLandscapeKeepsAspectAndEvenDims() {
        let info = makeInfo(width: 400, height: 300)
        let g = FrameGeometry.create(info: info, cropRect: .empty)
        XCTAssertEqual(g.outputSize.width, 512)
        // 300 * 512 / 400 = 384 — чётное
        XCTAssertEqual(g.outputSize.height, 384)
        XCTAssertEqual(g.preKeyFilter, "")
    }

    func testNoCropPortraitRoundsToEven() {
        let info = makeInfo(width: 333, height: 500)
        let g = FrameGeometry.create(info: info, cropRect: .empty)
        XCTAssertEqual(g.outputSize.height, 512)
        // 333 * 512 / 500 = 340.99 → 341 → чётное 340
        XCTAssertEqual(g.outputSize.width, 340)
    }

    func testEvenHelper() {
        XCTAssertEqual(FrameGeometry.even(341.0), 340)
        XCTAssertEqual(FrameGeometry.even(340.0), 340)
        XCTAssertEqual(FrameGeometry.even(1.0), 2)
        XCTAssertEqual(FrameGeometry.even(2.6), 2)
    }
}
