#!/usr/bin/env bash
# Builds the ffmpeg bundled into LumeRecorder.app: universal, LGPL, no external
# libraries (TLS via SecureTransport, zlib from the OS), so the binary links
# only system libraries and runs on any Mac with macOS 15+.
#
# The recorder only stream-copies (HTTP/HLS in, HLS/MPEG-TS out), so encoders
# and devices are left out. Output: MacApp/.build/ffmpeg-<version>/ffmpeg plus
# the license and build notes copied into the app bundle.
#
#   ARCHS="arm64 x86_64"   architectures to build
set -euo pipefail

version="9.0.2"
sha256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
min_macos="15.0"

cd "$(dirname "$0")/.."
work="$(pwd)/.build/ffmpeg-$version"
archs="${ARCHS:-arm64 x86_64}"

if [[ -x "$work/ffmpeg" && "$(lipo -archs "$work/ffmpeg" | tr ' ' '\n' | sort | xargs)" == "$(echo "$archs" | tr ' ' '\n' | sort | xargs)" ]]; then
    echo "==> ffmpeg $version already built: $work/ffmpeg"
    exit 0
fi

mkdir -p "$work"
tarball="$work/ffmpeg-$version.tar.xz"
if [[ ! -f "$tarball" ]]; then
    echo "==> Downloading ffmpeg $version"
    curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$tarball.part"
    mv "$tarball.part" "$tarball"
fi
echo "$sha256  $tarball" | shasum -a 256 -c -

configure_flags=(
    --disable-gpl --disable-nonfree
    --disable-autodetect --enable-securetransport --enable-zlib
    --disable-shared --enable-static
    --disable-programs --enable-ffmpeg
    --disable-doc --disable-debug --disable-avdevice --disable-encoders --disable-x86asm
)

slices=()
for arch in $archs; do
    echo "==> Building ffmpeg $version for $arch"
    src="$work/src-$arch"
    rm -rf "$src"
    mkdir -p "$src"
    tar -xf "$tarball" -C "$src" --strip-components 1
    cross=()
    [[ "$arch" == "$(uname -m)" ]] || cross=(--enable-cross-compile --target-os=darwin)
    (
        cd "$src"
        ./configure "${configure_flags[@]}" ${cross[@]+"${cross[@]}"} --arch="$arch" \
            --cc="clang -arch $arch" \
            --extra-cflags="-mmacosx-version-min=$min_macos" \
            --extra-ldflags="-mmacosx-version-min=$min_macos" > "$work/configure-$arch.log"
        make -j"$(sysctl -n hw.ncpu)" ffmpeg > "$work/make-$arch.log" 2>&1
    )
    slices+=("$src/ffmpeg")
done

lipo -create "${slices[@]}" -output "$work/ffmpeg"
strip -x "$work/ffmpeg"

# What ships next to the binary (LGPL: license, version, how it was built, where the source is).
first_src="$work/src-${archs%% *}"
cp "$first_src/COPYING.LGPLv2.1" "$work/LICENSE.txt"
cat > "$work/README.txt" <<EOF
LumeRecorder bundles FFmpeg $version (https://ffmpeg.org), licensed under the
GNU Lesser General Public License v2.1 or later (see LICENSE.txt). It is an unmodified
build of the official source release:

  https://ffmpeg.org/releases/ffmpeg-$version.tar.xz
  SHA-256 $sha256

Configured with:
  ${configure_flags[*]}

The build script is MacApp/scripts/build-ffmpeg.sh in
https://github.com/bilipp/LumeRecorder.
EOF

rm -rf "$work"/src-*

"$work/ffmpeg" -hide_banner -version | head -1
otool -L "$work/ffmpeg"
echo "==> Done: $work/ffmpeg"
