#if os(macOS)
import SwiftUI
import StickerCore

/// Сцена предпросмотра: шахматка, кадр (базовый / точный 512 / playback),
/// оверлей кропа и пипетка. Порт PreviewControl из EditorUI.cs.
struct PreviewView: View {
    @ObservedObject var model: EditorModel

    private enum CropDragKind {
        case none, move
        case corner(dx: CGFloat, dy: CGFloat) // -1/+1 — какой угол тянем
    }
    @State private var cropDrag = CropDragKind.none
    @State private var cropDragStartSel = CGRect.zero

    var body: some View {
        GeometryReader { geo in
            let display = displayImage
            let videoRect = fitRect(imageSize: displaySize(display), in: geo.size)

            ZStack {
                CheckerboardBackground()
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)

                if let image = display {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: videoRect.width, height: videoRect.height)
                        .position(x: videoRect.midX, y: videoRect.midY)
                }

                // затемнение вне применённого кропа (когда кроп-режим выключен
                // и показывается полный кадр, а не точный 512-кадр)
                if model.inspector != .crop, model.exactImage == nil,
                   model.playbackImage == nil, model.doc.cropApplied {
                    appliedCropDim(videoRect: videoRect)
                }

                if model.inspector == .crop {
                    cropOverlay(videoRect: videoRect)
                }

                if let title = model.processingTitle {
                    processingBadge(title: title, detail: model.processingDetail)
                        .position(x: geo.size.width / 2, y: 34)
                }
            }
            .contentShape(Rectangle())
            .gesture(stageGesture(videoRect: videoRect))
        }
    }

    /// Единый жест сцены: в кроп-режиме — перетаскивание рамки,
    /// в режиме пипетки — клик по цвету.
    private func stageGesture(videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.inspector == .crop else { return }
                handleCropDragChanged(value, videoRect: videoRect)
            }
            .onEnded { value in
                if model.inspector == .crop {
                    cropDrag = .none
                } else if model.pickMode {
                    let p = viewToPreview(value.location, videoRect: videoRect)
                    model.pickColor(atPreviewPoint: p)
                }
            }
    }

    // MARK: - выбор картинки

    /// Во время воспроизведения — кадр кэша; на паузе — точный кадр,
    /// пока он не готов — базовый кадр превью.
    private var displayImage: CGImage? {
        if model.playing, let playback = model.playbackImage { return playback }
        if model.inspector != .crop, let exact = model.exactImage { return exact }
        return model.baseImage
    }

    private func displaySize(_ image: CGImage?) -> CGSize {
        if let image = image, model.inspector != .crop,
           image !== model.baseImage {
            return CGSize(width: image.width, height: image.height)
        }
        // Базовый кадр показываем в системе координат превью.
        return CGSize(width: model.doc.previewWidth, height: model.doc.previewHeight)
    }

    private func fitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 8, container.height > 8 else { return .zero }
        let scale = min(container.width / imageSize.width,
                        container.height / imageSize.height, 2.5)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }

    private func viewToPreview(_ point: CGPoint, videoRect: CGRect) -> CGPoint {
        guard videoRect.width > 0 else { return .zero }
        let kx = CGFloat(model.doc.previewWidth) / videoRect.width
        let ky = CGFloat(model.doc.previewHeight) / videoRect.height
        return CGPoint(x: (point.x - videoRect.minX) * kx,
                       y: (point.y - videoRect.minY) * ky)
    }

    // MARK: - применённый кроп

    private func appliedCropDim(videoRect: CGRect) -> some View {
        let sel = model.cropToPreview(model.doc.state.cropRect)
        let scale = videoRect.width / CGFloat(max(1, model.doc.previewWidth))
        let rect = CGRect(x: videoRect.minX + sel.minX * scale,
                          y: videoRect.minY + sel.minY * scale,
                          width: sel.width * scale,
                          height: sel.height * scale)
        return ZStack {
            Path { path in
                path.addRect(videoRect)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(Theme.textMuted.opacity(0.7), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    // MARK: - кроп-режим

    private func cropOverlay(videoRect: CGRect) -> some View {
        let scale = videoRect.width / CGFloat(max(1, model.doc.previewWidth))
        let sel = model.cropSel
        let rect = CGRect(x: videoRect.minX + sel.minX * scale,
                          y: videoRect.minY + sel.minY * scale,
                          width: sel.width * scale,
                          height: sel.height * scale)
        return ZStack {
            Path { path in
                path.addRect(videoRect)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))

            Rectangle()
                .strokeBorder(Theme.accent, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // сетка третей
            Path { path in
                for i in 1...2 {
                    let t = CGFloat(i) / 3
                    path.move(to: CGPoint(x: rect.minX + rect.width * t, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX + rect.width * t, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * t))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * t))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 1)

            ForEach(0..<4, id: \.self) { i in
                let (dx, dy) = Self.cornerOffsets[i]
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 11, height: 11)
                    .position(x: rect.midX + dx * rect.width / 2,
                              y: rect.midY + dy * rect.height / 2)
            }
        }
    }

    private static let cornerOffsets: [(CGFloat, CGFloat)] =
        [(-1, -1), (1, -1), (-1, 1), (1, 1)]

    private func handleCropDragChanged(_ value: DragGesture.Value, videoRect: CGRect) {
        let scale = videoRect.width / CGFloat(max(1, model.doc.previewWidth))
        guard scale > 0 else { return }
        let startPreview = viewToPreview(value.startLocation, videoRect: videoRect)
        if case .none = cropDrag {
            cropDrag = hitTest(startPreview, sel: model.cropSel,
                               handleRadius: 14 / scale)
            cropDragStartSel = model.cropSel
        }
        let dx = (value.location.x - value.startLocation.x) / scale
        let dy = (value.location.y - value.startLocation.y) / scale
        applyCropDrag(dx: dx, dy: dy)
    }

    private func hitTest(_ p: CGPoint, sel: CGRect, handleRadius: CGFloat) -> CropDragKind {
        for (dx, dy) in Self.cornerOffsets {
            let corner = CGPoint(x: sel.midX + dx * sel.width / 2,
                                 y: sel.midY + dy * sel.height / 2)
            if hypot(p.x - corner.x, p.y - corner.y) <= handleRadius {
                return .corner(dx: dx, dy: dy)
            }
        }
        if sel.insetBy(dx: -6, dy: -6).contains(p) { return .move }
        return .move // клик вне рамки тоже двигает — центрируем к точке ниже
    }

    private func applyCropDrag(dx: CGFloat, dy: CGFloat) {
        let pw = CGFloat(model.doc.previewWidth)
        let ph = CGFloat(model.doc.previewHeight)
        let minSide: CGFloat = 24
        var sel = cropDragStartSel

        switch cropDrag {
        case .none:
            return
        case .move:
            sel.origin.x = min(max(0, sel.origin.x + dx), pw - sel.width)
            sel.origin.y = min(max(0, sel.origin.y + dy), ph - sel.height)
        case .corner(let cx, let cy):
            // Противоположный угол зафиксирован; квадрат по большей дельте.
            let anchor = CGPoint(x: sel.midX - cx * sel.width / 2,
                                 y: sel.midY - cy * sel.height / 2)
            let moved = CGPoint(
                x: sel.midX + cx * sel.width / 2 + dx,
                y: sel.midY + cy * sel.height / 2 + dy)
            var side = max(abs(moved.x - anchor.x), abs(moved.y - anchor.y))
            // не выходим за края холста в направлении тянущегося угла
            let maxW = cx > 0 ? pw - anchor.x : anchor.x
            let maxH = cy > 0 ? ph - anchor.y : anchor.y
            side = max(minSide, min(side, min(maxW, maxH)))
            sel = CGRect(x: cx > 0 ? anchor.x : anchor.x - side,
                         y: cy > 0 ? anchor.y : anchor.y - side,
                         width: side, height: side)
        }
        model.cropSel = sel
    }

    // MARK: - оверлей обработки

    private func processingBadge(title: String, detail: String?) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMain)
            }
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surfaceRaised.opacity(0.94)))
    }
}
#endif
