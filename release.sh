#!/bin/bash
# Сборка релиза: универсальное приложение (Apple Silicon + Intel) → dist/Notchling-<версия>.zip
# Запускается на GitHub (см. .github/workflows/release.yml) или локально: bash release.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.0.0}"
APP_NAME="Notchling"
OUT="dist"
APP="$OUT/$APP_NAME.app"
ZIP="$OUT/$APP_NAME-$VERSION.zip"

echo "== Notchling $VERSION"
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/sounds" "$OUT/obj"

for ARCH in arm64 x86_64; do
  echo "== Компиляция $ARCH"
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" -module-name Notchling \
    -o "$OUT/obj/$APP_NAME-$ARCH" Sources/Wisp/*.swift Sources/App/*.swift
done
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "$OUT/obj/$APP_NAME-arm64" "$OUT/obj/$APP_NAME-x86_64"
rm -rf "$OUT/obj"

cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
cp Resources/sounds/*.wav "$APP/Contents/Resources/sounds/"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Аудит: ни одного сетевого вызова (как в build.sh)
echo "== Аудит сети"
NET=$(nm -u "$APP/Contents/MacOS/$APP_NAME" | grep -Ei 'URLSession|NSURLConnection|NSURLRequest|URLRequest|_nw_|NWConnection|NWPathMonitor|NWListener|CFSocket|CFStream|CFHTTP|CFNetwork|getaddrinfo|gethostbyname|^_connect$|^_socket$|^_sendto$|WebSocket|WKWebView|CloudKit|CKContainer|UNUserNotification|SFSafari' || true)
if [ -n "$NET" ]; then echo "!! Найдены сетевые символы:"; echo "$NET"; exit 2; fi
if otool -L "$APP/Contents/MacOS/$APP_NAME" | grep -Ei 'Network.framework|CFNetwork'; then
  echo "!! Подключены сетевые фреймворки"; exit 2
fi
echo "   сетевых вызовов нет ✓"
lipo -info "$APP/Contents/MacOS/$APP_NAME"

# Подпись ad-hoc (нотаризация требует платного аккаунта Apple)
codesign --force --deep --sign - --identifier io.github.notchling "$APP"
codesign --verify --deep --strict "$APP" && echo "   подпись в порядке ✓"

ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "== Готово: $ZIP"
