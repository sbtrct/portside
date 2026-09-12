#!/bin/zsh
# Builds dist/Portside.app from the SPM release binary.
#
# Signs with Developer ID when a certificate is available, otherwise falls
# back to ad-hoc (fine for local dev, NOT distributable — macOS 15+ gives
# users no right-click-open escape for ad-hoc builds).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/Portside/Version.swift)
# Monotonic so macOS can always tell builds apart, even when the marketing
# version is unchanged. Wall-clock rather than a commit count: a count goes
# backwards across a history squash and collides for dirty-tree builds.
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)

# Universal binary so the same .app works on Intel and Apple Silicon.
swift build -c release --arch arm64 --arch x86_64

APP="dist/Portside.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/apple/Products/Release/Portside "$APP/Contents/MacOS/Portside"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Portside</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>design.subtract.portside</string>
	<key>CFBundleName</key>
	<string>Portside</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Thomas Drach. MIT licensed.</string>
	<key>NSDesktopFolderUsageDescription</key>
	<string>Portside reads project files (like package.json) in a server&#39;s folder to build its restart command. It never writes there.</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>Portside reads project files (like package.json) in a server&#39;s folder to build its restart command. It never writes there.</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>Portside reads project files (like package.json) in a server&#39;s folder to build its restart command. It never writes there.</string>
</dict>
</plist>
PLIST

# Prefer a real Developer ID; --timestamp is a notarization hard requirement.
# Pinned to the project's team: picking "whichever Developer ID is first"
# would silently re-key every user's TCC grants and login item if a second
# certificate ever lands in the keychain.
TEAM_ID="6GG3WY94W2"
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
IDENTITY=$(printf '%s\n' "${IDENTITIES}" \
	| sed -n "s/.*\"\(Developer ID Application:.*(${TEAM_ID})\)\".*/\1/p" \
	| sed -n '1p')

if [[ -n "${IDENTITY}" ]]; then
	codesign --force --timestamp --options runtime -s "${IDENTITY}" "$APP"
	echo "Signed: ${IDENTITY}"
else
	codesign --force --options runtime -s - "$APP"
	echo "WARNING: ad-hoc signed (no Developer ID found) — local use only."
fi

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
echo "Built $APP (${VERSION})"
