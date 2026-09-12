#!/bin/zsh
# Full distribution build: sign → notarize+staple the APP → package →
# sign+notarize+staple the DMG → verify.
#
# Two notarization passes on purpose. Stapling the app itself is what makes
# it launch offline (or when Apple's servers are slow) after a tester drags
# it out of the disk image; a ticket on the DMG alone leaves the extracted
# app depending on an online lookup.
#
# One-time setup:
#   xcrun notarytool store-credentials portside \
#     --apple-id <apple-id> --team-id <team-id>
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-portside}"
VERSION=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/Portside/Version.swift)
APP="dist/Portside.app"
DMG="dist/Portside-${VERSION}.dmg"
ZIP="dist/Portside-${VERSION}.zip"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
	echo "ERROR: no notarytool credentials for profile '${PROFILE}'."
	echo "Run: xcrun notarytool store-credentials ${PROFILE} \\"
	echo "       --apple-id <your-apple-id> --team-id <your-team-id>"
	exit 1
fi

# Any older disk image must go: a stale artifact sitting beside the real one
# is the easiest possible way to hand someone the wrong build.
rm -f dist/*.dmg(N)

./build-app.sh

# Captured to a variable, not piped: `cmd | grep -q` under pipefail reports
# failure when grep exits early and the producer takes SIGPIPE.
SIGNATURE=$(codesign -dv "$APP" 2>&1 || true)
if [[ "$SIGNATURE" != *"TeamIdentifier="* || "$SIGNATURE" == *"TeamIdentifier=not set"* ]]; then
	echo "ERROR: app is ad-hoc signed — notarization requires a Developer ID."
	exit 1
fi

# Same team pin as build-app.sh: the disk image must be signed by the
# identity that signed the app inside it, not whichever cert is listed first.
TEAM_ID="6GG3WY94W2"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
	| sed -n "s/.*\"\(Developer ID Application:.*(${TEAM_ID})\)\".*/\1/p" | sed -n '1p')
[[ -n "$IDENTITY" ]] || { echo "ERROR: no Developer ID for team ${TEAM_ID}"; exit 1; }

# On rejection, notarytool exits non-zero with no reason — fetch the log,
# which names the exact offending binary and cause.
notarize() {
	local target="$1"
	local submission
	submission=$(xcrun notarytool submit "$target" --keychain-profile "$PROFILE" \
		--wait --output-format json) || true
	local verdict submission_id
	verdict=$(printf '%s' "$submission" | /usr/bin/python3 -c \
		'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
	submission_id=$(printf '%s' "$submission" | /usr/bin/python3 -c \
		'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
	if [[ "$verdict" != "Accepted" ]]; then
		echo "ERROR: notarization ${verdict:-failed} for ${target}"
		if [[ -n "$submission_id" ]]; then
			xcrun notarytool log "$submission_id" --keychain-profile "$PROFILE" || true
		fi
		exit 1
	fi
	echo "Notarized: ${target}"
}

echo "==> Notarizing the app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "==> Packaging ${DMG}"
rm -rf dist/dmg "$DMG"
mkdir -p dist/dmg
ditto "$APP" dist/dmg/Portside.app
ln -s /Applications dist/dmg/Applications
hdiutil create -volname Portside -srcfolder dist/dmg -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/dmg

# Sign the disk image too, so it carries its own verifiable identity.
codesign --force --timestamp -s "${IDENTITY}" "$DMG"

echo "==> Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> Verifying"
FAILED=0
check() {
	local label="$1"; shift
	local output
	if output=$("$@" 2>&1); then
		printf '  ok  %s\n' "$label"
	else
		printf '  FAIL %s\n%s\n' "$label" "$output"
		FAILED=1
	fi
}

check "disk image ticket" xcrun stapler validate "$DMG"
check "disk image signature" spctl -a -t open \
	--context context:primary-signature "$DMG"

MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
check "app accepted by Gatekeeper" spctl -a "$MOUNT/Portside.app"
check "app ticket stapled (offline launch)" \
	xcrun stapler validate "$MOUNT/Portside.app"
spctl -a -vvv "$MOUNT/Portside.app" 2>&1 | grep -E "source=|origin=" || true
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT" 2>/dev/null || true

if [[ "$FAILED" != "0" ]]; then
	echo
	echo "ERROR: the artifact failed verification — do NOT distribute it."
	exit 1
fi

echo
echo "Release ready: ${DMG} ($(du -h "$DMG" | cut -f1))"
