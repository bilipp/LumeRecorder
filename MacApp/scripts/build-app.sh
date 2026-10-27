#!/usr/bin/env bash
# Builds LumeRecorder.app (universal, bundled ffmpeg) and a drag-to-Applications
# LumeRecorder-<version>.dmg in MacApp/dist/.
#
#   FFMPEG_BINARY=/path/to/ffmpeg          bundle this ffmpeg instead of building
#                                          one with scripts/build-ffmpeg.sh
#   SIGN_IDENTITY="Developer ID Application: …"   sign with hardened runtime
#                                          (default: ad-hoc, runs only on this Mac
#                                          unless the user clears quarantine)
#   NOTARY_PROFILE=name                    notarize + staple app and DMG (xcrun
#                                          notarytool store-credentials name …)
#   NOTARY_KEY_PATH=AuthKey.p8 NOTARY_KEY_ID=… NOTARY_ISSUER_ID=…
#                                          notarize with an App Store Connect API key
#                                          instead of a profile (CI)
#   BUNDLE_ID=com.example.lumerecorder     override the bundle identifier
#   ARCHS="arm64 x86_64"                   architectures to build
set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd)"
dist="$root/dist"
app="$dist/LumeRecorder.app"
bundle_id="${BUNDLE_ID:-com.bilipp.lumerecorder}"
archs="${ARCHS:-arm64 x86_64}"
export ARCHS="$archs"
version="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' ../Sources/RecorderCore/RecorderConfig.swift)"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
dmg="$dist/LumeRecorder-$version.dmg"

arch_flags=()
for arch in $archs; do arch_flags+=(--arch "$arch"); done

echo "==> Building LumeRecorder $version ($build_number) for $archs"
swift build -c release --product LumeRecorderApp "${arch_flags[@]}"
bin_dir="$(swift build -c release --product LumeRecorderApp "${arch_flags[@]}" --show-bin-path)"

if [[ -n "${FFMPEG_BINARY:-}" ]]; then
    ffmpeg_binary="$FFMPEG_BINARY"
    ffmpeg_notes=""
else
    scripts/build-ffmpeg.sh
    ffmpeg_dir="$(ls -d "$root"/.build/ffmpeg-* | grep -v '\.tar' | sort -V | tail -1)"
    ffmpeg_binary="$ffmpeg_dir/ffmpeg"
    ffmpeg_notes="$ffmpeg_dir"
fi
if otool -L "$ffmpeg_binary" | grep -E '^\s' | grep -qvE '^\s+(/usr/lib/|/System/)'; then
    echo "error: $ffmpeg_binary links libraries outside the OS (a Homebrew build?); use a static build" >&2
    exit 1
fi

echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/LumeRecorderApp" "$app/Contents/MacOS/LumeRecorder"
cp "$ffmpeg_binary" "$app/Contents/MacOS/ffmpeg"
chmod 755 "$app/Contents/MacOS/ffmpeg"
if [[ -n "$ffmpeg_notes" ]]; then
    mkdir -p "$app/Contents/Resources/FFmpeg"
    cp "$ffmpeg_notes/LICENSE.txt" "$ffmpeg_notes/README.txt" "$app/Contents/Resources/FFmpeg/"
fi
sed -e "s/__BUNDLE_ID__/$bundle_id/" -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build_number/" \
    Resources/Info.plist > "$app/Contents/Info.plist"
# Icon Composer icon → Assets.car (macOS 26) + AppIcon.icns (older macOS).
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" \
    --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon \
    --output-partial-info-plist "$root/.build/AppIcon-partial.plist" > /dev/null
# Dependency resource bundles (privacy manifests).
find "$bin_dir" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$app/Contents/Resources/" \;

identity="${SIGN_IDENTITY:--}"
sign_flags=(--force --timestamp=none --sign "$identity")
if [[ "$identity" != "-" ]]; then sign_flags=(--force --timestamp --options runtime --sign "$identity"); fi
echo "==> Signing (${identity})"
codesign "${sign_flags[@]}" "$app/Contents/MacOS/ffmpeg"
find "$app/Contents/Resources" -maxdepth 1 -name '*.bundle' -exec codesign "${sign_flags[@]}" {} \;
codesign "${sign_flags[@]}" "$app"
codesign --verify --strict --deep "$app"

notary_auth=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notary_auth=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    notary_auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi
notarize() {
    xcrun notarytool submit "$1" "${notary_auth[@]}" --wait --timeout 30m
}
if [[ ${#notary_auth[@]} -gt 0 ]]; then
    [[ "$identity" != "-" ]] || { echo "error: notarization needs SIGN_IDENTITY" >&2; exit 1; }
    # Staple the app itself too, so a copy dragged out of the DMG opens offline.
    echo "==> Notarizing the app"
    zip="$root/.build/LumeRecorder-notarize.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    notarize "$zip"
    rm -f "$zip"
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi

echo "==> Creating $dmg"
venv="$root/.build/dmgbuild-venv"
if [[ ! -x "$venv/bin/dmgbuild" ]]; then
    python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==1.6.7"
fi
rm -f "$dmg"
"$venv/bin/dmgbuild" -s Resources/dmg-settings.py -D app="$app" \
    -D icon="$app/Contents/Resources/AppIcon.icns" "LumeRecorder" "$dmg"

if [[ "$identity" != "-" ]]; then
    codesign --force --timestamp --sign "$identity" "$dmg"
fi
if [[ ${#notary_auth[@]} -gt 0 ]]; then
    echo "==> Notarizing the DMG"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

echo "==> Done: $app"
echo "    $dmg"
