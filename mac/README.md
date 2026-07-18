# Sticker Studio для macOS

Нативный порт uxlive Sticker Studio на Swift/SwiftUI. Функциональный паритет
с Windows-версией: обрезка 1:1, фрагмент 0,5–6 с, удаление однотонного фона,
двухпроходный VP9 WebM с альфой под лимит 256 КБ и hex-патч Duration.

## Требования

- macOS 13+ (Ventura), Apple Silicon или Intel
- Xcode 15+ (или Swift 5.9+ toolchain)
- ffmpeg (сборка с libvpx): `brew install ffmpeg` — либо положите бинарник
  `ffmpeg` рядом с приложением / в `mac/` перед сборкой бандла

## Сборка и запуск

```bash
cd mac

# вариант 1: из Xcode
open Package.swift          # схема StickerStudio → Run

# вариант 2: из терминала
swift run StickerStudio

# вариант 3: полноценный .app-бандл
./make-app.sh               # → dist/StickerStudio.app
```

## Тесты и CLI

```bash
swift test                  # юнит-тесты ядра (патчер, геометрия, хромакей, probe)

# экспорт без UI — удобно для сквозной проверки пайплайна:
swift run stickerctl probe input.mp4
swift run stickerctl export input.mp4 out.webm cut=1:5 crop=200:80:700 key=00FF00:100:0
```

## Архитектура

| Слой | Каталог | Зависимости |
|------|---------|-------------|
| `StickerCore` | `Sources/StickerCore` | только Foundation — собирается и на Linux |
| `StickerStudio` | `Sources/StickerStudio` | SwiftUI/AppKit/ImageIO (только macOS) |
| `stickerctl` | `Sources/stickerctl` | StickerCore |

Ядро — прямой порт C#-версии (`src/*.cs`): `ChromaKey`, `FrameGeometry`,
`EBMLPatcher`, `ExportPipeline`, `VideoDocument`, рендереры точного превью и
playback-кэша. Вся работа с видео — через ffmpeg-сабпроцессы, как в оригинале.

Главное отличие от Windows-версии: экспорт не гоняет PNG-секвенции через
кодеки картинок, а обрабатывает кадры одним raw-BGRA файлом (так уже работал
playback-кэш в оригинале). Это исключает искажения premultiplied-alpha в
CoreGraphics и делает пайплайн тестируемым без UI. Цена — временный файл
крупнее PNG-секвенции (для 4K-квадрата до нескольких ГБ на диске на время
экспорта; после экспорта всё удаляется).

## Горячие клавиши

Пробел — play/pause, ←/→ — покадрово, C — обрезка, B — фон,
⌘O — новое видео, ⌘E — экспорт, ⌘Z — отмена, Esc — выйти из режима.

## Отличия фазы 1 (сознательные)

- Хромакей считается на CPU (как в оригинале); Metal/vImage — следующая фаза
- Автообновление не портировано (на macOS это Sparkle либо App Store)
- ffmpeg не вшит в бинарник gzip-ом: кладётся в Resources бандла или берётся
  из Homebrew/PATH
- Результат сохраняется через стандартный NSSavePanel (готовность к sandbox),
  имя по умолчанию — `<исходник>_sticker.webm`
