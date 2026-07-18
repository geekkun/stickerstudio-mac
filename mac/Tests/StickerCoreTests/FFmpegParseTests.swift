import XCTest
@testable import StickerCore

final class FFmpegParseTests: XCTestCase {

    let sampleLog = """
    Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mp4':
      Metadata:
        major_brand     : isom
      Duration: 00:00:12.48, start: 0.000000, bitrate: 4258 kb/s
      Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637634), yuv420p(tv, bt709, progressive), 1920x1080 [SAR 1:1 DAR 16:9], 4122 kb/s, 59.94 fps, 59.94 tbr, 60k tbn (default)
      Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6D6134), 48000 Hz, stereo, fltp, 128 kb/s (default)
    At least one output file must be specified
    """

    func testParsesDurationSizeFps() {
        let info = FFmpeg.parseProbeLog(sampleLog)
        XCTAssertTrue(info.ok)
        XCTAssertEqual(info.duration, 12.48, accuracy: 0.001)
        XCTAssertEqual(info.width, 1920)
        XCTAssertEqual(info.height, 1080)
        XCTAssertEqual(info.fps, 59.94, accuracy: 0.001)
        XCTAssertFalse(info.hasAlpha)
    }

    func testDetectsAlphaFormats() {
        let log = """
          Duration: 00:00:03.00, start: 0.000000, bitrate: 900 kb/s
          Stream #0:0: Video: vp9, yuva420p(tv), 512x512, 30 fps, 30 tbr, 1k tbn
        """
        let info = FFmpeg.parseProbeLog(log)
        XCTAssertTrue(info.ok)
        XCTAssertTrue(info.hasAlpha)
        XCTAssertEqual(info.width, 512)
        XCTAssertEqual(info.fps, 30, accuracy: 0.001)
    }

    func testRejectsMissingVideoStream() {
        let log = """
          Duration: 00:00:03.00, start: 0.000000, bitrate: 128 kb/s
          Stream #0:0: Audio: mp3, 44100 Hz, stereo, fltp, 128 kb/s
        """
        let info = FFmpeg.parseProbeLog(log)
        XCTAssertFalse(info.ok)
        XCTAssertNotNil(info.error)
    }

    func testRejectsZeroDuration() {
        let log = """
          Duration: 00:00:00.01, start: 0.000000, bitrate: 900 kb/s
          Stream #0:0: Video: h264, yuv420p, 640x480, 30 fps
        """
        let info = FFmpeg.parseProbeLog(log)
        XCTAssertFalse(info.ok)
    }

    func testRejectsGarbage() {
        let info = FFmpeg.parseProbeLog("clip.mp4: Invalid data found when processing input")
        XCTAssertFalse(info.ok)
    }

    func testInvFormatting() {
        XCTAssertEqual(FFmpeg.inv(6.0), "6")
        XCTAssertEqual(FFmpeg.inv(0.5), "0.5")
        XCTAssertEqual(FFmpeg.inv(1.25), "1.25")
        XCTAssertEqual(FFmpeg.inv(29.97), "29.97")
        XCTAssertEqual(FFmpeg.inv(100), "100")
    }

    func testLastLine() {
        XCTAssertEqual(FFmpeg.lastLine("a\nb\nошибка тут\n\n"), "ошибка тут")
        XCTAssertEqual(FFmpeg.lastLine(""), "ffmpeg завершился с ошибкой")
        XCTAssertEqual(FFmpeg.lastLine(nil), "ffmpeg завершился с ошибкой")
    }
}
