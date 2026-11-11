#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
# Internal baseline until the first public version is chosen.
CACHE="${AGENTPET_BUILD_CACHE:-$HOME/Library/Caches/agentpet-lite-build}"
APP_NAME="${AGENTPET_APP_NAME:-AgentPet Local}"
case "$APP_NAME" in
  'AgentPet Lite'|'AgentPet Local') ;;
  *) echo 'AGENTPET_APP_NAME must be AgentPet Lite or AgentPet Local' >&2; exit 2 ;;
esac
if [[ "$APP_NAME" == 'AgentPet Lite' ]]; then
  BUNDLE_ID='io.github.jiziol.agentpet-lite'
  APP_VERSION='1.0.0'
  BUILD_VERSION='1.0.0'
else
  BUNDLE_ID='local.acerz.agentpet'
  APP_VERSION='1.17.1-local.209'
  BUILD_VERSION='1.17.1.209'
fi
OUTPUT_APP="$ROOT/build/$APP_NAME.app"
FLAGS=(-c release --arch arm64 --disable-automatic-resolution --scratch-path "$CACHE"
       -Xswiftc -DAGENTPET_LOCAL -Xswiftc -DAGENTPET_APP_BUNDLE)
if [[ "$APP_NAME" == 'AgentPet Lite' ]]; then FLAGS+=(-Xswiftc -DAGENTPET_LITE); fi
# Keep build-machine home paths out of debug records and source-location literals.
# This changes diagnostic paths only, not the app's runtime data/Hook locations.
FLAGS+=(-Xswiftc -debug-prefix-map -Xswiftc "$HOME=/build"
        -Xswiftc -file-prefix-map -Xswiftc "$HOME=/build"
        -Xcc "-fdebug-prefix-map=$HOME=/build")
swift build "${FLAGS[@]}"
BINDIR="$(swift build "${FLAGS[@]}" --show-bin-path)"
mkdir -p "$ROOT/build"
# Assemble from an empty directory: removed resources/localizations/licenses must
# not survive from an earlier build. Never stage over an installed application.
PACKAGE_STAGE="$(mktemp -d "$ROOT/build/.agentpet-package.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
APP="$PACKAGE_STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BINDIR/agentpet" "$APP/Contents/MacOS/agentpet"
cp scripts/AppInfo.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns "$APP/Contents/Resources/"
cp -R Localizations/*.lproj "$APP/Contents/Resources/"
# Replace the generated bundle so retired resources cannot remain in the app.
rm -rf "$APP/Contents/Resources/AgentPet_agentpet.bundle"
mkdir -p "$APP/Contents/Resources/AgentPet_agentpet.bundle"
# Copy only the current resource root; SwiftPM caches can retain retired files.
ditto "$BINDIR/AgentPet_agentpet.bundle/DefaultPets" "$APP/Contents/Resources/AgentPet_agentpet.bundle/DefaultPets"
ditto "$BINDIR/AgentPet_agentpet.bundle/Icons" "$APP/Contents/Resources/AgentPet_agentpet.bundle/Icons"
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/agentpet"
# Remove linker debug records that retain absolute object-file paths.
# Keep normal symbols/runtime metadata; do this before the final signature.
strip -S "$APP/Contents/MacOS/agentpet"
# Reject generated build-cache fallbacks and per-user paths before signing.
# Debug prefix maps do not rewrite ordinary SwiftPM resource string literals.
python3 - "$APP/Contents/MacOS/agentpet" <<'PY'
from pathlib import Path
import re
import sys

data = Path(sys.argv[1]).read_bytes()
if (re.search(rb"/(?:Users|home)/[^/\x00\r\n]+/", data)
        or re.search(rb"/[^\x00\r\n]*AgentPet_agentpet\.bundle", data)):
    raise SystemExit("Refusing to package an executable containing build-machine resource paths")
PY
mkdir -p "$APP/Contents/Resources/Licenses"
# Dependency licenses can retain a read-only mode; allow repeat local builds.
chmod -R u+w "$APP/Contents/Resources/Licenses"
cp LICENSE "$APP/Contents/Resources/Licenses/AgentPet-MIT.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
cp third-party-licenses/* "$APP/Contents/Resources/Licenses/"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
if [[ -e "$OUTPUT_APP" && ! -d "$OUTPUT_APP" || -L "$OUTPUT_APP" ]]; then
  echo 'Refusing to replace an unexpected build output.' >&2; exit 1
fi
rm -rf "$OUTPUT_APP"
mv "$APP" "$OUTPUT_APP"
printf 'Built and verified: %s\n' "$OUTPUT_APP"
