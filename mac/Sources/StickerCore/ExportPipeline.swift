import Foundation

public struct ExportResult: Sendable {
    public var ok = false
    public var error: String?
    public var outputPath: String?
    public var size: Int64 = 0
    public var alphaInOutput = false
    public var fpsWarning = false

    public init() {}
}

/// Полный экспорт: cut -> crop/scale -> (chroma key) -> VP9 2-pass <=256КБ -> hex-патч.
///
/// Отличие от Windows-версии: вместо PNG-секвенций кадры гоняются одним
/// raw-BGRA файлом (как это уже делал playback-кэш). Это убирает зависимость
/// от кодеков изображений (и проблемы premultiplied alpha в CoreGraphics),
/// ценой большего временного файла на диске.
public enum ExportPipeline {

    public static func defaultOutputPath(forSource source: String) -> String {
        let url = URL(fileURLWithPath: source)
        let name = url.deletingPathExtension().lastPathComponent + "_sticker.webm"
        return url.deletingLastPathComponent().appendingPathComponent(name).path
    }

    public static func run(ffmpeg: String, sourcePath: String, info: ProbeInfo,
                           sourceHasAlpha: Bool, state: EditState, outputPath: String,
                           progress: ((String) -> Void)?) -> ExportResult {
        var res = ExportResult()
        let dur = state.cutEnd - state.cutStart
        if dur < 0.1 {
            res.error = "Слишком короткий отрезок"
            return res
        }

        let keyed = state.key.enabled
        let alphaOut = sourceHasAlpha || keyed
        res.alphaInOutput = alphaOut
        res.fpsWarning = info.fps > 31 && !state.fps30

        // юзер согласился «сделать как надо» — приводим к 30 fps;
        // иначе частота кадров исходника не трогается
        let fpsPrefix = state.fps30 ? "fps=30," : ""

        // Геометрию делим на две части: crop до keying и scale после него.
        // Lanczos до удаления фона смешивал зелёный экран с краем объекта,
        // поэтому экспорт давал кайму, которой не было в live-preview.
        let geometry = FrameGeometry.create(info: info, cropRect: state.cropRect)
        let preKeyFilter = geometry.preKeyFilter
        let postKeyFilter = geometry.postKeyFilter
        let scaleFilter = preKeyFilter.isEmpty ? postKeyFilter : preKeyFilter + "," + postKeyFilter

        let cutArgs = ["-ss", FFmpeg.inv(state.cutStart), "-t", FFmpeg.inv(dur)]

        let tmpDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sse_" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(atPath: tmpDir,
                                                    withIntermediateDirectories: true)
        } catch {
            res.error = error.localizedDescription
            return res
        }
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let fps = state.fps30 ? 30 : (info.fps > 0 ? info.fps : 30)

        // Вход для 2-pass кодирования: либо исходник, либо подготовленный raw.
        var encodeInputArgs: [String]
        var encodeVf: String

        if keyed {
            // 1) вырезанный/кропнутый кусок -> raw BGRA на диске
            progress?("Подготовка кадров…")
            let keyW = geometry.crop.isEmpty ? info.width : geometry.crop.width
            let keyH = geometry.crop.isEmpty ? info.height : geometry.crop.height
            let nativeRaw = (tmpDir as NSString).appendingPathComponent("native.bgra")
            let prepFilter = fpsPrefix +
                (preKeyFilter.isEmpty ? "" : preKeyFilter + ",") + "format=bgra"
            var c1: Int32 = 0
            let e1 = FFmpeg.run(ffmpeg,
                ["-y", "-hide_banner", "-loglevel", "error"]
                + cutArgs
                + ["-i", sourcePath, "-vf", prepFilter, "-an", "-sn",
                   "-f", "rawvideo", nativeRaw],
                exitCode: &c1)
            if c1 != 0 {
                res.error = "Ошибка обработки: " + FFmpeg.lastLine(e1)
                return res
            }

            // 2) хромакей на каждом кадре — тем же кодом, что и превью
            let keyResult = processRawFrames(path: nativeRaw, width: keyW, height: keyH) {
                buffer, done, total in
                ChromaKey.apply(toBGRA: &buffer, width: keyW, height: keyH,
                                stride: keyW * 4, settings: state.key)
                if done % 20 == 0 {
                    progress?("Удаление фона… \(done * 100 / max(1, total))%")
                }
            }
            if case .failure(let message) = keyResult {
                res.error = message
                return res
            }

            // Lanczos выполняем до VP9, затем расширяем foreground RGB под
            // прозрачную кромку уже в конечных 512 px. Иначе yuva420p
            // усредняет остаточный green в соседний непрозрачный пиксель.
            let scaledRaw = (tmpDir as NSString).appendingPathComponent("scaled.bgra")
            var c2: Int32 = 0
            let e2 = FFmpeg.run(ffmpeg,
                ["-y", "-hide_banner", "-loglevel", "error",
                 "-f", "rawvideo", "-pix_fmt", "bgra",
                 "-video_size", "\(keyW)x\(keyH)",
                 "-framerate", FFmpeg.inv(fps),
                 "-i", nativeRaw,
                 "-vf", postKeyFilter + ",format=bgra",
                 "-f", "rawvideo", scaledRaw],
                exitCode: &c2)
            if c2 != 0 {
                res.error = "Ошибка очистки кромки: " + FFmpeg.lastLine(e2)
                return res
            }
            try? FileManager.default.removeItem(atPath: nativeRaw)

            let outW = geometry.outputSize.width
            let outH = geometry.outputSize.height
            let prepResult = processRawFrames(path: scaledRaw, width: outW, height: outH) {
                buffer, _, _ in
                ChromaKey.prepareForVP9(px: &buffer, width: outW, height: outH,
                                        stride: outW * 4, colorRadius: 3)
            }
            if case .failure(let message) = prepResult {
                res.error = message
                return res
            }

            encodeInputArgs = ["-f", "rawvideo", "-pix_fmt", "bgra",
                               "-video_size", "\(outW)x\(outH)",
                               "-framerate", FFmpeg.inv(fps),
                               "-i", scaledRaw]
            encodeVf = "setsar=1"
        } else {
            encodeInputArgs = ["-i", sourcePath] + cutArgs
            encodeVf = fpsPrefix + scaleFilter
        }

        // 3) итеративное 2-проходное кодирование под лимит размера
        let pixFmt = alphaOut ? "yuva420p" : "yuv420p"
        var kbps = Int(Double(FFmpeg.sizeTarget) * 8 / dur * 0.93 / 1000.0)
        if kbps < 30 { kbps = 30 }

        let outTmp = (tmpDir as NSString).appendingPathComponent("out.webm")
        let bestTmp = (tmpDir as NSString).appendingPathComponent("best.webm")
        var bestSize: Int64 = -1

        for attempt in 1...4 {
            let passLog = (tmpDir as NSString).appendingPathComponent("2p_\(attempt)")
            var common = encodeInputArgs
            common += ["-an", "-sn", "-map_metadata", "-1"]
            if !keyed { common += ["-map", "0:v:0"] }
            common += ["-c:v", "libvpx-vp9", "-pix_fmt", pixFmt,
                       "-b:v", "\(kbps)k",
                       "-minrate", "\(kbps / 2)k",
                       "-maxrate", "\(kbps * 3 / 2)k",
                       "-vf", encodeVf,
                       "-deadline", "good", "-cpu-used", "0",
                       "-aq-mode", "1", "-sharpness", "2",
                       "-row-mt", "1", "-auto-alt-ref", "0",
                       "-passlogfile", passLog]

            progress?("Кодирование, попытка \(attempt) (\(kbps) кбит/с)…")
            var code1: Int32 = 0
            let err1 = FFmpeg.run(ffmpeg,
                ["-y", "-hide_banner", "-loglevel", "error"] + common +
                ["-pass", "1", "-f", "null", "/dev/null"],
                exitCode: &code1)
            if code1 != 0 {
                res.error = "Ошибка кодирования: " + FFmpeg.lastLine(err1)
                return res
            }

            var code2: Int32 = 0
            let err2 = FFmpeg.run(ffmpeg,
                ["-y", "-hide_banner", "-loglevel", "error"] + common +
                ["-pass", "2", outTmp],
                exitCode: &code2)
            if code2 != 0 || !FileManager.default.fileExists(atPath: outTmp) {
                res.error = "Ошибка кодирования: " + FFmpeg.lastLine(err2)
                return res
            }

            let size = fileSize(outTmp)
            if size <= FFmpeg.sizeLimit && size > bestSize {
                try? FileManager.default.removeItem(atPath: bestTmp)
                try? FileManager.default.copyItem(atPath: outTmp, toPath: bestTmp)
                bestSize = size
            }

            if size <= FFmpeg.sizeLimit && size >= FFmpeg.sizeLimit * 6 / 10 { break }
            if size > FFmpeg.sizeLimit {
                kbps = Int(Double(kbps) * Double(FFmpeg.sizeTarget) / Double(size) * 0.92)
                if kbps < 20 { kbps = 20 }
            } else {
                if attempt >= 2 { break }
                kbps = Int(min(6000,
                    Double(kbps) * Double(FFmpeg.sizeTarget) / Double(max(size, 1)) * 0.95))
            }
        }

        if bestSize < 0 {
            res.error = "Не удалось ужать в 256 КБ (слишком длинный/сложный ролик)"
            return res
        }

        // 4) hex-патч длительности
        do {
            var data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: bestTmp)))
            EBMLPatcher.patch(&data)
            try Data(data).write(to: URL(fileURLWithPath: outputPath))
        } catch {
            res.error = error.localizedDescription
            return res
        }

        res.ok = true
        res.outputPath = outputPath
        res.size = bestSize
        return res
    }

    // MARK: - raw frame streaming

    enum RawProcessResult {
        case success
        case failure(String)
    }

    /// Обходит raw-BGRA файл кадр за кадром, применяя `transform` на месте.
    /// В памяти держится один кадр; total считается из размера файла.
    static func processRawFrames(path: String, width: Int, height: Int,
                                 transform: (inout [UInt8], _ done: Int, _ total: Int) -> Void)
        -> RawProcessResult {
        let frameBytes = width * height * 4
        guard frameBytes > 0 else { return .failure("Пустой кадр") }
        let total = Int(fileSize(path)) / frameBytes
        if total <= 0 { return .failure("Кадры не извлеклись") }

        guard let handle = FileHandle(forUpdatingAtPath: path) else {
            return .failure("Не удалось открыть кадры")
        }
        defer { try? handle.close() }

        var buffer = [UInt8](repeating: 0, count: frameBytes)
        for index in 0..<total {
            let offset = UInt64(index) * UInt64(frameBytes)
            do {
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: frameBytes),
                      data.count == frameBytes else {
                    return .failure("Обрыв кадра #\(index + 1)")
                }
                data.copyBytes(to: &buffer, count: frameBytes)
                transform(&buffer, index + 1, total)
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: Data(buffer))
            } catch {
                return .failure(error.localizedDescription)
            }
        }
        return .success
    }

    static func fileSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
