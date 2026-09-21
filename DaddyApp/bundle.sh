#!/bin/bash
#
# Builds Daddy.app — a real macOS application bundle.
#
# Why this exists: `swift build` produces a bare Unix executable. Run from a
# terminal, macOS never registers it as a foreground application — it inherits
# the terminal's activation context. The menu bar keeps saying "Terminal", and
# anything that pastes into "the focused app" (dictation, for one) pastes into
# the terminal instead of into Daddy. The app has to be a bundle with an
# Info.plist before the system will treat it as its own thing.
#
# Usage:  ./bundle.sh [debug|release]      (default: release)

set -euo pipefail

CONFIG="${1:-release}"
cd "$(dirname "$0")"

if [ -z "${APP_NAME:-}" ]; then
    APP_NAME="Daddy's Home"
fi
# The menu bar and the app switcher show the *executable's* name, so the binary
# is copied in as "Daddy" rather than "DaddyApp".
EXECUTABLE="Daddy"
BUILT_BINARY="DaddyApp"
BUNDLE_ID="com.aaronambrosi.daddy"
APP="build/${APP_NAME}.app"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

BINARY=".build/${CONFIG}/${BUILT_BINARY}"
[ -f "$BINARY" ] || { echo "No binary at $BINARY"; exit 1; }

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "$BINARY" "${APP}/Contents/MacOS/${EXECUTABLE}"

# The provider logos.
#
# SwiftPM puts a target's resources in a generated bundle next to the binary,
# and `Bundle.module` finds it there when the bare executable runs. Inside an
# .app that directory is Contents/MacOS, which `Bundle.module` does not search —
# it looks in Contents/Resources — so without this copy the logos silently fall
# back to letters in the bundled app and only in the bundled app.
RESOURCE_BUNDLE=".build/${CONFIG}/DaddyApp_DaddyApp.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "${APP}/Contents/Resources/"
else
    echo "  (no resource bundle at $RESOURCE_BUNDLE — provider logos will show as letters)"
fi

# Copy app icon if it exists
if [ -f "DaddyApp.icns" ]; then
    cp "DaddyApp.icns" "${APP}/Contents/Resources/"
fi

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>        <string>${EXECUTABLE}</string>
    <key>CFBundleIconFile</key>          <string>DaddyApp</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>    <string>26.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <!-- false = a normal app with a Dock icon and its own menu bar. -->
    <key>LSUIElement</key>               <false/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>   <false/>
    <key>NSMicrophoneUsageDescription</key>  <string>Daddy listens when you double-tap Option so you can add and manage Kanban cards by voice.</string>
    <!-- No NSSpeechRecognitionUsageDescription: transcription is Parakeet running
         in-process via FluidAudio, which never calls Apple's speech service. -->
</dict>
</plist>
PLIST

# A stable signature, not an ad-hoc one.
#
# `--sign -` gave the bundle a fresh identity on every build, and the keychain
# binds its ACLs to that identity — so the Google Drive token prompted for the
# login password again after each rebuild, and "Always Allow" never survived.
# Touch ID has the same problem: a biometric ACL is pinned to the signature
# that created it. Signing with a real certificate is what makes both stick.
#
# Deliberately no `--options runtime`: the hardened runtime gates audio input,
# and this app records the microphone and runs speech recognition. Enabling it
# without `com.apple.security.device.audio-input` breaks voice capture, and it
# is only required for notarization — which a local personal build never does.
#
# Override with SIGN_IDENTITY to use a different certificate; falls back to
# ad-hoc so a machine without the cert still produces a runnable bundle.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: Aaron Ambrosi (2Q7MBD643R)}"

if codesign --force --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null; then
    echo "  signed as ${SIGN_IDENTITY}"
else
    echo "  (no '${SIGN_IDENTITY}' certificate — falling back to ad-hoc)"
    echo "  Keychain and Touch ID will re-prompt after every build."
    codesign --force --sign - "$APP" 2>/dev/null || echo "  (ad-hoc signing skipped)"
fi

echo
echo "Built ${APP}"
echo
echo "Run it:    open ${APP}"
echo "With logs: ${APP}/Contents/MacOS/${EXECUTABLE}"
