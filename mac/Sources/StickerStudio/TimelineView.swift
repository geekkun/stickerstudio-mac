#if os(macOS)
import SwiftUI
import StickerCore

/// Таймлайн-филмстрип: миниатюры на всю длительность, окно отрезка
/// (0,5–6 с) с ручками по краям и каретка позиции. Порт TimelineControl.
struct TimelineView: View {
    @ObservedObject var model: EditorModel

    private enum DragKind {
        case none, seek, moveWindow, startHandle, endHandle
    }
    @State private var drag = DragKind.none
    @State private var dragPre = EditState()
    @State private var dragStartCut: (Double, Double) = (0, 0)
    @State private var thumbnails: [Int: CGImage] = [:]
    @State private var thumbnailsWidth: CGFloat = 0

    private let handleWidth: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(0.01, model.doc.info.duration)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surface)

                filmstrip(width: width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // затемнение вне окна отрезка
                let x0 = xOf(model.doc.state.cutStart, width: width, duration: duration)
                let x1 = xOf(model.doc.state.cutEnd, width: width, duration: duration)
                Rectangle()
                    .fill(Color.black.opacity(0.62))
                    .frame(width: max(0, x0))
                Rectangle()
                    .fill(Color.black.opacity(0.62))
                    .frame(width: max(0, width - x1))
                    .offset(x: x1)

                // рамка окна + ручки
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .frame(width: max(4, x1 - x0), height: geo.size.height)
                    .offset(x: x0)
                handle(at: x0 - handleWidth / 2, height: geo.size.height)
                handle(at: x1 - handleWidth / 2, height: geo.size.height)

                // каретка позиции
                let xp = xOf(model.position, width: width, duration: duration)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: geo.size.height + 6)
                    .offset(x: xp - 1, y: -3)
            }
            .contentShape(Rectangle())
            .gesture(timelineGesture(width: width, duration: duration))
            .onAppear { buildThumbnails(width: width) }
            .onChange(of: width) { newWidth in
                buildThumbnails(width: newWidth)
            }
        }
    }

    // MARK: - миниатюры

    private func filmstrip(width: CGFloat, height: CGFloat) -> some View {
        let doc = model.doc
        let aspect = CGFloat(max(1, doc.previewWidth)) / CGFloat(max(1, doc.previewHeight))
        let thumbW = max(24, height * aspect)
        let count = max(1, Int(ceil(width / thumbW)))
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { slot in
                Group {
                    if let image = thumbnails[slot] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Theme.surfaceSoft
                    }
                }
                .frame(width: thumbW, height: height)
                .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
    }

    private func buildThumbnails(width: CGFloat) {
        guard width > 0, abs(width - thumbnailsWidth) > 1 else { return }
        thumbnailsWidth = width
        let doc = model.doc
        let aspect = CGFloat(max(1, doc.previewWidth)) / CGFloat(max(1, doc.previewHeight))
        let thumbW = max(24, 56 * aspect)
        let count = max(1, Int(ceil(width / thumbW)))
        let duration = doc.info.duration
        let frames = doc.frames

        DispatchQueue.global(qos: .utility).async {
            var result: [Int: CGImage] = [:]
            for slot in 0..<count {
                let t = duration * (Double(slot) + 0.5) / Double(count)
                let index = doc.frameIndex(at: t)
                guard index < frames.count else { continue }
                if let image = ImageConversion.decode(frames[index]) {
                    result[slot] = image
                }
            }
            DispatchQueue.main.async {
                thumbnails = result
            }
        }
    }

    // MARK: - геометрия

    private func xOf(_ t: Double, width: CGFloat, duration: Double) -> CGFloat {
        CGFloat(t / duration) * width
    }

    private func timeOf(_ x: CGFloat, width: CGFloat, duration: Double) -> Double {
        max(0, min(duration, Double(x / max(1, width)) * duration))
    }

    private func handle(at x: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.accent)
            .frame(width: handleWidth, height: height * 0.72)
            .overlay(
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: height * 0.34))
            .offset(x: x, y: height * 0.14)
    }

    // MARK: - жесты

    private func timelineGesture(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if case .none = drag {
                    beginDrag(at: value.startLocation.x, width: width, duration: duration)
                }
                continueDrag(value, width: width, duration: duration)
            }
            .onEnded { _ in
                switch drag {
                case .moveWindow, .startHandle, .endHandle:
                    model.cutCommitted(pre: dragPre)
                default:
                    break
                }
                drag = .none
            }
    }

    private func beginDrag(at x: CGFloat, width: CGFloat, duration: Double) {
        let state = model.doc.state
        let x0 = xOf(state.cutStart, width: width, duration: duration)
        let x1 = xOf(state.cutEnd, width: width, duration: duration)
        dragPre = state
        dragStartCut = (state.cutStart, state.cutEnd)
        // увеличенная зона захвата ручек
        if abs(x - x0) <= handleWidth + 4 {
            drag = .startHandle
        } else if abs(x - x1) <= handleWidth + 4 {
            drag = .endHandle
        } else if x > x0 && x < x1 {
            let xp = xOf(model.position, width: width, duration: duration)
            // рядом с кареткой — скраб, иначе двигаем окно
            drag = abs(x - xp) <= 7 ? .seek : .moveWindow
        } else {
            drag = .seek
        }
    }

    private func continueDrag(_ value: DragGesture.Value, width: CGFloat, duration: Double) {
        let dt = Double((value.location.x - value.startLocation.x) / max(1, width)) * duration
        switch drag {
        case .none:
            break
        case .seek:
            model.seek(to: timeOf(value.location.x, width: width, duration: duration))
        case .moveWindow:
            let len = dragStartCut.1 - dragStartCut.0
            var start = dragStartCut.0 + dt
            start = max(0, min(duration - len, start))
            model.doc.state.cutStart = start
            model.doc.state.cutEnd = start + len
            model.cutChanged()
        case .startHandle:
            var start = dragStartCut.0 + dt
            let maxStart = dragStartCut.1 - VideoLimits.minCutSeconds
            let minStart = max(0, dragStartCut.1 - VideoLimits.maxCutSeconds)
            start = max(minStart, min(maxStart, start))
            model.doc.state.cutStart = start
            model.cutChanged()
        case .endHandle:
            var end = dragStartCut.1 + dt
            let minEnd = dragStartCut.0 + VideoLimits.minCutSeconds
            let maxEnd = min(duration, dragStartCut.0 + VideoLimits.maxCutSeconds)
            end = max(minEnd, min(maxEnd, end))
            model.doc.state.cutEnd = end
            model.cutChanged()
        }
    }
}
#endif
