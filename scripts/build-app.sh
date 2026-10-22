#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
BUILD_MODE="${1:-full}"
if [[ "$BUILD_MODE" != "full" && "$BUILD_MODE" != "--native-only" ]]; then
    print -u2 "Usage: scripts/build-app.sh [--native-only]"
    exit 2
fi
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift build -c release --product FileFan --cache-path .build/cache --config-path .build/config --security-path .build/security --manifest-cache local --disable-sandbox
BINARY_DIR=$(swift build -c release --show-bin-path --cache-path .build/cache --config-path .build/config --security-path .build/security --manifest-cache local --disable-sandbox)
APP_DIR="$PROJECT_DIR/dist/FileFan.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_DIR/FileFan" "$APP_DIR/Contents/MacOS/FileFan.next"
mv -f "$APP_DIR/Contents/MacOS/FileFan.next" "$APP_DIR/Contents/MacOS/FileFan"
cp -R "$BINARY_DIR/FileFan_FileFanCore.bundle" "$APP_DIR/Contents/Resources/"
if [[ "$BUILD_MODE" == "--native-only" ]]; then
    test -x "$APP_DIR/Contents/Resources/Backend/filee-cli"
    test -f "$APP_DIR/Contents/Resources/Backend/backend-manifest.json"
else
    zsh scripts/backend-capabilities-build.sh
    python3 scripts/backend-package.py "$APP_DIR/Contents/Resources/Backend"
fi
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
swift Resources/generate-icon.swift "$PROJECT_DIR/.build/FileFan.iconset"
cp "$PROJECT_DIR/.build/FileFan.icns" "$APP_DIR/Contents/Resources/FileFan.icns"
plutil -lint "$APP_DIR/Contents/Info.plist"
if [[ "$BUILD_MODE" != "--native-only" ]]; then
    codesign --force --deep --sign - "$APP_DIR"
    python3 scripts/backend-package.py --rehash "$APP_DIR/Contents/Resources/Backend"
fi
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
test -x "$APP_DIR/Contents/MacOS/FileFan"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")" = "local.filefan.app"
print "Built: $APP_DIR"
