import Foundation

/// Диагностический лог в stderr — виден при запуске из терминала
/// (`swift run StickerStudio`) и в Console.app. Выключается через
/// STICKERSTUDIO_QUIET=1.
public enum SSLog {
    private static let enabled: Bool = {
        ProcessInfo.processInfo.environment["STICKERSTUDIO_QUIET"] != "1"
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func log(_ message: String) {
        guard enabled else { return }
        let line = "[sticker \(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
