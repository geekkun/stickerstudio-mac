import Foundation

/// Направленный хромакей (в духе Keylight), прямой порт Windows-версии:
///  - матовость = расстояние хромы пикселя от ключевого оттенка в UV;
///  - smoothstep-кривая вместо линейной — мягкие края;
///  - despill: загрязнённые ключом цвета мягко идут к своей яркости;
///  - морфология (shrink/grow) и финальное 3x3-перо маски.
/// Один и тот же код для превью и экспорта — WYSIWYG.
///
/// Все функции работают с буфером BGRA (порядок байтов B,G,R,A), как отдаёт
/// ffmpeg `format=bgra`. CPU-реализация без Metal — сознательно: сначала
/// паритет поведения, оптимизации потом.
public enum ChromaKey {

    public static func apply(toBGRA px: inout [UInt8], width w: Int, height h: Int,
                             stride: Int, settings k: KeySettings) {
        guard k.enabled, w > 0, h > 0 else { return }
        let count = w * h

        let keyR = Double(k.screenColor.r) / 255.0
        let keyG = Double(k.screenColor.g) / 255.0
        let keyB = Double(k.screenColor.b) / 255.0
        let keyU = -0.100644 * keyR - 0.338572 * keyG + 0.439216 * keyB + 0.501961
        let keyV = 0.439216 * keyR - 0.398942 * keyG - 0.040274 * keyB + 0.501961

        // OBS использует similarity=0.4, smoothness=0.08 и spill=0.1.
        // Текущий Gain сохраняем как один понятный контрол допуска.
        let similarity = 0.18 + Double(max(0, min(200, k.gain))) * 0.0021
        let smoothness = 0.085
        let spillRange = 0.11

        var distance = [Double](repeating: 0, count: count)
        for y in 0..<h {
            let row = y * stride
            for x in 0..<w {
                let i = row + x * 4
                let b = Double(px[i]) / 255.0
                let g = Double(px[i + 1]) / 255.0
                let r = Double(px[i + 2]) / 255.0
                let u = -0.100644 * r - 0.338572 * g + 0.439216 * b + 0.501961
                let v = 0.439216 * r - 0.398942 * g - 0.040274 * b + 0.501961
                let du = u - keyU
                let dv = v - keyV
                distance[y * w + x] = (du * du + dv * dv).squareRoot()
            }
        }

        // CPU-аналог box-filter из OBS shader: центр + четыре соседа.
        // Это стабилизирует matte на шумном H.264 и не создаёт рваную лесенку.
        var filtered = [Double](repeating: 0, count: count)
        for y in 0..<h {
            let up = max(0, y - 1)
            let down = min(h - 1, y + 1)
            for x in 0..<w {
                let left = max(0, x - 1)
                let right = min(w - 1, x + 1)
                let idx = y * w + x
                filtered[idx] = (distance[idx] + 2.0 * (
                    distance[y * w + left] + distance[y * w + right] +
                    distance[up * w + x] + distance[down * w + x])) / 9.0
            }
        }

        var alpha = [UInt8](repeating: 0, count: count)
        var spillKeep = [Double](repeating: 0, count: count)
        for idx in 0..<count {
            // Соседний фильтр не должен съедать тонкую белую проволоку или блик:
            // если сам центральный пиксель явно далёк от screen color, сохраняем его.
            var effectiveDistance = filtered[idx]
            if distance[idx] >= similarity + smoothness {
                effectiveDistance = max(effectiveDistance, distance[idx])
            }
            let baseMask = effectiveDistance - similarity
            let matte = pow(saturate(baseMask / smoothness), 1.5)
            alpha[idx] = UInt8((matte * 255.0).rounded())
            spillKeep[idx] = pow(saturate(baseMask / spillRange), 1.5)
        }

        // shrink/grow: min/max-фильтр 3x3, до 3 итераций
        let sg = k.shrinkGrow
        let iters = min(3, abs(sg) / 34 + (abs(sg) > 0 ? 1 : 0))
        if iters > 0 {
            let grow = sg > 0
            var tmp = [UInt8](repeating: 0, count: count)
            for _ in 0..<iters {
                minMax3x3(src: alpha, dst: &tmp, w: w, h: h, useMax: grow)
                swap(&alpha, &tmp)
            }
        }

        // перо: одно 3x3-сглаживание маски убирает "лесенку" на краях
        let unblurred = alpha
        var blurred = [UInt8](repeating: 0, count: count)
        box3x3(src: unblurred, dst: &blurred, w: w, h: h)
        for idx in 0..<count {
            // Сохраняем уверенный foreground, размываем только переход и
            // прозрачную сторону края. Так тонкие детали не превращаются в 1/3 alpha.
            alpha[idx] = unblurred[idx] >= 240 ? unblurred[idx] : blurred[idx]
        }

        // OBS-style despill: загрязнённые ключом цвета мягко идут к своей яркости,
        // а не просто теряют зелёный канал и не дают серо-чёрную кромку.
        for y in 0..<h {
            let row = y * stride
            for x in 0..<w {
                let i = row + x * 4
                let idx = y * w + x
                let a = alpha[idx]
                let srcA = Int(px[i + 3])

                let keep = spillKeep[idx]
                let b = Double(px[i])
                let g = Double(px[i + 1])
                let r = Double(px[i + 2])
                let luma = r * 0.2126 + g * 0.7152 + b * 0.0722
                px[i] = clampByte(Int((luma * (1.0 - keep) + b * keep).rounded()))
                px[i + 1] = clampByte(Int((luma * (1.0 - keep) + g * keep).rounded()))
                px[i + 2] = clampByte(Int((luma * (1.0 - keep) + r * keep).rounded()))

                px[i + 3] = UInt8(Int(a) * srcA / 255)
            }
        }

        // Лёгкая защита до ресайза. Основной радиус 3 px применяется уже
        // на конечных 512x512 непосредственно перед VP9.
        protectTransparentColors(px: &px, w: w, h: h, stride: stride, radius: 1)
    }

