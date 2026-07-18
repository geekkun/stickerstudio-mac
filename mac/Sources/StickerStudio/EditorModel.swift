#if os(macOS)
import AppKit
import Combine
import CoreGraphics
import Foundation
import StickerCore

enum InspectorMode {
    case main
    case crop
    case key
}

/// Логика экрана редактора — порт EditorView.cs. Все публичные методы
/// вызываются с главного потока; колбэки рендереров прыгают на main сами.
final class EditorModel: ObservableObject {
    let doc: VideoDocument
    let ffmpegPath: String
    var onBack: () -> Void = {}

    // MARK: - публикуемое состояние

    /// Растёт при каждом изменении doc.state — заставляет вью перечитать doc.
    @Published var stateRevision = 0

    @Published var baseImage: CGImage?
    @Published var exactImage: CGImage?
    @Published var playbackImage: CGImage?
    @Published var processingTitle: String?
    @Published var processingDetail: String?

    @Published var playing = false
    @Published var position: Double = 0
    @Published var currentFrame = 0

    @Published var statusText = ""
    @Published var statusIsError = false
    @Published var statusIsWarn = false
    @Published var statusIsOk = false

    @Published var busy = false
    @Published var inspector = InspectorMode.main
    @Published var cropSel = CGRect.zero          // координаты превью-кадра
    @Published var editingKey = KeySettings()     // активен при inspector == .key
    @Published var pickMode = false

    // MARK: - приватное

    private let exactRenderer = ExactPreviewRenderer()
    private let playbackRenderer = PlaybackPreviewRenderer()
    private let decodeQueue = DispatchQueue(label: "stickerstudio.frame-decode",
                                            qos: .userInteractive)

    private var exactRevision: Int64 = 0
    private var exactTimer: Timer?

    private var playbackCache: PlaybackCache?
    private var playbackCacheRevision: Int64 = 0
    private var playbackCacheBuilding = false
    private var playWhenCacheReady = false
    private var playbackRequestedFrame = -1
    private var cacheTimer: Timer?

    private var playTimer: Timer?
    private var playStart = Date()
    private var playOffset: Double = 0

    private var baseGeneration = 0
    private var showingResult = false
    private var shuttingDown = false

    // MARK: - init

    init(doc: VideoDocument, ffmpegPath: String) {
        self.doc = doc
        self.ffmpegPath = ffmpegPath
        position = doc.state.cutStart
        currentFrame = doc.frameIndex(at: doc.state.cutStart)

        exactRenderer.completed = { [weak self] revision, frame in
            let image = ImageConversion.cgImage(from: frame)
            DispatchQueue.main.async {
                self?.exactCompleted(revision: revision, image: image)
            }
        }
        playbackRenderer.completed = { [weak self] revision, cache in
            DispatchQueue.main.async {
                self?.playbackCacheCompleted(revision: revision, cache: cache)
            }
        }
        playbackRenderer.failed = { [weak self] revision, message in
            DispatchQueue.main.async {
                self?.playbackCacheFailed(revision: revision, message: message)
            }
        }

        updateStatusIdle()
        updateBaseFrame()
        scheduleExactPreview(afterMs: 1)
        schedulePlaybackCache(afterMs: 180)
    }

    func shutdown() {
        shuttingDown = true
        playTimer?.invalidate()
        exactTimer?.invalidate()
        cacheTimer?.invalidate()
        exactRenderer.shutdown()
        playbackRenderer.shutdown()
        playbackCache?.dispose()
        playbackCache = nil
    }

    // MARK: - производные

    var activeKey: KeySettings {
        inspector == .key ? editingKey : doc.state.key
    }

    var exportBlocked: Bool {
        doc.cropRequired && !doc.cropApplied
    }

    var canUndoNow: Bool {
        doc.canUndo && !busy
    }

    var keyToolAvailable: Bool { !doc.sourceHasAlpha }

    private func bumpState() {
        stateRevision += 1
    }

    // MARK: - статус

