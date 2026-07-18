#if os(macOS)
import SwiftUI
import StickerCore

/// Правая колонка: инспектор готовности / панель кропа / панель кия.
struct InspectorPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            Divider().overlay(Theme.borderIdle)
            switch model.inspector {
            case .main:
                mainPanel
            case .crop:
                cropPanel
            case .key:
                keyPanel
            }
        }
        .padding(.bottom, 16)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textMain)
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var title: String {
        switch model.inspector {
        case .main: return "Готовность"
        case .crop: return "Обрезка 1:1"
        case .key: return "Удаление фона"
        }
    }

    private var caption: String {
        switch model.inspector {
        case .main: return "Проверка перед экспортом"
        case .crop: return "Композиция будущего стикера"
        case .key: return "Живой предпросмотр маски"
        }
    }

    // MARK: - главный инспектор

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            let blocked = model.exportBlocked

            statusRow(title: "Статус",
                      value: blocked ? "нужна обрезка" : "можно экспортировать",
                      system: blocked ? "lock" : "checkmark.circle",
                      color: blocked ? Theme.warn : Theme.ok)

            statusRow(title: "Квадрат 1:1",
                      value: model.doc.cropApplied ? "выбран"
                          : (blocked ? "обязателен" : "не требуется"),
                      system: "crop",
                      color: model.doc.cropApplied ? Theme.ok
                          : (blocked ? Theme.warn : Theme.textMuted))

            if model.doc.sourceHasAlpha {
                statusRow(title: "Альфа-канал", value: "сохранится",
                          system: "checkmark.circle", color: Theme.ok)
            } else {
                let removed = model.doc.state.key.enabled
                statusRow(title: "Фон",
                          value: removed ? "удалён" : "без обработки",
                          system: removed ? "checkmark.circle" : "wand.and.stars",
                          color: removed ? Theme.ok : Theme.textMuted)
            }

            statusRow(title: "Холст",
                      value: model.doc.cropApplied ? "512 × 512"
                          : "\(model.doc.info.width) × \(model.doc.info.height)",
                      system: "square.dashed", color: Theme.textMuted)

            VStack(alignment: .leading, spacing: 4) {
                Text(blocked ? "Остался один шаг" : "Все проверки пройдены")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textMain)
                Text(blocked ? "Выберите квадрат 1:1 для стикера."
                     : "WebM будет собран под лимит 256 КБ.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 6)

            Spacer()

            Text(model.statusText)
                .font(.system(size: 11.5))
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.doExport()
            } label: {
                Label(exportTitle,
                      systemImage: model.exportBlocked ? "lock" : "square.and.arrow.up")
            }
            .buttonStyle(StudioButtonStyle(accent: !model.exportBlocked && !model.busy))
            .disabled(model.busy)
            .help(model.exportBlocked
                  ? "Видео больше 512 px. Сначала выберите квадратную область."
                  : "Экспортировать WebM до 256 КБ (⌘E)")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var exportTitle: String {
        if model.busy { return "Экспортирую…" }
        if model.exportBlocked { return "Сначала обрезать кадр" }
        return "Экспортировать WebM"
    }

    private var statusColor: Color {
        if model.statusIsError { return Theme.err }
        if model.statusIsWarn { return Theme.warn }
        if model.statusIsOk { return Theme.ok }
        return Theme.textMuted
    }

    private func statusRow(title: String, value: String, system: String,
                           color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSoft)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface))
    }

    // MARK: - панель кропа

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Перетащите рамку и углы, чтобы выбрать квадрат 512 × 512.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button {
                model.applyCrop()
            } label: {
                Label("Применить обрезку", systemImage: "checkmark")
            }
            .buttonStyle(StudioButtonStyle(accent: true))

            Button {
                model.cancelCrop()
            } label: {
                Label("Отмена", systemImage: "xmark")
            }
            .buttonStyle(StudioButtonStyle(ghost: true))
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: - панель кия

    private var keyPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Кликните пипеткой по цвету фона на видео, затем подстройте маску.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.togglePick()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eyedropper")
                    Text("Выбрать цвет на видео")
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(swatchColor)
                        .frame(width: 18, height: 18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Theme.borderIdle, lineWidth: 1))
                }
            }
            .buttonStyle(StudioButtonStyle(accent: model.pickMode,
                                           ghost: !model.pickMode))
            .help("Кликните по цвету фона на видео")

            VStack(alignment: .leading, spacing: 4) {
                Text("Сила удаления: \(model.editingKey.gain)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSoft)
                Slider(value: gainBinding, in: 0...200, step: 1)
                    .tint(Theme.accent)
                    .help("Сила вырезания фона")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Край маски: " +
                     (model.editingKey.shrinkGrow > 0 ? "+" : "") +
                     "\(model.editingKey.shrinkGrow)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSoft)
                Slider(value: shrinkBinding, in: -100...100, step: 1)
                    .tint(Theme.accent)
                    .help("Поджать (−) или расширить (+) края маски")
            }

            Spacer()

            Button {
                model.applyKey()
            } label: {
                Label("Применить фон", systemImage: "checkmark")
            }
            .buttonStyle(StudioButtonStyle(accent: true))

            Button {
                model.cancelKey()
            } label: {
                Label("Отмена", systemImage: "xmark")
            }
            .buttonStyle(StudioButtonStyle(ghost: true))
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var swatchColor: Color {
        let c = model.editingKey.screenColor
        return Color(.sRGB,
                     red: Double(c.r) / 255.0,
                     green: Double(c.g) / 255.0,
                     blue: Double(c.b) / 255.0,
                     opacity: 1)
    }

    private var gainBinding: Binding<Double> {
        Binding(get: { Double(model.editingKey.gain) },
                set: { value in
                    let v = Int(value.rounded())
                    if v != model.editingKey.gain {
                        model.editingKey.gain = v
                        model.keyParamChanged()
                    }
                })
    }

    private var shrinkBinding: Binding<Double> {
        Binding(get: { Double(model.editingKey.shrinkGrow) },
                set: { value in
                    let v = Int(value.rounded())
                    if v != model.editingKey.shrinkGrow {
                        model.editingKey.shrinkGrow = v
                        model.keyParamChanged()
                    }
                })
    }
}
#endif
