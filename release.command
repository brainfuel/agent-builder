#!/bin/bash
# =============================================================================
#  release.command — Agent Builder one-button release script
#  Double-click this file in Finder, or run: bash release.command
# =============================================================================
set -euo pipefail

# ── Resolve project root (works whether double-clicked or run from terminal) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Config ────────────────────────────────────────────────────────────────────
SCHEME="Agentic"
PROJECT="Agentic.xcodeproj"
APP_NAME="Agent Builder"             # CFBundleName — what the .app is called inside the archive
BUILD_DIR="build"
DIST_DIR="dist"
ENTITLEMENTS_SRC="Agentic/Agentic.entitlements"

# Signing identity and notarisation profile.
# Forks: override via environment variables, e.g.
#   DEVELOPER_ID="Developer ID Application: Your Org (ABCDE12345)" \
#   NOTARY_PROFILE="notary-your-app" \
#   TEAM_ID="ABCDE12345" \
#   bash release.command
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Moosia LLC (NC83U5R385)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-agent-builder}"
TEAM_ID="${TEAM_ID:-NC83U5R385}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step()  { echo -e "\n${CYAN}▶ $*${NC}"; }
ok()    { echo -e "${GREEN}✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $*${NC}"; }
die()   { echo -e "${RED}✗ $*${NC}"; exit 1; }

# ── Preflight checks ──────────────────────────────────────────────────────────
step "Preflight checks"
command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode."
command -v gh         >/dev/null || die "'gh' not found — install: brew install gh"
command -v hdiutil    >/dev/null || die "hdiutil not found (unexpected on macOS)."
command -v codesign   >/dev/null || die "codesign not found."
command -v xcrun      >/dev/null || die "xcrun not found."

security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID" \
    || die "Developer ID cert not in keychain: '${DEVELOPER_ID}'"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "Notary profile '${NOTARY_PROFILE}' not set up. Run: xcrun notarytool store-credentials '${NOTARY_PROFILE}' --apple-id <you@example.com> --team-id ${TEAM_ID}"

git diff --quiet || warn "You have uncommitted changes — they won't be included in the archive."
ok "Tools & signing identity found"

# ── Determine next version ────────────────────────────────────────────────────
step "Calculating next version"
LATEST_TAG=$(git tag --sort=-version:refname | grep '^v[0-9]' | head -1 || true)
if [[ -z "$LATEST_TAG" ]]; then
    LATEST_TAG="v1.0.0"
    warn "No existing tags found — starting from v1.0.0"
fi

BASE_VERSION="${LATEST_TAG#v}"          # strip leading 'v'
IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE_VERSION"
PATCH=$((PATCH + 1))
NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
NEW_TAG="v${NEW_VERSION}"

echo "  Previous tag : ${LATEST_TAG}"
echo "  New version  : ${NEW_VERSION} (${NEW_TAG})"

# Confirm before proceeding
echo ""
read -r -p "  Proceed with release ${NEW_TAG}? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Bump version in Xcode project ─────────────────────────────────────────────
step "Bumping MARKETING_VERSION → ${NEW_VERSION}"
PBXPROJ="${PROJECT}/project.pbxproj"
sed -i '' "s/MARKETING_VERSION = [0-9][0-9.]*;/MARKETING_VERSION = ${NEW_VERSION};/g" "$PBXPROJ"
grep -q "MARKETING_VERSION = ${NEW_VERSION};" "$PBXPROJ" || die "Version bump failed — check ${PBXPROJ}"
ok "Version bumped"

# ── Archive (Mac Catalyst) ────────────────────────────────────────────────────
step "Archiving (this takes a minute…)"
ARCHIVE_PATH="${BUILD_DIR}/Agent-Builder.xcarchive"
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
    -project        "$PROJECT" \
    -scheme         "$SCHEME" \
    -configuration  Release \
    -destination    "generic/platform=macOS,variant=Mac Catalyst" \
    -archivePath    "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic \
    -quiet
ok "Archive created at ${ARCHIVE_PATH}"

# ── Extract app from archive ──────────────────────────────────────────────────
step "Extracting app from archive"
ARCHIVE_APP="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
[[ -d "$ARCHIVE_APP" ]] || die ".app not found inside archive at ${ARCHIVE_APP}"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
rm -rf "$APP_PATH"
ditto "$ARCHIVE_APP" "$APP_PATH"
ok "App extracted to ${APP_PATH}"

