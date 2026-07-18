#!/bin/bash
# Сборка StickerStudio.app из SwiftPM-билда (запускать на macOS).
#
#   ./make-app.sh                    — release-сборка + бандл в dist/StickerStudio.app
#   FFMPEG_BIN=/path/ffmpeg ./make-app.sh   — встроить конкретный бинарник
#   NO_FFMPEG=1 ./make-app.sh        — собрать без встроенного ffmpeg
#
# ffmpeg встраивается в Contents/Resources автоматически: берётся первый
# найденный из FFMPEG_BIN, ./ffmpeg, PATH и типовых префиксов Homebrew
# (включая ~/homebrew). Homebrew-бинарник слинкован с dylib-ами своего
# префикса — такой бандл работает на этой машине, но не для раздачи другим;
# для распространения подложите статическую сборку через FFMPEG_BIN.
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

# --- встраивание ffmpeg ---
find_ffmpeg() {
    if [ -n "${FFMPEG_BIN:-}" ] && [ -x "$FFMPEG_BIN" ]; then
        echo "$FFMPEG_BIN"; return
    fi
    if [ -x ffmpeg ]; then
        echo "$PWD/ffmpeg"; return
    fi
    command -v ffmpeg 2>/dev/null && return
    for c in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg \
             "$HOME/homebrew/bin/ffmpeg" "$HOME/.homebrew/bin/ffmpeg" \
             /opt/local/bin/ffmpeg; do
        if [ -x "$c" ]; then echo "$c"; return; fi
    done
    return 1
}

if [ "${NO_FFMPEG:-0}" = "1" ]; then
    echo "ffmpeg не встраивается (NO_FFMPEG=1): приложение будет искать его само"
elif FF="$(find_ffmpeg)"; then
    cp "$FF" "$APP/Contents/Resources/ffmpeg"
    chmod +x "$APP/Contents/Resources/ffmpeg"
    echo "ffmpeg встроен: $FF"
    if command -v otool >/dev/null && \
       otool -L "$FF" | grep -qE "$HOME|/opt/homebrew|/usr/local/Cellar"; then
        echo "⚠ этот ffmpeg слинкован с библиотеками Homebrew: бандл будет"
        echo "  работать на этой машине, но для раздачи другим возьмите"
        echo "  статическую сборку и соберите с FFMPEG_BIN=/путь/к/ffmpeg"
    fi
else
    echo "⚠ ffmpeg не найден — бандл собран без него; приложение поищет"
    echo "  ffmpeg в Homebrew/PATH при запуске (brew install ffmpeg)"
fi

# ad-hoc подпись, чтобы бандл запускался локально без Developer ID
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "Готово: $APP"
