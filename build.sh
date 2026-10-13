#!/bin/bash
# Сборка Notchling без Xcode (нужны только Command Line Tools: xcode-select --install).
# Результат: ~/Applications/Notchling.app. Лог сборки: build.log.
set -uo pipefail
cd "$(dirname "$0")"
exec > >(tee build.log) 2>&1

APP_NAME="Notchling"
BUILD="build/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"

echo "== Сборка $(date '+%H:%M:%S')"
rm -rf build && mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources/sounds"

if ! swiftc -O -swift-version 5 \
     -target "$(uname -m)-apple-macos14.0" \
     -module-name Notchling \
     -o "$BUILD/Contents/MacOS/$APP_NAME" \
     Sources/Wisp/*.swift Sources/App/*.swift; then
  echo "== ОШИБКА КОМПИЛЯЦИИ"
  exit 1
fi

cp Info.plist "$BUILD/Contents/Info.plist"
cp Resources/sounds/*.wav "$BUILD/Contents/Resources/sounds/"
iconutil -c icns Resources/AppIcon.iconset -o "$BUILD/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "   (иконку собрать не удалось — не страшно)"

# --- Аудит: в бинарнике не должно быть ни одного сетевого вызова -------------
echo "== Аудит сети"
BIN="$BUILD/Contents/MacOS/$APP_NAME"
NET=$(nm -u "$BIN" | grep -Ei 'URLSession|NSURLConnection|NSURLRequest|URLRequest|_nw_|NWConnection|NWPathMonitor|NWListener|CFSocket|CFStream|CFHTTP|CFNetwork|getaddrinfo|gethostbyname|^_connect$|^_socket$|^_sendto$|WebSocket|WKWebView|CloudKit|CKContainer|UNUserNotification|SFSafari' || true)
if [ -n "$NET" ]; then
  echo "!! Найдены сетевые символы — сборка остановлена:"
  echo "$NET"
  exit 2
fi
echo "   сетевых вызовов нет ✓"
echo "   библиотеки:"; otool -L "$BIN" | tail -n +2 | sed 's/^/   /'

# --- Подпись -----------------------------------------------------------------
# Постоянный локальный сертификат «Notchling Local Signing» (создаётся один раз в связке ключей
# входа). С ним macOS не сбрасывает «Универсальный доступ» после каждой пересборки.
# Сертификат самоподписанный, никуда не отправляется.
IDENTITY="Notchling Local Signing"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "== Создаю локальный сертификат подписи (один раз)"
  TMP=$(mktemp -d)
  cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" -extensions ext \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -passout pass:notchling -name "$IDENTITY" >/dev/null 2>&1
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P notchling -T /usr/bin/codesign >/dev/null 2>&1 && echo "   сертификат добавлен в связку ключей"
  rm -rf "$TMP"
fi
if codesign --force --deep --sign "$IDENTITY" --identifier io.github.notchling "$BUILD"; then
  echo "== Подписано: $IDENTITY"
else
  echo "== Постоянная подпись не удалась, подписываю ad-hoc (доступ придётся выдавать заново)"
  codesign --force --deep --sign - --identifier io.github.notchling "$BUILD" >/dev/null 2>&1 || true
fi

echo "== Проверка подписи"
codesign --verify --deep --strict "$BUILD" && echo "   подпись в порядке ✓"
codesign -dv --verbose=2 "$BUILD" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier)=" | sed 's/^/   /'

# Режим разработки (файл .devmode в папке проекта): диагностика пишется в .diag/ рядом.
if [ -f .devmode ]; then
  mkdir -p .diag
  defaults write io.github.notchling diagDir "$(pwd)/.diag"
  defaults write io.github.notchling debugLog -bool true
  echo "== Режим разработки: диагностика в $(pwd)/.diag"
fi

# Установка
pkill -x "$APP_NAME" 2>/dev/null && sleep 0.7
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
if ditto "$BUILD" "$DEST" && [ -x "$DEST/Contents/MacOS/$APP_NAME" ]; then
  echo "== Установлено: $DEST"
else
  echo "!! Не удалось установить в $DEST — запускаю прямо из папки сборки"
  DEST="$(pwd)/$BUILD"
fi
open "$DEST" && echo "== Запущено: $DEST"
