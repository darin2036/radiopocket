#!/bin/zsh
set -eu
cd "${0:A:h}"
VERSION=$(sed -n 's/^RadioPocket \([0-9][0-9.]*\).*/\1/p' Resources/CHANGELOG.txt | head -1)
[ -n "$VERSION" ] || { echo "No version found in Resources/CHANGELOG.txt" >&2; exit 1; }
APP="${RADIOPOCKET_APP_PATH:-${PWD}/dist/RadioPocket.app}"
APP="${APP:A}"
# Replacing a live signed bundle makes macOS reject the running process's location identity.
ensure_app_is_stopped() {
    local running_pid
    while read -r running_pid; do
        if [[ "$(ps -p "$running_pid" -o comm=)" == "$APP/Contents/MacOS/RadioPocket" ]]; then
            print -u2 "RadioPocket is running from $APP. Quit it before rebuilding this bundle, or set RADIOPOCKET_APP_PATH to an isolated .work app."
            return 1
        fi
    done < <(pgrep -x RadioPocket || true)
}
ensure_app_is_stopped
# Preflight: a Swift toolchain is required (Command Line Tools are enough).
if ! xcrun --find swift >/dev/null 2>&1; then
    print -u2 "No Swift toolchain found. Install the Apple command-line tools with: xcode-select --install"
    exit 1
fi
# On-device AI uses FoundationModels macros, whose plugin ships only with full Xcode.
# If Xcode is installed but not selected, use it for this build without changing system settings.
fm_plugin() { print -r -- "$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null)/Developer/usr/lib/swift/host/plugins/libFoundationModelsMacros.dylib"; }
if [ ! -f "$(fm_plugin)" ] && [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift --version >/dev/null 2>&1; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        print "Using /Applications/Xcode.app for this build."
    fi
fi
SWIFT_FLAGS=()
if [ ! -f "$(fm_plugin)" ]; then
    print "Full Xcode not available: building without on-device AI (Discover and Moods use their non-AI fallbacks)."
    print "To include it, install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
    SWIFT_FLAGS=(-Xswiftc -DRADIOPOCKET_NO_FM_MACROS)
fi
swift build -c release "${SWIFT_FLAGS[@]}"
ensure_app_is_stopped
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RadioPocket "$APP/Contents/MacOS/RadioPocket"
ditto Resources/Skins "$APP/Contents/Resources/Skins"
cp Resources/CHANGELOG.txt "$APP/Contents/Resources/CHANGELOG.txt"
cp Resources/THIRD-PARTY.md "$APP/Contents/Resources/THIRD-PARTY.md"
cp Resources/DIRECTORY-SOURCES.md "$APP/Contents/Resources/DIRECTORY-SOURCES.md"
cp Resources/RadioPocket.icns "$APP/Contents/Resources/RadioPocket.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RadioPocket</string>
<key>CFBundleIdentifier</key><string>com.radiopocket.player</string>
<key>CFBundleIconFile</key><string>RadioPocket</string>
<key>CFBundleName</key><string>RadioPocket</string>
<key>CFBundleDisplayName</key><string>RadioPocket</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>RadioPocket Radio Link</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>CFBundleURLSchemes</key><array><string>radiopocket</string></array>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Internet Radio Playlist</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.m3u-playlist</string><string>public.pls-playlist</string></array>
<key>CFBundleTypeExtensions</key><array><string>m3u</string><string>m3u8</string><string>pls</string></array>
<key>CFBundleTypeMIMETypes</key><array><string>audio/x-mpegurl</string><string>audio/mpegurl</string><string>application/vnd.apple.mpegurl</string><string>audio/x-scpls</string></array>
</dict></array>
<key>UTImportedTypeDeclarations</key><array>
<dict><key>UTTypeIdentifier</key><string>public.m3u-playlist</string><key>UTTypeDescription</key><string>M3U Radio Playlist</string><key>UTTypeConformsTo</key><array><string>public.text</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>m3u</string><string>m3u8</string></array><key>public.mime-type</key><array><string>audio/x-mpegurl</string><string>audio/mpegurl</string><string>application/vnd.apple.mpegurl</string></array></dict></dict>
<dict><key>UTTypeIdentifier</key><string>public.pls-playlist</string><key>UTTypeDescription</key><string>PLS Radio Playlist</string><key>UTTypeConformsTo</key><array><string>public.text</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><string>pls</string><key>public.mime-type</key><string>audio/x-scpls</string></dict></dict>
</array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocationUsageDescription</key><string>Find your nearby city for weather-inspired Moods. RadioPocket saves an approximate area and uses it to request weather from Open-Meteo. Location is requested only when you choose Use my location.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Find your nearby city for weather-inspired Moods when you choose Use my location.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsForMedia</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
sed -i '' "s|<string>0.7.0</string>|<string>$VERSION</string>|" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "${APP:h}/RadioPocket-$VERSION.zip"
echo "Built $APP and ${APP:h}/RadioPocket-$VERSION.zip"
