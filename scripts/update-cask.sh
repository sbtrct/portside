#!/bin/zsh
# Point the Homebrew cask at the current version's DMG. Run after
# `make release` and after the GitHub release exists.
set -euo pipefail
cd "$(dirname "$0")/.."

TAP="${TAP_DIR:-../homebrew-tap}"
VERSION=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/Portside/Version.swift)
DMG="dist/Portside-${VERSION}.dmg"

[[ -f "$DMG" ]] || { echo "ERROR: $DMG not built"; exit 1; }
[[ -d "$TAP/Casks" ]] || { echo "ERROR: tap not found at $TAP"; exit 1; }

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

# The cask points at the GitHub asset, so hash THAT, and refuse to publish if
# it differs from the local file — a rebuild after upload would otherwise ship
# a cask whose checksum fails for every user.
ASSET="https://github.com/sbtrct/portside/releases/download/v${VERSION}/Portside-${VERSION}.dmg"
REMOTE_SHA=$(curl -sL "$ASSET" | shasum -a 256 | cut -d' ' -f1)
if [[ "$REMOTE_SHA" != "$SHA" ]]; then
	echo "ERROR: uploaded asset differs from local ${DMG}"
	echo "  local:  ${SHA}"
	echo "  remote: ${REMOTE_SHA}"
	echo "Re-upload the DMG (gh release upload v${VERSION} ${DMG} --clobber) first."
	exit 1
fi
sed -i '' \
	-e "s/^  version \".*\"/  version \"${VERSION}\"/" \
	-e "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" \
	"$TAP/Casks/portside.rb"

cd "$TAP"
git add Casks/portside.rb
git commit -q -m "portside ${VERSION}"
git push origin main
echo "cask → ${VERSION} (${SHA})"
