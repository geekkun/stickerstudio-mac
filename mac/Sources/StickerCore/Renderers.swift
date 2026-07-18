import Foundation

/// Декодированный кадр в BGRA (без premultiply) — то, что отдаёт ffmpeg
/// `format=bgra`. UI-слой сам конвертирует в CGImage.
public struct RawFrame: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Запуск ffmpeg с возможностью отмены: процесс публикуется под локом,
/// поэтому Kill из другого потока не может проиграть гонку старту.
final class CancellableRunner {
    private let lock = NSLock()
    private var currentProcess: Process?
    private var generation: Int64 = 0
    private var stopped = false

    func bumpGeneration() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    var currentGeneration: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func stop() {
        lock.lock()
        stopped = true
        generation += 1
        let process = currentProcess
        lock.unlock()
        killAsync(process)
    }

    /// Отменяет текущий запуск (не помечая раннер остановленным).
    func cancelCurrent() {
        lock.lock()
        generation += 1
        let process = currentProcess
        lock.unlock()
        killAsync(process)
    }

    private func killAsync(_ process: Process?) {
        guard let process = process else { return }
        // Kill НЕ на вызывающем (обычно UI) потоке: остановка ffmpeg
        // блокирует на десятки мс и подвешивает перерисовку при скрабе.
        DispatchQueue.global(qos: .utility).async {
            if process.isRunning { process.terminate() }
        }
    }

    /// Возвращает (stderr, exitCode); exitCode = -1 если запуск отменён.
    func run(_ executable: String, _ arguments: [String], generation: Int64) -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-nostdin"] + arguments
        process.standardInput = FileHandle.nullDevice
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        lock.lock()
        if stopped || generation != self.generation {
            lock.unlock()
            return ("", -1)
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            return (error.localizedDescription, -1)
        }
        currentProcess = process
        lock.unlock()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        if currentProcess === process { currentProcess = nil }
        lock.unlock()

        return (String(data: errData, encoding: .utf8) ?? "", process.terminationStatus)
    }
}

// MARK: - Точный предпросмотр одного кадра

/// Запрос "точного" кадра: тот же ffmpeg-пайплайн, что и на экспорте
/// (crop → key → lanczos 512 → prepareForVP9), но для одного кадра.
public struct ExactPreviewRequest: Sendable {
    public var revision: Int64 = 0
    public var ffmpegPath = ""
    public var sourcePath = ""
    public var info = ProbeInfo()
    public var time: Double = 0
    public var cropRect = PixelRect.empty
    public var key = KeySettings()
    /// Для предпросмотра готового WebM: заставляет libvpx декодировать альфу.
    public var decodeVP9Alpha = false

    public init() {}
}

/// Последовательный воркер "последний запрос побеждает" — порт
/// ExactPreviewRenderer из EditorUI.cs.
public final class ExactPreviewRenderer {
    private let queue = DispatchQueue(label: "stickerstudio.exact-preview", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: ExactPreviewRequest?
    private var draining = false
    private let runner = CancellableRunner()

    /// (revision, кадр) — вызывается на фоновом потоке.
    public var completed: ((Int64, RawFrame) -> Void)?

    public init() {}

    public func request(_ request: ExactPreviewRequest) {
        lock.lock()
        pending = request
        let needDrain = !draining
        if needDrain { draining = true }
        lock.unlock()
        if needDrain {
            queue.async { [weak self] in self?.drain() }
        }
    }

    public func cancelPending() {
        lock.lock()
        pending = nil
        lock.unlock()
        runner.cancelCurrent()
    }

    public func shutdown() {
        lock.lock()
        pending = nil
        lock.unlock()
        runner.stop()
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            let generation = runner.bumpGeneration()
            var frame = render(request, generation: generation)
            if frame == nil {
                // одиночный ретрай, если нас не отменили и не перекрыли новым запросом
                lock.lock()
                let retry = pending == nil
                lock.unlock()
                if retry && generation == runner.currentGeneration {
                    frame = render(request, generation: generation)
                }
            }
            if let frame = frame {
                completed?(request.revision, frame)
            }
        }
    }

