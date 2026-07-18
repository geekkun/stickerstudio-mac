import Foundation
import StickerCore

// Консольный экспортёр — аналог Windows-режима `StickerStudio.exe /export`.
// Позволяет тестировать пайплайн без UI:
//   stickerctl export <in> <out> [crop=x:y:size] [cut=a:b] [key=RRGGBB[:gain[:shrink]]] [fps30]
//   stickerctl probe <in>

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("""
    usage:
      stickerctl export <in> <out> [crop=x:y:size] [cut=a:b] [key=RRGGBB[:gain[:shrink]]] [fps30]
      stickerctl probe <in>
    """, code: 64)
}

guard let ffmpeg = FFmpeg.find() else {
    fail("ffmpeg не найден (положите рядом, либо brew install ffmpeg)", code: 2)
}

switch args[1] {
case "probe":
    guard args.count >= 3 else { fail("probe: нужен путь к файлу", code: 64) }
    let info = FFmpeg.probe(ffmpeg, input: args[2])
    if !info.ok { fail(info.error ?? "probe failed", code: 3) }
    print("duration=\(FFmpeg.inv(info.duration)) size=\(info.width)x\(info.height) " +
          "fps=\(FFmpeg.inv(info.fps)) alpha=\(info.hasAlpha)")

case "export":
    guard args.count >= 4 else { fail("export: нужны входной и выходной пути", code: 64) }
    let input = args[2]
    let output = args[3]

    let info = FFmpeg.probe(ffmpeg, input: input)
    if !info.ok { fail("probe: " + (info.error ?? "?"), code: 3) }

    var state = EditState()
    state.cutStart = 0
    state.cutEnd = min(info.duration, VideoLimits.maxCutSeconds)

    for a in args.dropFirst(4) {
        if a.lowercased().hasPrefix("crop=") {
            let p = a.dropFirst(5).split(separator: ":").compactMap { Int($0) }
            if p.count >= 3 {
                state.cropRect = PixelRect(x: p[0], y: p[1], width: p[2], height: p[2])
            }
        } else if a.lowercased().hasPrefix("cut=") {
            let p = a.dropFirst(4).split(separator: ":").compactMap { Double($0) }
            if p.count >= 2 {
                state.cutStart = p[0]
                state.cutEnd = p[1]
                if state.cutEnd - state.cutStart > VideoLimits.maxCutSeconds {
                    state.cutEnd = state.cutStart + VideoLimits.maxCutSeconds
                }
            }
        } else if a.lowercased() == "fps30" {
            state.fps30 = true
        } else if a.lowercased().hasPrefix("key=") {
            let p = a.dropFirst(4).split(separator: ":")
            if let rgb = UInt32(p[0], radix: 16) {
                state.key.enabled = true
                state.key.screenColor = RGBColor(
                    r: UInt8((rgb >> 16) & 255),
                    g: UInt8((rgb >> 8) & 255),
                    b: UInt8(rgb & 255))
                if p.count > 1, let gain = Int(p[1]) { state.key.gain = gain }
                if p.count > 2, let sg = Int(p[2]) { state.key.shrinkGrow = sg }
            }
        }
    }

    let result = ExportPipeline.run(ffmpeg: ffmpeg, sourcePath: input, info: info,
                                    sourceHasAlpha: info.hasAlpha, state: state,
                                    outputPath: output) { message in
        print(message)
    }
    if !result.ok { fail("export: " + (result.error ?? "?"), code: 1) }
    print("OK \(result.outputPath ?? output) (\(result.size) байт" +
          (result.alphaInOutput ? ", с альфой" : "") + ")")
    if result.fpsWarning {
        print("⚠ fps выше 30 — Telegram может отклонить файл")
    }

default:
    fail("неизвестная команда: \(args[1])", code: 64)
}
