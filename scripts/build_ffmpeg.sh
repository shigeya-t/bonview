#!/bin/zsh
# Build the minimal LGPL FFmpeg that BonView bundles into BonView.app.
#   scripts/build_ffmpeg.sh            → build/ffmpeg/{include,lib}  (host architecture)
#   FORCE=1 scripts/build_ffmpeg.sh    rebuild even if build/ffmpeg exists
#
# Only what Sources/CFFmpeg/tvffmpeg.c uses is enabled: the MPEG-2 / H.264 / HEVC / AAC (ADTS, LATM)
# decoders and parsers, VideoToolbox, the buffer / buffersink / bwdif filters, swresample and swscale.
# --disable-autodetect keeps it from picking up Homebrew libraries, so the result depends only on
# system frameworks. Dylibs get `@rpath/…` install names; bundle.sh copies them to Contents/Frameworks.
# No GPL or nonfree parts are enabled, so the libraries stay LGPL 2.1+.
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
MIN_MACOS=14.0

SRC_DIR=build/ffmpeg-src
PREFIX="$PWD/build/ffmpeg"
TARBALL="$SRC_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz"

if [[ -f "$PREFIX/.version" && "$(<"$PREFIX/.version")" == "$FFMPEG_VERSION" && -z "${FORCE:-}" ]]; then
  echo "$PREFIX (FFmpeg $FFMPEG_VERSION, already built; FORCE=1 to rebuild)"
  exit 0
fi

mkdir -p "$SRC_DIR"
if [[ ! -f "$TARBALL" ]]; then
  echo "Downloading FFmpeg $FFMPEG_VERSION…"
  curl -fL --progress-bar -o "$TARBALL.part" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $TARBALL" >&2; exit 1; }

WORK="$SRC_DIR/ffmpeg-$FFMPEG_VERSION"
rm -rf "$WORK" "$PREFIX"
tar xJf "$TARBALL" -C "$SRC_DIR"

ASM=()
[[ "$(uname -m)" == x86_64 ]] && ! command -v nasm >/dev/null && ASM=(--disable-x86asm)

(
  cd "$WORK"
  ./configure \
    --prefix="$PREFIX" \
    --install-name-dir='@rpath' \
    --enable-shared --disable-static \
    --disable-programs --disable-doc --disable-debug \
    --disable-autodetect --disable-network \
    --disable-avformat --disable-avdevice \
    --disable-everything \
    --enable-videotoolbox \
    --enable-decoder=mpeg2video,h264,hevc,aac,aac_latm \
    --enable-parser=mpegvideo,h264,hevc,aac,aac_latm \
    --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
    --enable-filter=buffer,buffersink,bwdif,format,scale \
    --extra-cflags="-mmacosx-version-min=$MIN_MACOS" \
    --extra-ldflags="-mmacosx-version-min=$MIN_MACOS" \
    "${ASM[@]}" \
    >../configure.log || { tail -30 ../configure.log ffbuild/config.log >&2; exit 1; }
  make -j"$(sysctl -n hw.ncpu)" >../make.log 2>&1 || { tail -40 ../make.log >&2; exit 1; }
  make install >>../make.log 2>&1
)

# License texts for the app bundle (LGPL: the user may replace these dylibs).
mkdir -p "$PREFIX/share/licenses"
cp "$WORK/COPYING.LGPLv2.1" "$WORK/LICENSE.md" "$PREFIX/share/licenses/"
echo "$FFMPEG_VERSION" > "$PREFIX/.version"
rm -rf "$WORK"
echo "$PREFIX (FFmpeg $FFMPEG_VERSION)"