    private func updateStatusIdle() {
        guard !busy, !showingResult else { return }
        statusIsError = false
        statusIsOk = false
        if exportBlocked {
            statusIsWarn = true
            statusText = "Обрезка обязательна: исходник больше 512 px."
        } else {
            statusIsWarn = false
            statusText = "Готово к экспорту. Результат появится рядом с исходником."
        }
    }

    // MARK: - базовый кадр превью (с живым кием)

    func updateBaseFrame() {
        guard currentFrame >= 0, currentFrame < doc.frames.count else { return }
        baseGeneration += 1
        let generation = baseGeneration
        let data = doc.frames[currentFrame]
        let w = doc.previewWidth
        let h = doc.previewHeight
        let key = activeKey
        decodeQueue.async { [weak self] in
            var image: CGImage?
            if key.enabled {
                if var px = ImageConversion.decodeBGRA(data, width: w, height: h) {
                    ChromaKey.apply(toBGRA: &px, width: w, height: h,
                                    stride: w * 4, settings: key)
                    image = ImageConversion.cgImage(fromBGRA: px, width: w, height: h)
                }
            } else {
                image = ImageConversion.decode(data)
            }
            DispatchQueue.main.async {
                guard let self = self, generation == self.baseGeneration else { return }
                if let image = image { self.baseImage = image }
            }
        }
    }

    private func setFrame(_ index: Int) {
        let clamped = max(0, min(doc.frames.count - 1, index))
        if clamped != currentFrame {
            currentFrame = clamped
            updateBaseFrame()
        }
    }

    // MARK: - точный предпросмотр

    func scheduleExactPreview(afterMs delayMs: Int) {
        exactRevision += 1
        exactTimer?.invalidate()
        exactRenderer.cancelPending()
        exactImage = nil
        if busy || playing || inspector == .crop || pickMode { return }

        let revision = exactRevision
        exactTimer = Timer.scheduledTimer(withTimeInterval: Double(delayMs) / 1000.0,
                                          repeats: false) { [weak self] _ in
            guard let self = self, revision == self.exactRevision else { return }
            self.requestExactPreview()
        }
    }

    func cancelExactPreview(clear: Bool) {
        exactRevision += 1
        exactTimer?.invalidate()
        exactRenderer.cancelPending()
        if clear { exactImage = nil }
    }

    private func requestExactPreview() {
        guard !busy, !playing, inspector != .crop else { return }
        var request = ExactPreviewRequest()
        request.revision = exactRevision
        request.ffmpegPath = ffmpegPath
        request.sourcePath = doc.sourcePath
        request.info = doc.info
        request.time = doc.time(ofFrame: currentFrame)
        request.cropRect = doc.state.cropRect
        request.key = activeKey
        exactRenderer.request(request)
    }

    private func exactCompleted(revision: Int64, image: CGImage?) {
        guard !shuttingDown, revision == exactRevision, !busy, !playing,
              inspector != .crop, let image = image else { return }
        exactImage = image
    }

    /// После экспорта preview берётся уже из готового VP9 WebM: видимый кадр
    /// включает тот же alpha decode и те же codec-артефакты, что у Telegram.
    private func requestEncodedPreview(outputPath: String) {
        guard FileManager.default.fileExists(atPath: outputPath) else { return }
        exactRevision += 1
        exactTimer?.invalidate()
        exactRenderer.cancelPending()
        exactImage = nil

        let geometry = FrameGeometry.create(info: doc.info, cropRect: doc.state.cropRect)
        var outputInfo = ProbeInfo()
        outputInfo.ok = true
        outputInfo.width = geometry.outputSize.width
        outputInfo.height = geometry.outputSize.height
        outputInfo.duration = doc.cutDuration
        outputInfo.fps = doc.state.fps30 ? 30 : doc.info.fps
        outputInfo.hasAlpha = true

        let frameStep = outputInfo.fps > 0 ? 1.0 / outputInfo.fps : 0.04
        var time = max(0, position - doc.state.cutStart)
        time = min(time, max(0, outputInfo.duration - frameStep))

        var request = ExactPreviewRequest()
        request.revision = exactRevision
        request.ffmpegPath = ffmpegPath
        request.sourcePath = outputPath
        request.info = outputInfo
        request.time = time
        request.cropRect = .empty
        request.key = KeySettings()
        request.decodeVP9Alpha = true
        exactRenderer.request(request)
    }

