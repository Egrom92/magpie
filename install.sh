#!/bin/bash
# Установка или обновление Magpie одной командой (история при обновлении не трогается):
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/magpie/main/install.sh | bash
# или из скачанной папки:  ./install.sh
set -euo pipefail

REPO="Egrom92/magpie"
say() { printf '\n\033[1m▶︎ %s\033[0m\n' "$*"; }
die() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Magpie работает только на macOS."
ver=$(sw_vers -productVersion)
[ "${ver%%.*}" -ge 14 ] || die "Нужна macOS 14 Sonoma или новее (у вас $ver)."

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    say "Нужны бесплатные инструменты разработчика Apple (Command Line Tools)"
    echo "Сейчас откроется окно установки: нажмите «Установить», дождитесь окончания"
    echo "(5–15 минут) и запустите эту же команду ещё раз."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

# Исходники: из этой папки или свежие с GitHub
self="${BASH_SOURCE[0]:-}"
if [ -n "$self" ] && [ -f "$(dirname "$self")/Sources/main.swift" ] && [ -f "$(dirname "$self")/Resources/AppIcon.icns" ]; then
    cd "$(dirname "$self")"
else
    say "Скачиваю Magpie с GitHub"
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/magpie.XXXXXX")
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$TMP" \
        || die "Не удалось скачать https://github.com/$REPO. Проверьте интернет."
    cd "$TMP/magpie-main"
fi

DEST=/Applications
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"   # у обычного (не администратора) пользователя нет прав на /Applications
    mkdir -p "$DEST"
fi
APP="$DEST/Magpie.app"
BUILD=build/Magpie.app
arch=$(uname -m)

say "Собираю Magpie (первый раз около минуты)"
rm -rf build
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" -o "$BUILD/Contents/MacOS/Magpie" Sources/main.swift \
    || die "Сборка не удалась. Обновите Command Line Tools (Системные настройки → Основные → Обновление ПО) и попробуйте снова."
cp Resources/AppIcon.icns "$BUILD/Contents/Resources/AppIcon.icns"

cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>local.magpie</string>
    <key>CFBundleName</key><string>Magpie</string>
    <key>CFBundleDisplayName</key><string>Magpie</string>
    <key>CFBundleExecutable</key><string>Magpie</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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
Magpie сам запускается при входе в систему. Обновить — запустить эту же команду ещё раз.
Удалить: curl -fsSL https://raw.githubusercontent.com/Egrom92/magpie/main/uninstall.sh | bash
DONE
