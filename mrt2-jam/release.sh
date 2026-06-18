#!/bin/bash
# Build, Developer-ID sign, notarize and staple VerveFlow into a distributable
# DMG. Requires:
#   - A "Developer ID Application" certificate + private key in the keychain.
#   - A notarytool keychain profile (default: notarytool-creds) created once via:
#       xcrun notarytool store-credentials notarytool-creds \
#         --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-pw>
#
# Usage:  mrt2-jam/release.sh
set -euo pipefail

# ── Config (override via env) ────────────────────────────────────────────────
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: CHUNYU YIN (83HFUV53VA)}"
NOTARY_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-notarytool-creds}"
APP_NAME="VerveFlow"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO/build"
CMAKE="$REPO/.venv/bin/cmake"
APP_SRC="$BUILD/mrt2-jam/mrt2_jam.app"      # built bundle (target name)
ENTITLEMENTS="$REPO/mrt2-jam/JamEntitlements.plist"

STAGE="$BUILD/dmg_stage"
APP_OUT="$STAGE/$APP_NAME.app"
DMG="$BUILD/$APP_NAME.dmg"

echo "▸ Signing identity: $IDENTITY"

# ── 1. Configure with the Developer ID + build (deploy signs with hardened
#       runtime + secure timestamp via CODESIGN_FLAGS) ─────────────────────────
"$CMAKE" -S "$REPO" -B "$BUILD" -DCODESIGN_IDENTITY="$IDENTITY" >/dev/null
"$CMAKE" --build "$BUILD" --target deploy_mrt2_jam -j 8

# ── 2. Stage VerveFlow.app + an /Applications drop target ─────────────────────
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP_SRC" "$APP_OUT"           # rename wrapper to VerveFlow.app (sig stays valid)
ln -s /Applications "$STAGE/Applications"

# Re-sign the outer bundle for good measure (deep, hardened runtime) and verify.
codesign --force --options=runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --generate-entitlement-der \
    --sign "$IDENTITY" "$APP_OUT"
codesign --verify --deep --strict --verbose=2 "$APP_OUT"

# ── 3. Build the DMG ─────────────────────────────────────────────────────────
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "$DMG"

# ── 4. Sign + notarize + staple the DMG ──────────────────────────────────────
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "▸ Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

rm -rf "$STAGE"
echo "✓ Done → $DMG"
echo "  Verify on a clean Mac: spctl -a -vv -t open --context context:primary-signature \"$DMG\""