    private func render(_ request: ExactPreviewRequest, generation: Int64) -> RawFrame? {
        guard !request.ffmpegPath.isEmpty, !request.sourcePath.isEmpty,
              request.info.width > 0 else { return nil }

        let tempDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ssp_" + UUID().uuidString)
        guard (try? FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let geometry = FrameGeometry.create(info: request.info, cropRect: request.cropRect)
        let nativeRaw = (tempDir as NSString).appendingPathComponent("native.bgra")
        let finalRaw = (tempDir as NSString).appendingPathComponent("final.bgra")
        let nativeW = geometry.crop.isEmpty ? request.info.width : geometry.crop.width
        let nativeH = geometry.crop.isEmpty ? request.info.height : geometry.crop.height

        let prepFilter = (geometry.preKeyFilter.isEmpty ? "" : geometry.preKeyFilter + ",")
            + "format=bgra"

        // -ss ПЕРЕД -i: ffmpeg прыгает к ключевому кадру и декодирует
        // только хвост до нужного времени, а не весь файл с нуля
        var args = ["-y", "-hide_banner", "-loglevel", "error",
                    "-ss", FFmpeg.inv(request.time)]
        if request.decodeVP9Alpha { args += ["-c:v", "libvpx-vp9"] }
        args += ["-i", request.sourcePath, "-frames:v", "1",
                 "-vf", prepFilter, "-f", "rawvideo", nativeRaw]
        var (_, code) = runner.run(request.ffmpegPath, args, generation: generation)
        guard code == 0, var native = readRawFrame(path: nativeRaw, width: nativeW, height: nativeH)
        else { return nil }

        if request.key.enabled {
            ChromaKey.apply(toBGRA: &native.pixels, width: nativeW, height: nativeH,
                            stride: nativeW * 4, settings: request.key)
            guard (try? Data(native.pixels).write(to: URL(fileURLWithPath: nativeRaw))) != nil
            else { return nil }
        }

        (_, code) = runner.run(request.ffmpegPath,
            ["-y", "-hide_banner", "-loglevel", "error",
             "-f", "rawvideo", "-pix_fmt", "bgra",
             "-video_size", "\(nativeW)x\(nativeH)",
             "-i", nativeRaw, "-frames:v", "1",
             "-vf", geometry.postKeyFilter + ",format=bgra",
             "-f", "rawvideo", finalRaw],
            generation: generation)
        guard code == 0,
              var final = readRawFrame(path: finalRaw,
                                       width: geometry.outputSize.width,
                                       height: geometry.outputSize.height)
        else { return nil }

        if request.key.enabled {
            ChromaKey.prepareForVP9(px: &final.pixels,
                                    width: final.width, height: final.height,
                                    stride: final.width * 4, colorRadius: 3)
        }
        return final
    }

    private func readRawFrame(path: String, width: Int, height: Int) -> RawFrame? {
        guard let data = FileManager.default.contents(atPath: path),
              data.count >= width * height * 4 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        data.copyBytes(to: &pixels, count: pixels.count)
        return RawFrame(width: width, height: height, pixels: pixels)
    }
}

// MARK: - Кэш чёткого воспроизведения

public struct PlaybackPreviewRequest: Sendable {
    public var revision: Int64 = 0
    public var ffmpegPath = ""
    public var sourcePath = ""
    public var info = ProbeInfo()
    public var start: Double = 0
    public var end: Double = 0
    public var fps: Double = 30
    public var cropRect = PixelRect.empty
    public var key = KeySettings()

    public init() {}
}

/// Кадры лежат единым BGRA-файлом на диске: 6 секунд при 30 fps занимают
/// до ~190 МБ на диске, но в памяти остаются только один кадр и read-buffer.
public final class PlaybackCache {
    private let lock = NSLock()
    private let directory: String
    private let rawPath: String
    private var handle: FileHandle?
    private var disposed = false

    public let revision: Int64
    public let start: Double
    public let end: Double
    public let fps: Double
    public let width: Int
    public let height: Int
    public let frameCount: Int

    init(directory: String, rawPath: String, revision: Int64,
         start: Double, end: Double, fps: Double,
         width: Int, height: Int, frameCount: Int) {
        self.directory = directory
        self.rawPath = rawPath
        self.revision = revision
        self.start = start
        self.end = end
        self.fps = fps
        self.width = width
        self.height = height
        self.frameCount = frameCount
    }

    public func frameIndex(at time: Double) -> Int {
        guard frameCount > 0, fps > 0 else { return -1 }
        let index = Int(((time - start) * fps + 0.0001).rounded(.down))
        return max(0, min(frameCount - 1, index))
    }

    public func decodeFrame(_ index: Int) -> RawFrame? {
        guard index >= 0, index < frameCount else { return nil }
        let frameBytes = width * height * 4
        lock.lock()
        defer { lock.unlock() }
        if disposed { return nil }
        if handle == nil {
            handle = FileHandle(forReadingAtPath: rawPath)
        }
        guard let handle = handle else { return nil }
        do {
            try handle.seek(toOffset: UInt64(index) * UInt64(frameBytes))
            guard let data = try handle.read(upToCount: frameBytes),
                  data.count == frameBytes else { return nil }
            var pixels = [UInt8](repeating: 0, count: frameBytes)
            data.copyBytes(to: &pixels, count: frameBytes)
            return RawFrame(width: width, height: height, pixels: pixels)
        } catch {
            return nil
        }
    }

    public func dispose() {
        lock.lock()
        if disposed {
            lock.unlock()
            return
        }
        disposed = true
        try? handle?.close()
        handle = nil
        lock.unlock()
        try? FileManager.default.removeItem(atPath: directory)
    }

