#!/bin/bash
# Установка Magpie (история буфера обмена) в /Applications. Повторный запуск — обновление; история не трогается.
#   ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1m▶︎ %s\033[0m\n' "$*"; }
die() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Нужен macOS."
xcrun --find swiftc >/dev/null 2>&1 || { xcode-select --install 2>/dev/null || true; die "Нужны Command Line Tools: установите и запустите снова."; }

APP=/Applications/Magpie.app
BUILD=build/Magpie.app
arch=$(uname -m)

say "Собираю Magpie (первый раз около минуты)"
rm -rf build
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" -o "$BUILD/Contents/MacOS/Magpie" Sources/main.swift

cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>local.magpie</string>
    <key>CFBundleName</key><string>Magpie</string>
    <key>CFBundleDisplayName</key><string>Magpie</string>
    <key>CFBundleExecutable</key><string>Magpie</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Roman Egliens</string>
</dict></plist>
PLIST
codesign --force --sign - "$BUILD" 2>/dev/null

say "Ставлю в $APP"
pkill -x Magpie 2>/dev/null || true
sleep 0.5
rm -rf "$APP"
ditto "$BUILD" "$APP"
open "$APP"

cat <<'DONE'

✅ Готово: значок буфера (планшет со списком) в строке меню.
  • Щелчок по значку — история справа на всю высоту экрана; Esc или щелчок мимо — закрыть.
  • Сверху фильтр: Все / Текст / Картинки / Файлы. Записи разделены по дням.
  • Кнопка ⧉ у записи (или щелчок по ней) кладёт её в буфер и закрывает панель.
  • Правый щелчок по записи — удалить из истории; по значку — очистить всё, автозапуск, выход.
  • История хранится 7 дней. Пароли из менеджеров паролей не сохраняются.
Magpie сам запускается при входе в систему. Обновить — запустить ./install.sh ещё раз.
DONE
