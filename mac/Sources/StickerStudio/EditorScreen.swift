#if os(macOS)
import SwiftUI
import StickerCore

struct EditorScreen: View {
    @ObservedObject var model: EditorModel
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                toolRail
                stage
                InspectorPanel(model: model)
                    .frame(width: 312)
                    .background(Theme.backPanel)
            }
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - верхняя панель

    private var toolbar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text((model.doc.sourcePath as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textMain)
                    .lineLimit(1)
                Text(sourceMeta)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Button {
                model.onBack()
            } label: {
                Label("Новое видео", systemImage: "folder")
            }
            .buttonStyle(StudioButtonStyle(ghost: true, compact: true))
            .help("Открыть другое видео (⌘O)")
            .disabled(model.busy)

            Button {
                model.doUndo()
            } label: {
                Label("Отменить", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(StudioButtonStyle(compact: true))
            .help("Откатить последнее действие (⌘Z)")
            .disabled(!model.canUndoNow)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.backHeader)
    }

    private var sourceMeta: String {
        let info = model.doc.info
        let fps = info.fps > 0 ? FFmpeg.inv(info.fps) + " fps" : "fps: нет данных"
        return "\(info.width) × \(info.height)  /  " +
            String(format: "%.1f с", info.duration) + "  /  " + fps
    }

    // MARK: - рельса инструментов

    private var toolRail: some View {
        VStack(spacing: 10) {
            railButton(title: "Обрезать", system: "crop",
                       active: model.doc.cropApplied || model.inspector == .crop,
                       help: "Выбрать квадратную зону стикера 512 × 512 (C)") {
                model.startCrop()
            }
            if model.keyToolAvailable {
                railButton(title: "Убрать фон", system: "wand.and.stars",
                           active: model.doc.state.key.enabled || model.inspector == .key,
                           help: "Убрать однотонный фон (B)") {
                    model.openKeyPanel()
                }
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .frame(width: 86)
        .background(Theme.backPanel)
    }

    private func railButton(title: String, system: String, active: Bool,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: system)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(active ? Theme.accent : Theme.textSoft)
            .frame(width: 72, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Theme.accentSoft.opacity(0.55) : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(model.busy)
    }

    // MARK: - сцена

    private var stage: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.stage
                PreviewView(model: model)
                    .padding(18)
            }
            transport
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .help("Воспроизведение / пауза (Пробел). Без звука.")
            .disabled(model.busy)

            VStack(alignment: .leading, spacing: 6) {
                TimelineView(model: model)
                    .frame(height: 56)
                Text(timeLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.backFooter)
    }

    private var timeLabel: String {
        let s = model.doc.state
        return String(format: "%.1f с   /   %.1f-%.1f   /   %.1f с",
                      model.position, s.cutStart, s.cutEnd, s.cutEnd - s.cutStart)
    }

    // MARK: - клавиатура

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if model.handleKey(event) { return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
#endif
