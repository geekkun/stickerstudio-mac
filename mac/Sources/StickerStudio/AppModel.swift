#if os(macOS)
import AppKit
import Combine
import Foundation
import StickerCore
import UniformTypeIdentifiers

/// Верхнеуровневое состояние приложения: лендинг → загрузка → редактор.
final class AppModel: ObservableObject {
    enum Screen {
        case landing
        case loading
        case editor
    }

    @Published var screen = Screen.landing
    @Published var loadPercent = 0
    @Published var loadText = ""
    @Published var errorMessage: String?
    @Published private(set) var editor: EditorModel?

    let ffmpegPath: String?

    static let allowedExtensions = ["mov", "webm", "mp4", "m4v"]

    init() {
        ffmpegPath = FFmpeg.find()
    }

    var ffmpegMissing: Bool { ffmpegPath == nil }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Выбрать видео"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AppModel.allowedExtensions
            .compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func canAccept(url: URL) -> Bool {
        AppModel.allowedExtensions.contains(url.pathExtension.lowercased())
    }

    func load(url: URL) {
        guard screen != .loading else { return }
        guard let ffmpeg = ffmpegPath else {
            errorMessage = "ffmpeg не найден. Установите его: brew install ffmpeg " +
                "(или положите бинарник ffmpeg рядом с приложением)."
            return
        }
        guard canAccept(url: url) else {
            errorMessage = "Поддерживаются MOV, WebM и MP4."
            return
        }

        // Закрываем предыдущий редактор до загрузки нового файла.
        editor?.shutdown()
        editor = nil

        errorMessage = nil
        screen = .loading
        loadPercent = 0
        loadText = "Открываю видео…"

        let doc = VideoDocument()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = doc.load(ffmpeg: ffmpeg, path: url.path) { percent, text in
                DispatchQueue.main.async {
                    self?.loadPercent = percent
                    self?.loadText = text
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.errorMessage = error
                    self.screen = .landing
                    return
                }
                let editor = EditorModel(doc: doc, ffmpegPath: ffmpeg)
                editor.onBack = { [weak self] in self?.backToLanding() }
                self.editor = editor
                self.screen = .editor
            }
        }
    }

    func backToLanding() {
        editor?.shutdown()
        editor = nil
        screen = .landing
    }
}
#endif
