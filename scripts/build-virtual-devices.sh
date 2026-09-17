#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/virtual-devices"

mkdir -p "$BUILD_DIR"

echo "=== Building VDI Camera System Extension ==="

CAMERA_SRC="$PROJECT_DIR/VirtualDevices/VDICamera"
CAMERA_APP_SRC="$PROJECT_DIR/VirtualDevices/VDICameraApp"
CAMERA_APP="$BUILD_DIR/VDICameraHost.app"
CAMERA_SYSEXT="$CAMERA_APP/Contents/Library/SystemExtensions/com.osx-vdi.camera-host.extension.systemextension"

rm -rf "$CAMERA_APP"
mkdir -p "$CAMERA_APP/Contents/MacOS"
mkdir -p "$CAMERA_SYSEXT/Contents/MacOS"

# Build the camera extension
swiftc \
    -target arm64-apple-macosx14.0 \
    -framework CoreMediaIO \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework VideoToolbox \
    -framework IOKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$CAMERA_SRC/Info.plist" \
    -o "$CAMERA_SYSEXT/Contents/MacOS/VDICamera-arm64" \
    "$CAMERA_SRC/main.swift"

swiftc \
    -target x86_64-apple-macosx14.0 \
    -framework CoreMediaIO \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework VideoToolbox \
    -framework IOKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$CAMERA_SRC/Info.plist" \
    -o "$CAMERA_SYSEXT/Contents/MacOS/VDICamera-x86_64" \
    "$CAMERA_SRC/main.swift"

lipo -create \
    "$CAMERA_SYSEXT/Contents/MacOS/VDICamera-arm64" \
    "$CAMERA_SYSEXT/Contents/MacOS/VDICamera-x86_64" \
    -output "$CAMERA_SYSEXT/Contents/MacOS/VDICamera"

rm "$CAMERA_SYSEXT/Contents/MacOS/VDICamera-arm64" "$CAMERA_SYSEXT/Contents/MacOS/VDICamera-x86_64"
cp "$CAMERA_SRC/Info.plist" "$CAMERA_SYSEXT/Contents/"

# Sign the camera extension with entitlements
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" \
    --entitlements "$CAMERA_SRC/entitlements.plist" \
    "$CAMERA_SYSEXT"

echo "  Built camera extension: $CAMERA_SYSEXT"

# Build the container host app
swiftc \
    -target arm64-apple-macosx14.0 \
    -framework Foundation \
    -framework SystemExtensions \
    -framework AppKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$CAMERA_APP_SRC/Info.plist" \
    -o "$CAMERA_APP/Contents/MacOS/VDICameraHost-arm64" \
    "$CAMERA_APP_SRC/main.swift"

swiftc \
    -target x86_64-apple-macosx14.0 \
    -framework Foundation \
    -framework SystemExtensions \
    -framework AppKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$CAMERA_APP_SRC/Info.plist" \
    -o "$CAMERA_APP/Contents/MacOS/VDICameraHost-x86_64" \
    "$CAMERA_APP_SRC/main.swift"

lipo -create \
    "$CAMERA_APP/Contents/MacOS/VDICameraHost-arm64" \
    "$CAMERA_APP/Contents/MacOS/VDICameraHost-x86_64" \
    -output "$CAMERA_APP/Contents/MacOS/VDICameraHost"

rm "$CAMERA_APP/Contents/MacOS/VDICameraHost-arm64" "$CAMERA_APP/Contents/MacOS/VDICameraHost-x86_64"
cp "$CAMERA_APP_SRC/Info.plist" "$CAMERA_APP/Contents/"

# Sign the container app with entitlements (must sign AFTER embedding the extension)
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" \
    --entitlements "$CAMERA_APP_SRC/entitlements.plist" \
    "$CAMERA_APP"

echo "  Built camera host app: $CAMERA_APP"

echo ""
echo "=== Building VDI Camera DAL Plugin ==="

CAM_DAL_SRC="$PROJECT_DIR/VirtualDevices/VDICamera"
CAM_DAL="$BUILD_DIR/VDICamera.plugin"
rm -rf "$CAM_DAL"
mkdir -p "$CAM_DAL/Contents/MacOS"

clang \
    -target arm64-apple-macosx14.0 \
    -bundle \
    -framework CoreMediaIO \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework CoreFoundation \
    -framework IOKit \
    -o "$CAM_DAL/Contents/MacOS/VDICamera-arm64" \
    "$CAM_DAL_SRC/VDICameraPlugin.c"

clang \
    -target x86_64-apple-macosx14.0 \
    -bundle \
    -framework CoreMediaIO \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework CoreFoundation \
    -framework IOKit \
    -o "$CAM_DAL/Contents/MacOS/VDICamera-x86_64" \
    "$CAM_DAL_SRC/VDICameraPlugin.c"

lipo -create \
    "$CAM_DAL/Contents/MacOS/VDICamera-arm64" \
    "$CAM_DAL/Contents/MacOS/VDICamera-x86_64" \
    -output "$CAM_DAL/Contents/MacOS/VDICamera"

rm "$CAM_DAL/Contents/MacOS/VDICamera-arm64" "$CAM_DAL/Contents/MacOS/VDICamera-x86_64"

cp "$CAM_DAL_SRC/Info-DAL.plist" "$CAM_DAL/Contents/Info.plist"

codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$CAM_DAL"

echo "  Built: $CAM_DAL"

echo ""
echo "=== Building VDI Microphone HAL Plugin ==="

MIC_SRC="$PROJECT_DIR/VirtualDevices/VDIMicrophone"
MIC_DRIVER="$BUILD_DIR/VDIMicrophone.driver"
rm -rf "$MIC_DRIVER"
mkdir -p "$MIC_DRIVER/Contents/MacOS"

clang \
    -target arm64-apple-macosx14.0 \
    -bundle \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$MIC_DRIVER/Contents/MacOS/VDIMicrophone-arm64" \
    "$MIC_SRC/VDIMicDriver.c"

clang \
    -target x86_64-apple-macosx14.0 \
    -bundle \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$MIC_DRIVER/Contents/MacOS/VDIMicrophone-x86_64" \
    "$MIC_SRC/VDIMicDriver.c"

lipo -create \
    "$MIC_DRIVER/Contents/MacOS/VDIMicrophone-arm64" \
    "$MIC_DRIVER/Contents/MacOS/VDIMicrophone-x86_64" \
    -output "$MIC_DRIVER/Contents/MacOS/VDIMicrophone"

rm "$MIC_DRIVER/Contents/MacOS/VDIMicrophone-arm64" "$MIC_DRIVER/Contents/MacOS/VDIMicrophone-x86_64"

cp "$MIC_SRC/Info.plist" "$MIC_DRIVER/Contents/"

codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$MIC_DRIVER"

echo "  Built: $MIC_DRIVER"

echo ""
echo "=== Build Complete ==="
echo ""
echo "To install, run:"
echo "  sudo bash $SCRIPT_DIR/install-virtual-devices.sh"