# ── Re-sign with Developer ID + hardened runtime ─────────────────────────────
step "Re-signing app with Developer ID"
DIST_ENTITLEMENTS="${BUILD_DIR}/Distribution.entitlements"
cp "$ENTITLEMENTS_SRC" "$DIST_ENTITLEMENTS"

# Strip entitlements that require App Store / TestFlight provisioning profiles.
# Developer ID distribution cannot carry these without rejection at notarization.
/usr/libexec/PlistBuddy -c "Delete :aps-environment"                              "$DIST_ENTITLEMENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.aps-environment"          "$DIST_ENTITLEMENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.icloud-container-identifiers" "$DIST_ENTITLEMENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.icloud-services"          "$DIST_ENTITLEMENTS" 2>/dev/null || true

# Sign nested frameworks/dylibs first (deepest inside-out order).
while IFS= read -r -d '' item; do
    codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$item" >/dev/null
done < <(find "$APP_PATH/Contents" \( -name "*.dylib" -o -name "*.framework" \) -print0)

# Then the app bundle itself with entitlements.
codesign --force --timestamp --options runtime \
    --entitlements "$DIST_ENTITLEMENTS" \
    --sign "$DEVELOPER_ID" \
    "$APP_PATH"

codesign --verify --strict --verbose=1 "$APP_PATH" >/dev/null
ok "App signed with Developer ID"

# ── Create DMG ────────────────────────────────────────────────────────────────
step "Creating DMG"
mkdir -p "$DIST_DIR"
DMG_NAME="Agent-Builder_${NEW_VERSION}_macOS_arm64.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
rm -f "$DMG_PATH"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "$APP_PATH" \
    -ov \
    -format UDZO \
    -o "$DMG_PATH" > /dev/null
ok "DMG created: ${DMG_NAME}"

# ── Sign, notarize & staple DMG ──────────────────────────────────────────────
step "Signing DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG_PATH"
ok "DMG signed"

step "Notarizing DMG with Apple (usually 1-5 min)"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
ok "Notarization accepted"

step "Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
ok "DMG stapled & validated — Gatekeeper will trust it offline"

# ── SHA256 checksum ───────────────────────────────────────────────────────────
step "Generating SHA256 checksum"
SHA_NAME="Agent-Builder_${NEW_VERSION}_SHA256SUMS.txt"
SHA_PATH="${DIST_DIR}/${SHA_NAME}"
shasum -a 256 "$DMG_PATH" | awk -v name="$DMG_NAME" '{print $1 "  " name}' > "$SHA_PATH"
ok "Checksum: $(cat "$SHA_PATH")"

# ── Commit version bump ───────────────────────────────────────────────────────
step "Committing version bump"
git add "${PROJECT}/project.pbxproj"
if git diff --cached --quiet; then
    warn "project.pbxproj already at ${NEW_VERSION} (previous partial run?) — skipping commit."
else
    git commit -m "Bump version to ${NEW_VERSION}

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
    ok "Committed"
fi

# ── Tag & push ────────────────────────────────────────────────────────────────
step "Tagging and pushing"
if git rev-parse "$NEW_TAG" >/dev/null 2>&1; then
    warn "Tag ${NEW_TAG} already exists locally — skipping tag creation."
else
    git tag "$NEW_TAG"
fi
git push origin HEAD
git push origin "$NEW_TAG"
ok "Pushed tag ${NEW_TAG} to origin"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release ${NEW_TAG}"
gh release create "$NEW_TAG" \
    "${DMG_PATH}" \
    "${SHA_PATH}" \
    --title "${APP_NAME} ${NEW_TAG}" \
    --notes "## ${APP_NAME} ${NEW_TAG}

### What's new
- Bug fixes and performance improvements

---
_Built with Xcode · Mac Catalyst · macOS arm64_"

RELEASE_URL=$(gh release view "$NEW_TAG" --json url -q .url 2>/dev/null || echo "(see GitHub)")
ok "GitHub release live: ${RELEASE_URL}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅  ${APP_NAME} ${NEW_TAG} released!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
