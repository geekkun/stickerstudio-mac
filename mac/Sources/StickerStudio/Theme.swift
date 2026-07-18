#if os(macOS)
import SwiftUI

/// Палитра UX Live 2026: ink-black рабочие поверхности с flame-orange
/// акцентом (порт Theme из Common.cs).
enum Theme {
    static let backMain = Color(rgb: 11, 11, 13)
    static let backPanel = Color(rgb: 18, 18, 21)
    static let backHeader = Color(rgb: 24, 24, 28)
    static let backFooter = Color(rgb: 14, 14, 17)
    static let stage = Color(rgb: 14, 14, 17)
    static let surface = Color(rgb: 23, 23, 27)
    static let surfaceRaised = Color(rgb: 29, 29, 34)
    static let surfaceSoft = Color(rgb: 35, 35, 41)

    static let accent = Color(rgb: 255, 62, 5)
    static let accentHover = Color(rgb: 255, 88, 38)
    static let accentPressed = Color(rgb: 218, 47, 0)
    static let accentSoft = Color(rgb: 68, 29, 18)
    static let accent2 = Color(rgb: 255, 126, 73)
    static let telegram = Color(rgb: 51, 169, 242)

    static let textMain = Color(rgb: 249, 248, 246)
    static let textSoft = Color(rgb: 215, 212, 207)
    static let textMuted = Color(rgb: 159, 157, 164)
    static let borderIdle = Color(rgb: 51, 51, 58)
    static let borderHover = Color(rgb: 83, 82, 91)
    static let ok = Color(rgb: 99, 216, 158)
    static let warn = Color(rgb: 247, 197, 95)
    static let err = Color(rgb: 255, 103, 128)
    static let checker1 = Color(rgb: 33, 33, 38)
    static let checker2 = Color(rgb: 44, 44, 50)
    static let btnBase = Color(rgb: 34, 34, 39)
    static let btnHover = Color(rgb: 45, 45, 51)
    static let btnPressed = Color(rgb: 27, 27, 31)
}

extension Color {
    init(rgb r: Double, _ g: Double, _ b: Double) {
        self.init(.sRGB, red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: 1)
    }
}

/// Кнопка в стиле приложения: заливка/акцент/ghost + скругление.
struct StudioButtonStyle: ButtonStyle {
    var accent = false
    var ghost = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(accent ? Color.white : Theme.textMain)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 9)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background(configuration)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(ghost ? Theme.borderIdle : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func background(_ configuration: Configuration) -> Color {
        if accent {
            return configuration.isPressed ? Theme.accentPressed : Theme.accent
        }
        if ghost {
            return configuration.isPressed ? Theme.btnPressed : .clear
        }
        return configuration.isPressed ? Theme.btnPressed : Theme.btnBase
    }
}

/// Шахматка под прозрачность.
struct CheckerboardBackground: View {
    var cell: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / cell))
            let rows = Int(ceil(size.height / cell))
            for row in 0..<rows {
                for col in 0..<cols {
                    let color = (row + col) % 2 == 0 ? Theme.checker1 : Theme.checker2
                    let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                      width: cell, height: cell)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}
#endif
