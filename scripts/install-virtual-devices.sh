#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/virtual-devices"

# Allow running from the home directory (deployed files)
if [ ! -d "$BUILD_DIR" ]; then
    BUILD_DIR="$HOME"
fi

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run with sudo"
    exit 1
fi

echo "=== Installing VDI Virtual Devices ==="
echo "macOS version: $(sw_vers -productVersion)"
echo "Architecture: $(uname -m)"
echo ""

# --- Microphone HAL Plugin ---
MIC_DRIVER="$BUILD_DIR/VDIMicrophone.driver"
MIC_INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"

if [ -d "$MIC_DRIVER" ]; then
    echo "Installing VDI Microphone..."
    mkdir -p "$MIC_INSTALL_DIR"
    rm -rf "$MIC_INSTALL_DIR/VDIMicrophone.driver"
    cp -R "$MIC_DRIVER" "$MIC_INSTALL_DIR/"
    chown -R root:wheel "$MIC_INSTALL_DIR/VDIMicrophone.driver"
    echo "  Installed to $MIC_INSTALL_DIR/VDIMicrophone.driver"
    echo "  Binary type:"
    file "$MIC_INSTALL_DIR/VDIMicrophone.driver/Contents/MacOS/VDIMicrophone" | head -1
    echo "  Signature:"
    codesign -dvv "$MIC_INSTALL_DIR/VDIMicrophone.driver" 2>&1 | grep -E 'Authority|Signature|adhoc'
    echo "  Verifying factory symbol:"
    nm -g "$MIC_INSTALL_DIR/VDIMicrophone.driver/Contents/MacOS/VDIMicrophone" 2>&1 | grep -i "Factory" || echo "  WARNING: Factory symbol not found!"
    echo "  Verifying plist Load As Application:"
    plutil -p "$MIC_INSTALL_DIR/VDIMicrophone.driver/Contents/Info.plist" | grep -E "Load As Application|CFPlugInTypes" || true
else
    echo "  VDIMicrophone.driver not found at $MIC_DRIVER"
fi

echo ""

# Restart coreaudiod to pick up the mic plugin
echo "Restarting coreaudiod..."
killall coreaudiod 2>/dev/null || true
sleep 2
echo "coreaudiod restarted (PID: $(pgrep coreaudiod))"

echo ""

# --- Camera System Extension via Host App ---
CAMERA_APP="$BUILD_DIR/VDICameraHost.app"

# Clean up old approaches
rm -rf /usr/local/lib/vdi/com.osx-vdi.camera-extension.systemextension 2>/dev/null || true
rm -rf /usr/local/lib/vdi/VDICamera.appex 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.osx-vdi.camera-extension.plist 2>/dev/null || true
rm -rf "/Library/CoreMediaIO/Plug-Ins/DAL/VDICamera.plugin" 2>/dev/null || true

# Unload existing LaunchAgent if present
REAL_USER="${SUDO_USER:-$(whoami)}"
AGENT_PLIST_DST="/Library/LaunchAgents/com.osx-vdi.camera-extension.plist"
su - "$REAL_USER" -c "launchctl unload '$AGENT_PLIST_DST' 2>/dev/null" || true
rm -f "$AGENT_PLIST_DST" 2>/dev/null || true
killall VDICamera 2>/dev/null || true
killall VDICameraHost 2>/dev/null || true
sleep 1

if [ -d "$CAMERA_APP" ]; then
    echo "Installing VDI Camera (System Extension)..."

    rm -rf /Applications/VDICameraHost.app
    cp -R "$CAMERA_APP" /Applications/
    chown -R root:wheel /Applications/VDICameraHost.app

    echo "  Installed to /Applications/VDICameraHost.app"
    echo "  Extension bundle:"
    ls -la "/Applications/VDICameraHost.app/Contents/Library/SystemExtensions/" 2>/dev/null || echo "  (none)"
    echo "  Signature (app):"
    codesign -dvv /Applications/VDICameraHost.app 2>&1 | grep -E 'Authority|TeamIdentifier|Signature|adhoc' || true
    echo "  Signature (extension):"
    codesign -dvv "/Applications/VDICameraHost.app/Contents/Library/SystemExtensions/com.osx-vdi.camera-host.extension.systemextension" 2>&1 | grep -E 'Authority|TeamIdentifier|Signature|adhoc' || true

    echo ""
    echo "  Activating system extension..."
    echo "  (Running host app as $REAL_USER to trigger OSSystemExtensionRequest)"
    su - "$REAL_USER" -c "/Applications/VDICameraHost.app/Contents/MacOS/VDICameraHost &" 2>&1
    sleep 5

    echo "  System extensions:"
    systemextensionsctl list 2>&1 || true
else
    echo "  VDICameraHost.app not found at $CAMERA_APP"
fi

echo ""
echo "=== Verification ==="
echo "HAL plugins:"
ls -la /Library/Audio/Plug-Ins/HAL/ 2>/dev/null || echo "  (none)"
echo ""
echo "Audio devices:"
system_profiler SPAudioDataType 2>/dev/null | grep -A3 "VDI\|Zoom" || echo "  (no VDI/Zoom devices found)"
echo ""
echo "Camera extension process:"
ps aux | grep -E "VDICamera|cmio" | grep -v grep || echo "  (not running)"
echo ""

echo "=== Installation Complete ==="
echo ""
echo "Debug logs:"
echo "  Mic: log show --predicate 'process == \"coreaudiod\"' --last 60s --info --debug"
echo "  Cam: log show --predicate 'process == \"VDICameraHost\" OR process == \"sysextd\"' --last 60s --info --debug"
