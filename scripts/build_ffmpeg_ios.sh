#!/bin/zsh
# Build the minimal LGPL FFmpeg for the iOS app as dynamic-framework XCFrameworks.
#   scripts/build_ffmpeg_ios.sh          → build/ffmpeg-ios/lib{avcodec,avutil,avfilter,swresample,swscale}.xcframework
#   FORCE=1 scripts/build_ffmpeg_ios.sh  rebuild even if build/ffmpeg-ios exists
#
# Same version and component set as scripts/build_ffmpeg.sh (the macOS build), for iOS devices
# (arm64) and the iOS Simulator (arm64). The libraries stay dynamic (one .framework each, embedded
# in BonView.app/Frameworks) so they can be replaced, as the LGPL requires. Package.swift picks the
# XCFrameworks up as binary targets for iOS when they exist.
# As on macOS, configure gets a neutral --prefix (its command line is embedded in libavutil) and the
# install is staged with DESTDIR. The compiler is `xcrun --sdk <sdk> clang` rather than --cc/--sysroot
# paths, so no local path ends up in the frameworks (the host tools built along the way keep using the
# macOS SDK).
set -euo pipefail
cd "$(dirname "$0")/.."

# Version and checksum come from the macOS script so the two never drift apart.
FFMPEG_VERSION=$(sed -n 's/^FFMPEG_VERSION=//p' scripts/build_ffmpeg.sh)
FFMPEG_SHA256=$(sed -n 's/^FFMPEG_SHA256=//p' scripts/build_ffmpeg.sh)
MIN_IOS=17.0
LIBS=(avutil swresample swscale avcodec avfilter)

SRC_DIR=build/ffmpeg-src
OUT="$PWD/build/ffmpeg-ios"
TARBALL="$SRC_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz"

if [[ -f "$OUT/.version" && "$(<"$OUT/.version")" == "$FFMPEG_VERSION" && -z "${FORCE:-}" ]]; then
  echo "$OUT (FFmpeg $FFMPEG_VERSION for iOS, already built; FORCE=1 to rebuild)"
  exit 0
fi

mkdir -p "$SRC_DIR"
if [[ ! -f "$TARBALL" ]]; then
  echo "Downloading FFmpeg $FFMPEG_VERSION…"
  curl -fL --progress-bar -o "$TARBALL.part" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $TARBALL" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

# build_slice <sdk> <clang target triple> <platform name for Info.plist>
build_slice() {
  local sdk=$1 triple=$2 platform=$3
  local work="$SRC_DIR/ios-$sdk/ffmpeg-$FFMPEG_VERSION"
  local stage="$OUT/$sdk/stage"
  local prefix="$stage/usr/local"
  local fwdir="$OUT/$sdk/frameworks"
  rm -rf "$SRC_DIR/ios-$sdk"
  mkdir -p "$SRC_DIR/ios-$sdk" "$fwdir"
  tar xJf "$TARBALL" -C "$SRC_DIR/ios-$sdk"
  local version
  echo "Building FFmpeg $FFMPEG_VERSION for $sdk…"
  (
    cd "$work"
    ./configure \
      --prefix=/usr/local \
      --install-name-dir='@rpath' \
      --enable-cross-compile --target-os=darwin --arch=aarch64 \
      --cc="xcrun --sdk $sdk clang" \
      --enable-shared --disable-static --enable-pic \
      --disable-programs --disable-doc --disable-debug \
      --disable-autodetect --disable-network \
      --disable-avformat --disable-avdevice \
      --disable-everything \
      --enable-videotoolbox \
      --enable-decoder=mpeg2video,h264,hevc,aac,aac_latm \
      --enable-parser=mpegvideo,h264,hevc,aac,aac_latm \
      --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
      --enable-filter=buffer,buffersink,bwdif,format,scale \
      --extra-cflags="-target $triple" \
      --extra-ldflags="-target $triple" \
      >../configure.log || { tail -30 ../configure.log ffbuild/config.log >&2; exit 1; }
    make -j"$(sysctl -n hw.ncpu)" >../make.log 2>&1 || { tail -40 ../make.log >&2; exit 1; }
    make install DESTDIR="$stage" >>../make.log 2>&1
  )

  # Wrap each dylib in a framework: <lib>.framework/{<lib>, Headers/, Info.plist}, install name
  # @rpath/<lib>.framework/<lib>, and point the references between the libraries at the frameworks.
  for lib in $LIBS; do
    local name="lib$lib" fw="$fwdir/lib$lib.framework"
    mkdir -p "$fw/Headers"
    cp "$(realpath "$prefix/lib/$name.dylib")" "$fw/$name"
    cp -R "$prefix/include/$name/" "$fw/Headers/"
    install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name"
    for dep in $(otool -L "$fw/$name" | awk '/@rpath\/lib[a-z]*\.[0-9]*\.dylib/ {print $1}'); do
      local depname=${${dep#@rpath/}%%.*}
      install_name_tool -change "$dep" "@rpath/$depname.framework/$depname" "$fw/$name"
    done
    version=$(cat "$prefix/include/$name"/version*.h | sed -n "s/^#define LIB${(U)lib}_VERSION_MAJOR *//p" | head -1)
    cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>org.ffmpeg.$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$FFMPEG_VERSION</string>
  <key>CFBundleVersion</key><string>${version:-1}</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict>
</plist>
EOF
    # Sign the bundle (seals Info.plist and the headers too), ad hoc; Xcode re-signs it when embedding.
    codesign --force --sign - "$fw" 2>/dev/null || { echo "codesign failed: $fw" >&2; exit 1; }
  done
  rm -rf "$SRC_DIR/ios-$sdk"
}

build_slice iphoneos "arm64-apple-ios$MIN_IOS" iPhoneOS
build_slice iphonesimulator "arm64-apple-ios$MIN_IOS-simulator" iPhoneSimulator

for lib in $LIBS; do
  xcodebuild -create-xcframework \
    -framework "$OUT/iphoneos/frameworks/lib$lib.framework" \
    -framework "$OUT/iphonesimulator/frameworks/lib$lib.framework" \
    -output "$OUT/lib$lib.xcframework" >/dev/null
done

# License texts, bundled into the app as FFmpeg/ (shown on its licence screen).
mkdir -p "$OUT/FFmpeg"
tar xJf "$TARBALL" -C "$OUT/FFmpeg" --strip-components=1 \
  "ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "ffmpeg-$FFMPEG_VERSION/LICENSE.md"
rm -rf "$OUT/iphoneos" "$OUT/iphonesimulator"
echo "$FFMPEG_VERSION" > "$OUT/.version"
echo "$OUT (FFmpeg $FFMPEG_VERSION for iOS)"
