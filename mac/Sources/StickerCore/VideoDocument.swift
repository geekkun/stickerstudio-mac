import Foundation

/// Открытый документ: probe-инфо, превью-кадры в памяти, состояние правок
/// и undo-стек. Порт VideoDoc.cs; декодирование картинок для показа —
/// забота UI-слоя (ImageIO), здесь только байты PNG/JPEG.
public final class VideoDocument {
    public private(set) var sourcePath = ""
    public private(set) var info = ProbeInfo()
    public private(set) var sourceHasAlpha = false

    /// Превью-кадры: png (если у исходника альфа) или jpg.
    public private(set) var frames: [Data] = []
    public private(set) var previewFps: Double = 30
    public private(set) var previewWidth = 0
    public private(set) var previewHeight = 0

    public var state = EditState()
    private var undoStack: [EditState] = []

    public init() {}

    public var cropRequired: Bool {
        info.ok && (info.width > VideoLimits.stickerSide || info.height > VideoLimits.stickerSide)
    }

    public var cropApplied: Bool { !state.cropRect.isEmpty }

    public var canUndo: Bool { !undoStack.isEmpty }

    public func pushUndo() {
        undoStack.append(state)
    }

    /// Для случаев, когда снапшот "до" сделан заранее (драг таймлайна).
    public func pushUndoSnapshot(_ snapshot: EditState) {
        undoStack.append(snapshot)
    }

    @discardableResult
    public func undo() -> Bool {
        guard let last = undoStack.popLast() else { return false }
        state = last
        return true
    }

    public var cutDuration: Double { state.cutEnd - state.cutStart }

    public func frameIndex(at seconds: Double) -> Int {
        guard !frames.isEmpty else { return 0 }
        var idx = Int((seconds * previewFps).rounded(.down))
        if idx < 0 { idx = 0 }
        if idx >= frames.count { idx = frames.count - 1 }
        return idx
    }

    public func time(ofFrame idx: Int) -> Double {
        Double(idx) / previewFps
    }

    /// Загрузка: probe + извлечение превью-кадров во временную папку -> память.
    /// progress(процент 0..100, текст). Возвращает nil при успехе, иначе текст ошибки.
    public func load(ffmpeg: String, path: String,
                     progress: ((Int, String) -> Void)?) -> String? {
        sourcePath = path
        info = FFmpeg.probe(ffmpeg, input: path)
        guard info.ok else {
            return "Не удалось открыть видео: " + (info.error ?? "?")
        }
        if info.duration > VideoLimits.maxInputSeconds {
            return "Видео длиннее \(Int(VideoLimits.maxInputSeconds)) секунд. " +
                   "Для стикера загрузите ролик покороче."
        }

        sourceHasAlpha = info.hasAlpha

        state.cutStart = 0
        state.cutEnd = min(info.duration, VideoLimits.maxCutSeconds)
        if state.cutEnd - state.cutStart < VideoLimits.minCutSeconds {
            state.cutEnd = min(info.duration, state.cutStart + VideoLimits.minCutSeconds)
        }

        // размер превью: длинная сторона <= 400, чётные
        var pw: Int
        var ph: Int
        if info.width >= info.height {
            pw = min(400, info.width)
            ph = max(2, Int((Double(info.height) * Double(pw) / Double(info.width)).rounded()))
        } else {
            ph = min(400, info.height)
            pw = max(2, Int((Double(info.width) * Double(ph) / Double(info.height)).rounded()))
        }
        if pw % 2 != 0 { pw -= 1 }
        if ph % 2 != 0 { ph -= 1 }
        previewWidth = pw
        previewHeight = ph

        previewFps = (info.fps > 0 && info.fps <= 30) ? info.fps : 30.0
        let expected = Int(ceil(info.duration * previewFps)) + 2

        let tmpDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sst_" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(atPath: tmpDir,
                                                    withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let ext = sourceHasAlpha ? "png" : "jpg"
        var args = ["-y", "-hide_banner", "-loglevel", "error",
                    "-i", path,
                    "-vf", "fps=" + FFmpeg.inv(previewFps) + ",scale=\(pw):\(ph)"]
        if !sourceHasAlpha { args += ["-q:v", "4"] }
        args.append((tmpDir as NSString).appendingPathComponent("f%05d." + ext))

        // прогресс по числу появившихся файлов
        var done = false
        let doneLock = NSLock()
        if let progress = progress {
            DispatchQueue.global(qos: .utility).async {
                while true {
                    doneLock.lock()
                    let finished = done
                    doneLock.unlock()
                    if finished { return }
                    let n = (try? FileManager.default
                        .contentsOfDirectory(atPath: tmpDir).count) ?? 0
                    let pct = min(99, n * 100 / max(1, expected))
                    progress(pct, "Подготовка превью… \(pct)%")
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }

        var code: Int32 = 0
        let err = FFmpeg.run(ffmpeg, args, exitCode: &code)
        doneLock.lock()
        done = true
        doneLock.unlock()
        if code != 0 {
            return "Не удалось прочитать видео: " + FFmpeg.lastLine(err)
        }

        let files = ((try? FileManager.default.contentsOfDirectory(atPath: tmpDir)) ?? [])
            .filter { $0.hasPrefix("f") && $0.hasSuffix("." + ext) }
            .sorted()
        if files.isEmpty {
            return "Не удалось извлечь кадры из видео"
        }

        frames.removeAll()
        frames.reserveCapacity(files.count)
        for name in files {
            let p = (tmpDir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: p) else { continue }
            frames.append(data)
        }
        if frames.isEmpty {
            return "Не удалось извлечь кадры из видео"
        }

        progress?(100, "Готово")
        return nil
    }
}