    // MARK: - кэш чёткого воспроизведения

    func schedulePlaybackCache(afterMs delayMs: Int) {
        if playing { stopPlayback() }
        playbackCacheRevision += 1
        playbackCacheBuilding = false
        playWhenCacheReady = false
        playbackRequestedFrame = -1
        cacheTimer?.invalidate()
        playbackRenderer.cancelPending()
        playbackCache?.dispose()
        playbackCache = nil
        playbackImage = nil
        processingTitle = nil
        processingDetail = nil
        if busy || inspector == .crop { return }

        let revision = playbackCacheRevision
        cacheTimer = Timer.scheduledTimer(withTimeInterval: Double(delayMs) / 1000.0,
                                          repeats: false) { [weak self] _ in
            guard let self = self, revision == self.playbackCacheRevision else { return }
            self.requestPlaybackCache()
        }
    }

    private func requestPlaybackCache() {
        guard !busy, !playing, inspector != .crop, !playbackCacheBuilding else { return }
        var request = PlaybackPreviewRequest()
        request.revision = playbackCacheRevision
        request.ffmpegPath = ffmpegPath
        request.sourcePath = doc.sourcePath
        request.info = doc.info
        request.start = doc.state.cutStart
        request.end = doc.state.cutEnd
        request.fps = doc.previewFps > 0 ? min(30, doc.previewFps) : 30
        request.cropRect = doc.state.cropRect
        request.key = activeKey
        playbackCacheBuilding = true
        processingTitle = "Готовим чёткое воспроизведение"
        processingDetail = "Подготавливаем кадры 512 × 512"
        playbackRenderer.request(request)
    }

    private func playbackCacheCompleted(revision: Int64, cache: PlaybackCache) {
        guard !shuttingDown, revision == playbackCacheRevision, !busy,
              inspector != .crop else {
            cache.dispose()
            return
        }
        playbackCacheBuilding = false
        processingTitle = nil
        processingDetail = nil
        playbackCache?.dispose()
        playbackCache = cache
        playbackRequestedFrame = -1
        if playWhenCacheReady {
            playWhenCacheReady = false
            startPlayback()
        }
    }

    private func playbackCacheFailed(revision: Int64, message: String) {
        guard !shuttingDown, revision == playbackCacheRevision else { return }
        playbackCacheBuilding = false
        playWhenCacheReady = false
        processingTitle = nil
        processingDetail = nil
        statusIsError = true
        statusText = "Не удалось подготовить чёткое воспроизведение: " + message
    }

    // MARK: - воспроизведение

    func togglePlay() {
        guard !busy else { return }
        if playing {
            stopPlayback()
            return
        }
        if playWhenCacheReady {
            playWhenCacheReady = false
            return
        }
        if playbackCache == nil {
            playWhenCacheReady = true
            cancelExactPreview(clear: true)
            cacheTimer?.invalidate()
            requestPlaybackCache()
            statusIsError = false
            statusIsWarn = false
            statusIsOk = false
            statusText = "Готовлю чёткое воспроизведение 512 × 512…"
            return
        }
        startPlayback()
    }

