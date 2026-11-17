#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$BUILD_DIR/VDIClient.app"

BINARY=""
for candidate in \
    "$BUILD_DIR/apple/Products/Debug/vdi-client" \
    "$BUILD_DIR/apple/Products/Release/vdi-client" \
    "$BUILD_DIR/debug/vdi-client" \
    "$BUILD_DIR/release/vdi-client"; do
    if [ -f "$candidate" ]; then
        BINARY="$candidate"
        break
    fi
done

if [ -z "$BINARY" ]; then
    echo "Binary not found. Run 'swift build' first"
    exit 1
fi
echo "Using binary: $BINARY"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$PROJECT_DIR/Sources/VDIClient/Info.plist" "$APP_DIR/Contents/"
cp "$BINARY" "$APP_DIR/Contents/MacOS/vdi-client"

codesign --force --deep --sign - "$APP_DIR"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR"

echo "Created $APP_DIR"
echo "URL scheme 'vdi://' registered"
