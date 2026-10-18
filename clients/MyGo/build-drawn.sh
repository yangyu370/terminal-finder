#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$base"
# This branch packages the self-drawn client only; no nativefinder experiment.
if [ ! -x .tools/go/bin/go ] || [ ! -f .cache/natives/libghostty-vt.dylib ]; then
    ./bootstrap.sh
fi
if [ -n "${TF_CORE_BINARY:-}" ]; then
    core_binary=$TF_CORE_BINARY
    test -x "$core_binary"
else
    ./build-core.sh
    core_binary="$base/.cache/rust-target/debug/core"
fi
app="$base/dist/Terminal Finder Drawn.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
./go-local build -trimpath -ldflags '-s -w' -o "$app/Contents/MacOS/terminal-finder-drawn" ./cmd/terminal-finder-drawn
cp "$core_binary" "$app/Contents/Resources/terminal-finder-core"
cp .cache/natives/libghostty-vt.dylib "$app/Contents/Resources/libghostty-vt.dylib"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>terminal-finder-drawn</string>
<key>CFBundleIdentifier</key><string>dev.terminalfinder.mygo.drawn</string>
<key>CFBundleName</key><string>Terminal Finder Drawn</string>
<key>CFBundleDisplayName</key><string>Terminal Finder Drawn</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
