#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct LandingView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropHover = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 24)
            hero
            Spacer(minLength: 16)
            dropZone
                .frame(maxWidth: 620)
                .padding(.horizontal, 40)
            Text("Файл остаётся на этом компьютере")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 14)
            if model.ffmpegMissing {
                ffmpegWarning
                    .padding(.top, 18)
            }
            Spacer(minLength: 36)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sticker Studio")
                    .font(.system(size: 19, weight: .semibold, design: .default))
                    .foregroundStyle(Theme.textMain)
                Text("uxlive  /  видеостикеры Telegram")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Text("Telegram WebM   /   обработка локально")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSoft)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(Theme.backHeader)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Text("Видеостикер из любого ролика")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.textMain)
            Text("Обрезка 1:1, точный фрагмент до 6 секунд, удаление однотонного фона\nи готовый VP9 WebM 512 × 512 в лимит 256 КБ — без Adobe и облака.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSoft)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .padding(.horizontal, 40)
    }

    private var dropZone: some View {
        Button {
            model.pickFile()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(dropHover ? Theme.accent : Theme.textMuted)
                Text("Перетащите видео сюда или нажмите, чтобы выбрать")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textMain)
                Text("MOV, WebM с альфа-каналом или MP4  ·  до 180 секунд")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(dropHover ? Theme.surfaceRaised : Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(dropHover ? Theme.accent : Theme.borderIdle,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async {
                    model.load(url: url)
                }
            }
            return true
        }
    }

    private var ffmpegWarning: some View {
        VStack(spacing: 6) {
            Text("ffmpeg не найден")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.warn)
            Text("Установите его командой  brew install ffmpeg  — или положите бинарник ffmpeg рядом с приложением.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accentSoft.opacity(0.4)))
    }
}
#endif
