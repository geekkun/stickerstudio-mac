#!/bin/bash
# Сборка StickerStudio.app из SwiftPM-билда (запускать на macOS).
#
#   ./make-app.sh              — release-сборка + бандл в dist/StickerStudio.app
#
# ffmpeg: если рядом со скриптом лежит бинарник `ffmpeg`, он попадёт в
# Contents/Resources и приложение станет самодостаточным. Иначе приложение
# найдёт ffmpeg из Homebrew (/opt/homebrew/bin) или PATH.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/StickerStudio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/StickerStudio "$APP/Contents/MacOS/StickerStudio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Иконка из логотипа (best effort — без неё бандл тоже валиден)
if command -v sips >/dev/null && command -v iconutil >/dev/null && [ -f ../src/uxlive-logo.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 64 128 256 512; do
        sips -z $size $size ../src/uxlive-logo.png \
            --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || true
fi

# Встроенный ffmpeg (опционально)
if [ -f ffmpeg ]; then
    cp ffmpeg "$APP/Contents/Resources/ffmpeg"
    chmod +x "$APP/Contents/Resources/ffmpeg"
    echo "ffmpeg встроен в бандл"
else
    echo "ffmpeg не встроен: приложение будет искать его в Homebrew/PATH"
    echo "(чтобы встроить: положите бинарник ffmpeg рядом с make-app.sh)"
fi

# ad-hoc подпись, чтобы бандл запускался локально без Developer ID
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "Готово: $APP"
