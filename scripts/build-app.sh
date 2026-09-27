#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
swift build --configuration release
BIN_DIR="$(swift build --configuration release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/MacDou.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/MacDou" "$APP_DIR/Contents/MacOS/MacDou"
LIBUSB_PREFIX="${LIBUSB_PREFIX:-/opt/homebrew/opt/libusb}"
if [[ ! -f "$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib" || ! -f "$LIBUSB_PREFIX/include/libusb-1.0/libusb.h" || ! -f "$LIBUSB_PREFIX/COPYING" ]]; then
    echo "libusb development files are required; set LIBUSB_PREFIX to an existing installation." >&2
    exit 1
fi
HELPER="$APP_DIR/Contents/MacOS/modem-helper"
xcrun clang -std=c11 -O2 -Wall -Wextra -arch arm64 -mmacosx-version-min=26.0 \
    -I "$LIBUSB_PREFIX/include/libusb-1.0" "$PROJECT_DIR/Native/modem-helper.c" \
    -L "$LIBUSB_PREFIX/lib" -lusb-1.0 -o "$HELPER"
cp "$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib" "$APP_DIR/Contents/MacOS/"
chmod u+w "$APP_DIR/Contents/MacOS/libusb-1.0.0.dylib"
install_name_tool -id '@executable_path/libusb-1.0.0.dylib' "$APP_DIR/Contents/MacOS/libusb-1.0.0.dylib"
install_name_tool -change "$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib" '@executable_path/libusb-1.0.0.dylib' "$HELPER"
cp "$LIBUSB_PREFIX/COPYING" "$APP_DIR/Contents/Resources/libusb-LICENSE.txt"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
ICON_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
mkdir -p "$ICON_DIR"
sips -s format png "$PROJECT_DIR/Resources/AppIcon.svg" --out "$PROJECT_DIR/.build/AppIcon.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PROJECT_DIR/.build/AppIcon.png" --out "$ICON_DIR/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PROJECT_DIR/.build/AppIcon.png" --out "$ICON_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR/Contents/MacOS/libusb-1.0.0.dylib"
codesign --force --sign - "$HELPER"
codesign --force --sign - --identifier com.fan.macdou "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf 'App ready: %s\n' "$APP_DIR"
