#!/bin/bash
# Сборка Da10bayo.app
#   ./build.sh            — собрать в build/Da10bayo.app
#   ./build.sh --install  — собрать, установить в /Applications и запустить
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Da10bayo"
APP="build/${APP_NAME}.app"

# Подпись. Ad-hoc подпись меняется при каждой сборке, и macOS сбрасывает выданные
# разрешения («Универсальный доступ», Связка ключей). Если в системе есть сертификат
# «Apple Development», подписываем им — тогда разрешения переживают пересборки.
# Свой сертификат можно задать: SIGN_IDENTITY="…" ./build.sh
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "▸ Компиляция (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Сборка бандла…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Мост «Сейчас играет» (Яндекс Музыка и другие плееры)…"
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit \
    Helpers/MediaRemoteBridge.m -o "$APP/Contents/Resources/libD10MediaRemote.dylib"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/libD10MediaRemote.dylib"
cp Helpers/mediaremote.pl "$APP/Contents/Resources/mediaremote.pl"

if [ -f Resources/AppIcon.png ]; then
    echo "▸ Иконка…"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "▸ Подпись (ad-hoc — разрешения могут сбрасываться после пересборки)…"
else
    echo "▸ Подпись: $SIGN_IDENTITY"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo "✓ Готово: $APP"

if [ "${1:-}" = "--install" ]; then
    echo "▸ Установка в /Applications…"
    pkill -x "$APP_NAME" 2>/dev/null || true
    # Ждём, пока старый процесс завершится, иначе open падает с ошибкой -600.
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.3; done
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "✓ Запущено. Найдите остров у выреза экрана."
fi