    private func startPlayback() {
        guard let cache = playbackCache, !playing else { return }
        playing = true
        playbackRequestedFrame = -1
        cancelExactPreview(clear: true)
        playStart = Date()
        statusIsError = false
        statusIsWarn = false
        statusIsOk = false
        statusText = "Чёткое воспроизведение \(cache.width) × \(cache.height)"
        playTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                         repeats: true) { [weak self] _ in
            self?.playTick()
        }
        playTick()
    }

    func stopPlayback() {
        if playing {
            playOffset = currentPlayTime() - doc.state.cutStart
        }
        playing = false
        playTimer?.invalidate()
        playTimer = nil
        playbackRequestedFrame = -1
        playbackImage = nil
        updateStatusIdle()
        scheduleExactPreview(afterMs: 1)
    }

    private func currentPlayTime() -> Double {
        let len = max(0.05, doc.cutDuration)
        let t = (playOffset + Date().timeIntervalSince(playStart))
            .truncatingRemainder(dividingBy: len)
        return doc.state.cutStart + t
    }

    private func playTick() {
        guard playing else { return }
        let t = currentPlayTime()
        position = t
        setFrame(doc.frameIndex(at: t))
        if let cache = playbackCache {
            let index = cache.frameIndex(at: t)
            if index != playbackRequestedFrame {
                playbackRequestedFrame = index
                let revision = playbackCacheRevision
                decodeQueue.async { [weak self] in
                    guard let frame = cache.decodeFrame(index),
                          let image = ImageConversion.cgImage(from: frame) else { return }
                    DispatchQueue.main.async {
                        guard let self = self, self.playing,
                              revision == self.playbackCacheRevision,
                              index == self.playbackRequestedFrame else { return }
                        self.playbackImage = image
                    }
                }
            }
        }
    }

    // MARK: - таймлайн

    func seek(to t: Double) {
        if playing { togglePlay() }
        let clamped = max(0, min(doc.info.duration, t))
        position = clamped
        playOffset = max(0, min(doc.cutDuration, clamped - doc.state.cutStart))
        setFrame(doc.frameIndex(at: clamped))
        scheduleExactPreview(afterMs: 120)
    }

    func stepFrame(_ direction: Int) {
        guard !busy else { return }
        if playing { togglePlay() }
        let f = max(0, min(doc.frames.count - 1, currentFrame + direction))
        let t = doc.time(ofFrame: f)
        position = t
        playOffset = max(0, min(doc.cutDuration, t - doc.state.cutStart))
        setFrame(f)
        scheduleExactPreview(afterMs: 80)
    }

    /// Таймлайн двигает doc.state.cutStart/cutEnd напрямую во время драга;
    /// по окончании коммитим undo-снапшот, сделанный до драга.
    func cutChanged() {
        bumpState()
    }

    func cutCommitted(pre: EditState) {
        if playing { stopPlayback() }
        doc.pushUndoSnapshot(pre)
        showingResult = false
        position = max(doc.state.cutStart, min(doc.state.cutEnd, position))
        playOffset = max(0, min(doc.cutDuration, position - doc.state.cutStart))
        setFrame(doc.frameIndex(at: position))
        bumpState()
        updateStatusIdle()
        schedulePlaybackCache(afterMs: 220)
    }

    // MARK: - кроп

    func cropToPreview(_ orig: PixelRect) -> CGRect {
        guard !orig.isEmpty, doc.info.width > 0 else { return .zero }
        let k = Double(doc.previewWidth) / Double(doc.info.width)
        return CGRect(x: Double(orig.x) * k, y: Double(orig.y) * k,
                      width: Double(orig.width) * k, height: Double(orig.height) * k)
    }

    func previewToCrop(_ sel: CGRect) -> PixelRect {
        let k = Double(doc.info.width) / Double(doc.previewWidth)
        var size = Int((sel.width * k).rounded())
        var x = Int((sel.origin.x * k).rounded())
        var y = Int((sel.origin.y * k).rounded())
        size = min(size, min(doc.info.width, doc.info.height))
        x = max(0, min(doc.info.width - size, x))
        y = max(0, min(doc.info.height - size, y))
        return PixelRect(x: x, y: y, width: size, height: size)
    }

    func startCrop() {
        guard !busy else { return }
        if playing { togglePlay() }
        if inspector == .key { closeKeyPanel(applied: false) }

        if doc.cropApplied {
            cropSel = cropToPreview(doc.state.cropRect)
        } else {
            let s = CGFloat(min(doc.previewWidth, doc.previewHeight))
            cropSel = CGRect(x: (CGFloat(doc.previewWidth) - s) / 2,
                             y: (CGFloat(doc.previewHeight) - s) / 2,
                             width: s, height: s)
        }
        inspector = .crop
        cancelExactPreview(clear: true)
        schedulePlaybackCache(afterMs: 180)
    }

    func applyCrop() {
        doc.pushUndo()
        doc.state.cropRect = previewToCrop(cropSel)
        showingResult = false
        endCropMode()
    }

    func cancelCrop() {
        endCropMode()
    }

    private func endCropMode() {
        inspector = .main
        bumpState()
        updateStatusIdle()
        scheduleExactPreview(afterMs: 1)
        schedulePlaybackCache(afterMs: 180)
    }

    // MARK: - хромакей

    func openKeyPanel() {
        guard !busy, keyToolAvailable else { return }
        if inspector == .crop { cancelCrop() }

        var key = doc.state.key.enabled ? doc.state.key : KeySettings()
        key.enabled = true
        editingKey = key
        inspector = .key
        updateBaseFrame()
        scheduleExactPreview(afterMs: 120)
        schedulePlaybackCache(afterMs: 320)
    }

    func togglePick() {
        pickMode.toggle()
        if pickMode {
            cancelExactPreview(clear: true)
        } else {
            scheduleExactPreview(afterMs: 120)
        }
    }

    /// Пипетка: цвет берётся из НЕобработанного кадра превью.
    func pickColor(atPreviewPoint point: CGPoint) {
        guard currentFrame < doc.frames.count else { return }
        let w = doc.previewWidth
        let h = doc.previewHeight
        let x = max(0, min(w - 1, Int(point.x)))
        let y = max(0, min(h - 1, Int(point.y)))
        guard let px = ImageConversion.decodeBGRA(doc.frames[currentFrame],
                                                  width: w, height: h) else { return }
        let i = (y * w + x) * 4
        let color = RGBColor(r: px[i + 2], g: px[i + 1], b: px[i])
        pickMode = false
        editingKey.screenColor = color
        keyParamChanged()
    }

    func keyParamChanged() {
        guard inspector == .key else { return }
        updateBaseFrame()
        scheduleExactPreview(afterMs: 160)
        schedulePlaybackCache(afterMs: 360)
    }

    func applyKey() {
        doc.pushUndo()
        doc.state.key = editingKey
        showingResult = false
        closeKeyPanel(applied: true)
    }

    func cancelKey() {
        closeKeyPanel(applied: false)
    }

    func closeKeyPanel(applied: Bool) {
        inspector = .main
        pickMode = false
        bumpState()
        updateStatusIdle()
        updateBaseFrame()
        scheduleExactPreview(afterMs: 1)
        schedulePlaybackCache(afterMs: 180)
    }

    // MARK: - undo

    func doUndo() {
        guard canUndoNow else { return }
        if playing { stopPlayback() }
        if inspector == .crop { cancelCrop() }
        if inspector == .key { closeKeyPanel(applied: false) }
        doc.undo()
        showingResult = false
        position = max(doc.state.cutStart, min(doc.state.cutEnd, position))
        playOffset = max(0, min(doc.cutDuration, position - doc.state.cutStart))
        setFrame(doc.frameIndex(at: position))
        bumpState()
        updateBaseFrame()
        updateStatusIdle()
        scheduleExactPreview(afterMs: 1)
        schedulePlaybackCache(afterMs: 180)
    }

    // MARK: - экспорт

    func doExport() {
        guard !busy else { return }
        if exportBlocked {
            let alert = NSAlert()
            alert.messageText = "Сначала обрезка"
            alert.informativeText = "Видео больше 512 px, поэтому нужно выбрать " +
                "квадратную зону стикера.\nНажмите «Обрезать», выделите зону и примените обрезку."
            alert.runModal()
            return
        }
        if playing { togglePlay() }
        cancelExactPreview(clear: false)
        cacheTimer?.invalidate()
        playbackRenderer.cancelPending()
        playbackCacheBuilding = false
        playWhenCacheReady = false
        processingTitle = nil
        processingDetail = nil

        var snapshot = doc.state

        // fps выше лимита Telegram — спрашиваем один раз на экспорте.
        // «Нет» — на нет и суда нет: оставляем частоту исходника как есть.
        if doc.info.fps > 31 {
            let alert = NSAlert()
            alert.messageText = "FPS выше 30"
            alert.informativeText = "У видео \(FFmpeg.inv(doc.info.fps)) fps, это выше " +
                "лимита Telegram (30).\nTelegram может отклонить такой стикер.\n\n" +
                "Пересчитать видео в 30 fps?"
            alert.addButton(withTitle: "Да, в 30 fps")
            alert.addButton(withTitle: "Оставить как есть")
            snapshot.fps30 = alert.runModal() == .alertFirstButtonReturn
        }

        let panel = NSSavePanel()
        panel.title = "Экспорт WebM"
        panel.nameFieldStringValue = URL(fileURLWithPath:
            ExportPipeline.defaultOutputPath(forSource: doc.sourcePath)).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: doc.sourcePath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        busy = true
        showingResult = false
        statusIsError = false
        statusIsWarn = false
        statusIsOk = false
        statusText = "Собираю WebM и подгоняю размер…"

        let ffmpeg = ffmpegPath
        let src = doc.sourcePath
        let info = doc.info
        let srcAlpha = doc.sourceHasAlpha
        let outPath = outURL.path

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ExportPipeline.run(ffmpeg: ffmpeg, sourcePath: src, info: info,
                                            sourceHasAlpha: srcAlpha, state: snapshot,
                                            outputPath: outPath) { message in
                DispatchQueue.main.async { self?.statusText = message }
            }
            DispatchQueue.main.async { self?.exportDone(result) }
        }
    }

    private func exportDone(_ r: ExportResult) {
        busy = false
        showingResult = true
        if !r.ok {
            statusIsError = true
            statusText = "✗ " + (r.error ?? "Неизвестная ошибка")
            return
        }
        let outputPath = r.outputPath ?? ""
        let name = (outputPath as NSString).lastPathComponent
        let kb = String(Int((Double(r.size) / 1024.0).rounded())) + " КБ"
        statusIsError = false
        statusIsWarn = r.fpsWarning
        statusIsOk = !r.fpsWarning
        statusText = (r.fpsWarning ? "⚠ " : "✓ ") + "Готово → " + name + " (" + kb +
            (r.alphaInOutput ? ", с альфой" : ", без альфы") + ")" +
            (r.fpsWarning ? ". Частота выше 30 fps, Telegram может отклонить файл" : "")

        requestEncodedPreview(outputPath: outputPath)

        let alert = NSAlert()
        alert.messageText = "Экспорт завершён"
        alert.informativeText = "Стикер готов: \(name) (\(kb))\n\nПоказать в Finder?"
        alert.addButton(withTitle: "Показать в Finder")
        alert.addButton(withTitle: "Закрыть")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: outputPath)])
        }
    }

    // MARK: - клавиатура

    /// true = событие обработано. Порт EditorView.HandleKey.
    func handleKey(_ event: NSEvent) -> Bool {
        guard !busy else { return false }
        let cmd = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if cmd && chars == "o" { onBack(); return true }
        if cmd && chars == "e" { doExport(); return true }
        if cmd && chars == "z" { doUndo(); return true }
        if event.keyCode == 53 { // Esc
            if inspector == .crop { cancelCrop(); return true }
            if inspector == .key { closeKeyPanel(applied: false); return true }
            if playing { togglePlay(); return true }
            return false
        }
        if event.keyCode == 49 { // Space: в медиаредакторе пробел всегда play/pause
            togglePlay()
            return true
        }
        if chars == "c" && !cmd { startCrop(); return true }
        if chars == "b" && !cmd && keyToolAvailable { openKeyPanel(); return true }
        if event.keyCode == 123 { stepFrame(-1); return true } // ←
        if event.keyCode == 124 { stepFrame(1); return true }  // →
        return false
    }
}
#endif
