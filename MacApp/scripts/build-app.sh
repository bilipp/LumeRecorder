#!/usr/bin/env bash
# Builds LumeRecorder.app (universal) and a zip next to it in MacApp/dist/.
#
#   FFMPEG_BINARY=/path/to/static/ffmpeg   bundle this ffmpeg (Contents/MacOS/ffmpeg);
#                                          without it the app falls back to Homebrew's
#   SIGN_IDENTITY="Developer ID Application: …"   sign with hardened runtime
#                                          (default: ad-hoc, runs only on this Mac
#                                          unless the user clears quarantine)
#   NOTARY_PROFILE=name                    notarize + staple (xcrun notarytool
#                                          store-credentials name …); needs SIGN_IDENTITY
#   BUNDLE_ID=com.example.lumerecorder     override the bundle identifier
#   ARCHS="arm64 x86_64"                   architectures to build
set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd)"
dist="$root/dist"
app="$dist/LumeRecorder.app"
bundle_id="${BUNDLE_ID:-com.bilipp.lumerecorder}"
archs="${ARCHS:-arm64 x86_64}"
version="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' ../Sources/RecorderCore/RecorderConfig.swift)"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

arch_flags=()
for arch in $archs; do arch_flags+=(--arch "$arch"); done

echo "==> Building LumeRecorder $version ($build_number) for $archs"
swift build -c release --product LumeRecorderApp "${arch_flags[@]}"
bin_dir="$(swift build -c release --product LumeRecorderApp "${arch_flags[@]}" --show-bin-path)"

echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/LumeRecorderApp" "$app/Contents/MacOS/LumeRecorder"
sed -e "s/__BUNDLE_ID__/$bundle_id/" -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build_number/" \
    Resources/Info.plist > "$app/Contents/Info.plist"
# Dependency resource bundles (privacy manifests).
find "$bin_dir" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$app/Contents/Resources/" \;

if [[ -n "${FFMPEG_BINARY:-}" ]]; then
    echo "==> Bundling ffmpeg from $FFMPEG_BINARY"
    if otool -L "$FFMPEG_BINARY" | tail -n +2 | grep -qvE '^\s+(/usr/lib/|/System/)'; then
        echo "error: $FFMPEG_BINARY links libraries outside the OS (a Homebrew build?); use a static build" >&2
        exit 1
    fi
    cp "$FFMPEG_BINARY" "$app/Contents/MacOS/ffmpeg"
    chmod 755 "$app/Contents/MacOS/ffmpeg"
fi

identity="${SIGN_IDENTITY:--}"
sign_flags=(--force --timestamp=none --sign "$identity")
if [[ "$identity" != "-" ]]; then sign_flags=(--force --timestamp --options runtime --sign "$identity"); fi
echo "==> Signing (${identity})"
if [[ -f "$app/Contents/MacOS/ffmpeg" ]]; then codesign "${sign_flags[@]}" "$app/Contents/MacOS/ffmpeg"; fi
find "$app/Contents/Resources" -maxdepth 1 -name '*.bundle' -exec codesign "${sign_flags[@]}" {} \;
codesign "${sign_flags[@]}" "$app"
codesign --verify --strict --deep "$app"

zip="$dist/LumeRecorder-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ "$identity" != "-" ]] || { echo "error: notarization needs SIGN_IDENTITY" >&2; exit 1; }
    echo "==> Notarizing"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
fi

echo "==> Done: $app"
echo "    $zip"