    deinit {
        dispose()
    }
}

/// Сборка кэша: один ffmpeg-проход сразу в raw BGRA на выходном размере,
/// затем (если включён) хромакей прямо по raw-кадрам. Порт
/// PlaybackPreviewRenderer из EditorUI.cs.
public final class PlaybackPreviewRenderer {
    private let queue = DispatchQueue(label: "stickerstudio.playback-cache", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: PlaybackPreviewRequest?
    private var draining = false
    private let runner = CancellableRunner()

    /// (revision, кэш) на фоновом потоке.
    public var completed: ((Int64, PlaybackCache) -> Void)?
    /// (revision, текст ошибки) на фоновом потоке.
    public var failed: ((Int64, String) -> Void)?

    public init() {
        PlaybackPreviewRenderer.cleanupOldCaches()
    }

    public func request(_ request: PlaybackPreviewRequest) {
        lock.lock()
        pending = request
        let needDrain = !draining
        if needDrain { draining = true }
        lock.unlock()
        if needDrain {
            queue.async { [weak self] in self?.drain() }
        }
    }

    public func cancelPending() {
        lock.lock()
        pending = nil
        lock.unlock()
        runner.cancelCurrent()
    }

    public func shutdown() {
        lock.lock()
        pending = nil
        lock.unlock()
        runner.stop()
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            let generation = runner.bumpGeneration()
            var error = "Не удалось подготовить качественное воспроизведение"
            let cache = build(request, generation: generation, error: &error)

            let current = generation == runner.currentGeneration
            if !current {
                cache?.dispose()
                continue
            }
            if let cache = cache {
                completed?(request.revision, cache)
            } else {
                failed?(request.revision, error)
            }
        }
    }

    private func build(_ request: PlaybackPreviewRequest, generation: Int64,
                       error: inout String) -> PlaybackCache? {
        guard request.info.width > 0, request.end - request.start >= 0.05,
              !request.ffmpegPath.isEmpty, !request.sourcePath.isEmpty else { return nil }

        let tempDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ssplay_" + UUID().uuidString)
        var keep = false
        do {
            try FileManager.default.createDirectory(atPath: tempDir,
                                                    withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer {
            if !keep { try? FileManager.default.removeItem(atPath: tempDir) }
        }

        let geometry = FrameGeometry.create(info: request.info, cropRect: request.cropRect)
        let rawPath = (tempDir as NSString).appendingPathComponent("frames.bgra")

        // -ss/-t ПЕРЕД -i: мгновенный прыжок к отрезку вместо
        // декодирования исходника с самого начала при каждой пересборке
        let filters = "fps=" + FFmpeg.inv(request.fps) + "," +
            (geometry.preKeyFilter.isEmpty ? "" : geometry.preKeyFilter + ",") +
            geometry.postKeyFilter + ",format=bgra"
        let (log, code) = runner.run(request.ffmpegPath,
            ["-y", "-hide_banner", "-loglevel", "error",
             "-ss", FFmpeg.inv(request.start),
             "-t", FFmpeg.inv(request.end - request.start),
             "-i", request.sourcePath,
             "-vf", filters, "-an", "-sn",
             "-f", "rawvideo", rawPath],
            generation: generation)

        guard code == 0, FileManager.default.fileExists(atPath: rawPath) else {
            error = "Кэш воспроизведения: " + FFmpeg.lastLine(log)
            return nil
        }

        let outW = geometry.outputSize.width
        let outH = geometry.outputSize.height

        if request.key.enabled {
            let result = ExportPipeline.processRawFrames(path: rawPath, width: outW, height: outH) {
                buffer, _, _ in
                ChromaKey.apply(toBGRA: &buffer, width: outW, height: outH,
                                stride: outW * 4, settings: request.key)
            }
            if case .failure(let message) = result {
                error = message
                return nil
            }
            // Отмена во время долгого CPU-кия: не отдаём устаревший кэш.
            if generation != runner.currentGeneration { return nil }
        }

        let frameBytes = outW * outH * 4
        let count = Int(ExportPipeline.fileSize(rawPath)) / frameBytes
        guard count > 0 else { return nil }

        keep = true
        return PlaybackCache(directory: tempDir, rawPath: rawPath,
                             revision: request.revision,
                             start: request.start, end: request.end, fps: request.fps,
                             width: outW, height: outH, frameCount: count)
    }

    /// Осиротевшие кэши прошлых запусков (краш, kill) подчищаются по возрасту.
    static func cleanupOldCaches() {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            let temp = NSTemporaryDirectory()
            guard let names = try? fm.contentsOfDirectory(atPath: temp) else { return }
            for name in names where name.hasPrefix("ssplay_") {
                let dir = (temp as NSString).appendingPathComponent(name)
                if let attrs = try? fm.attributesOfItem(atPath: dir),
                   let modified = attrs[.modificationDate] as? Date,
                   modified < Date().addingTimeInterval(-2 * 3600) {
                    try? fm.removeItem(atPath: dir)
                }
            }
        }
    }
}