    /// Финальная подготовка 512px-кадра. Внешнее субпиксельное перо хранится
    /// прямо в alpha и поэтому остаётся гладким даже в плеерах, которые
    /// увеличивают WebM через nearest/point sampling. Затем RGB прозрачной
    /// стороны продолжается от foreground для безопасного yuva420p.
    public static func prepareForVP9(px: inout [UInt8], width w: Int, height h: Int,
                                     stride: Int, colorRadius: Int) {
        softenOuterAlpha(px: &px, w: w, h: h, stride: stride)
        protectTransparentColors(px: &px, w: w, h: h, stride: stride, radius: colorRadius)
    }

    static func softenOuterAlpha(px: inout [UInt8], w: Int, h: Int, stride: Int) {
        guard w > 0, h > 0 else { return }
        var source = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * stride
            for x in 0..<w {
                source[y * w + x] = px[row + x * 4 + 3]
            }
        }

        // Gaussian 1-2-1, но только наружу: уверенный foreground и тонкие
        // провода не теряют плотность, рядом появляется coverage до ~0.3 px.
        for y in 0..<h {
            let y0 = max(0, y - 1)
            let y1 = min(h - 1, y + 1)
            let row = y * stride
            for x in 0..<w {
                let x0 = max(0, x - 1)
                let x1 = min(w - 1, x + 1)
                var weighted = 0
                var total = 0
                for yy in y0...y1 {
                    let wy = yy == y ? 2 : 1
                    for xx in x0...x1 {
                        let weight = wy * (xx == x ? 2 : 1)
                        weighted += Int(source[yy * w + xx]) * weight
                        total += weight
                    }
                }
                let blurred = weighted / max(1, total)
                let feather = (blurred * 2 + 1) / 3
                let current = Int(source[y * w + x])
                if feather > current {
                    px[row + x * 4 + 3] = UInt8(feather)
                }
            }
        }
    }

    /// VP9 yuva420p усредняет цвет 2x2 без знания alpha. Поэтому RGB прозрачной
    /// стороны кромки должен продолжать foreground, иначе зелёный screen снова
    /// протечёт в непрозрачный пиксель при chroma subsampling.
    public static func protectTransparentColors(px: inout [UInt8], w: Int, h: Int,
                                                stride: Int, radius: Int) {
        guard radius > 0, w > 0, h > 0 else { return }
        let count = w * h
        var filled = [Bool](repeating: false, count: count)
        var blue = [UInt8](repeating: 0, count: count)
        var green = [UInt8](repeating: 0, count: count)
        var red = [UInt8](repeating: 0, count: count)
        for y in 0..<h {
            let row = y * stride
            for x in 0..<w {
                let i = row + x * 4
                let idx = y * w + x
                blue[idx] = px[i]
                green[idx] = px[i + 1]
                red[idx] = px[i + 2]
                filled[idx] = px[i + 3] >= 192
            }
        }

        for _ in 0..<radius {
            var add = [Bool](repeating: false, count: count)
            var nb = blue
            var ng = green
            var nr = red
            for y in 0..<h {
                let y0 = max(0, y - 1)
                let y1 = min(h - 1, y + 1)
                for x in 0..<w {
                    let idx = y * w + x
                    if filled[idx] { continue }
                    let x0 = max(0, x - 1)
                    let x1 = min(w - 1, x + 1)
                    var sb = 0, sg = 0, sr = 0, n = 0
                    for yy in y0...y1 {
                        for xx in x0...x1 {
                            let near = yy * w + xx
                            if !filled[near] { continue }
                            sb += Int(blue[near])
                            sg += Int(green[near])
                            sr += Int(red[near])
                            n += 1
                        }
                    }
                    if n == 0 { continue }
                    nb[idx] = UInt8(sb / n)
                    ng[idx] = UInt8(sg / n)
                    nr[idx] = UInt8(sr / n)
                    add[idx] = true
                }
            }
            blue = nb
            green = ng
            red = nr
            var any = false
            for i in 0..<count where add[i] {
                filled[i] = true
                any = true
            }
            if !any { break }
        }

        for y in 0..<h {
            let row = y * stride
            for x in 0..<w {
                let i = row + x * 4
                let idx = y * w + x
                if filled[idx] && px[i + 3] < 192 {
                    px[i] = blue[idx]
                    px[i + 1] = green[idx]
                    px[i + 2] = red[idx]
                } else if !filled[idx] && px[i + 3] <= 2 {
                    px[i] = 0
                    px[i + 1] = 0
                    px[i + 2] = 0
                }
            }
        }
    }

    static func saturate(_ value: Double) -> Double {
        value < 0 ? 0 : (value > 1 ? 1 : value)
    }

    static func clampByte(_ v: Int) -> UInt8 {
        UInt8(v < 0 ? 0 : (v > 255 ? 255 : v))
    }

    static func minMax3x3(src: [UInt8], dst: inout [UInt8], w: Int, h: Int, useMax: Bool) {
        for y in 0..<h {
            let y0 = max(0, y - 1)
            let y1 = min(h - 1, y + 1)
            for x in 0..<w {
                let x0 = max(0, x - 1)
                let x1 = min(w - 1, x + 1)
                var m = src[y * w + x]
                for yy in y0...y1 {
                    for xx in x0...x1 {
                        let v = src[yy * w + xx]
                        if useMax {
                            if v > m { m = v }
                        } else {
                            if v < m { m = v }
                        }
                    }
                }
                dst[y * w + x] = m
            }
        }
    }

    static func box3x3(src: [UInt8], dst: inout [UInt8], w: Int, h: Int) {
        for y in 0..<h {
            let y0 = max(0, y - 1)
            let y1 = min(h - 1, y + 1)
            for x in 0..<w {
                let x0 = max(0, x - 1)
                let x1 = min(w - 1, x + 1)
                var sum = 0
                var n = 0
                for yy in y0...y1 {
                    for xx in x0...x1 {
                        sum += Int(src[yy * w + xx])
                        n += 1
                    }
                }
                dst[y * w + x] = UInt8(sum / n)
            }
        }
    }
}
