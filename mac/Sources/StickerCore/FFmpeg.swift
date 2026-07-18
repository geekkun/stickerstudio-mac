import Foundation

public struct ProbeInfo: Sendable {
    public var ok = false
    public var error: String?
    public var duration: Double = 0
    public var width = 0
    public var height = 0
    public var fps: Double = 0
    public var hasAlpha = false

    public init() {}
}

/// Обёртка над бинарником ffmpeg: поиск, запуск, probe.
/// Аргументы передаются массивом (без shell), поэтому пути с пробелами и
/// кавычками не требуют экранирования.
public enum FFmpeg {
    /// 256 КБ — лимит Telegram.
    public static let sizeLimit: Int64 = 262_144
    public static let sizeTarget: Int64 = 250 * 1024

    /// Текущий запущенный процесс — для отмены экспорта.
    private static let currentLock = NSLock()
    private static var _current: Process?

    public static var current: Process? {
        get { currentLock.lock(); defer { currentLock.unlock() }; return _current }
        set { currentLock.lock(); _current = newValue; currentLock.unlock() }
    }

    /// Поиск ffmpeg: рядом с бандлом/бинарником, потом Homebrew, потом PATH.
    public static func find() -> String? {
        var candidates: [String] = []

        #if os(macOS)
        // Внутри .app: Contents/Resources/ffmpeg (кладётся скриптом сборки).
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("ffmpeg").path)
        }
        #endif

        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("ffmpeg").path)

        candidates.append("/opt/homebrew/bin/ffmpeg")
        candidates.append("/usr/local/bin/ffmpeg")
        candidates.append("/usr/bin/ffmpeg")

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let trimmed = dir.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            candidates.append((trimmed as NSString).appendingPathComponent("ffmpeg"))
        }

        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    /// Запуск ffmpeg с ожиданием завершения. Возвращает stderr (там ffmpeg
    /// пишет и ошибки, и прогресс) и код выхода.
    @discardableResult
    public static func run(_ ffmpegPath: String, _ arguments: [String],
                           exitCode: inout Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments

        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        do {
            try process.run()
        } catch {
            exitCode = -1
            return error.localizedDescription
        }
        current = process

        // stdout читаем и выбрасываем, чтобы ffmpeg не встал на полном пайпе.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        current = nil

        exitCode = process.terminationStatus
        return String(data: errData, encoding: .utf8) ?? ""
    }

    public static func cancelCurrent() {
        current?.terminate()
    }

    /// Probe через `ffmpeg -hide_banner -i <input>` (ffmpeg выходит с ошибкой
    /// "no output", но лог содержит всё нужное).
    public static func probe(_ ffmpegPath: String, input: String) -> ProbeInfo {
        var code: Int32 = 0
        let log = run(ffmpegPath, ["-hide_banner", "-i", input], exitCode: &code)
        return parseProbeLog(log)
    }

    /// Чистый парсер лога `ffmpeg -i` — вынесен отдельно ради юнит-тестов.
    public static func parseProbeLog(_ log: String) -> ProbeInfo {
        var info = ProbeInfo()

        guard let md = firstMatch(#"Duration:\s+(\d+):(\d+):(\d+(?:\.\d+)?)"#, in: log) else {
            info.error = "не удалось определить длительность (файл повреждён?)"
            return info
        }
        info.duration = (Double(md[1]) ?? 0) * 3600
            + (Double(md[2]) ?? 0) * 60
            + (Double(md[3]) ?? 0)

        guard let mv = firstMatch(#"Stream #\d+:\d+.*?: Video: (.+)"#, in: log) else {
            info.error = "видеопоток не найден"
            return info
        }
        let vline = mv[1]

        guard let mdim = firstMatch(#"[, ](\d{2,5})x(\d{2,5})[ ,\[]"#, in: vline) else {
            info.error = "не удалось определить разрешение"
            return info
        }
        info.width = Int(mdim[1]) ?? 0
        info.height = Int(mdim[2]) ?? 0

        if let mfps = firstMatch(#"(\d+(?:\.\d+)?)\s*fps"#, in: vline) {
            info.fps = Double(mfps[1]) ?? 0
        }

        let alphaFormats = ["yuva", "rgba", "argb", "bgra", "abgr", "gbrap", "ya8", "ya16"]
        info.hasAlpha = alphaFormats.contains { vline.contains($0) }

        if info.duration <= 0.05 {
            info.error = "нулевая длительность"
            return info
        }
        info.ok = true
        return info
    }

    public static func lastLine(_ s: String?) -> String {
        guard let s = s, !s.isEmpty else { return "ffmpeg завершился с ошибкой" }
        let lines = s.replacingOccurrences(of: "\r", with: "").split(separator: "\n")
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return "ffmpeg завершился с ошибкой"
    }

    /// Инвариантное форматирование секунд/чисел для аргументов ffmpeg
    /// (аналог C# "0.###": до 3 знаков, без хвостовых нулей).
    public static func inv(_ v: Double) -> String {
        var s = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: - regex helper

    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
