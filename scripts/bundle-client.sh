#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$BUILD_DIR/VDIClient.app"

BINARY="$BUILD_DIR/debug/vdi-client"
if [ "$1" = "release" ]; then
    BINARY="$BUILD_DIR/apple/Products/Release/vdi-client"
fi

if [ ! -f "$BINARY" ]; then
    echo "Binary not found at $BINARY"
    echo "Run 'swift build' first"
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$PROJECT_DIR/Sources/VDIClient/Info.plist" "$APP_DIR/Contents/"
cp "$BINARY" "$APP_DIR/Contents/MacOS/vdi-client"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR"

echo "Created $APP_DIR"
echo "URL scheme 'vdi://' registered"
