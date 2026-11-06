#!/bin/bash
set -euo pipefail

project=$(cd "$(dirname "$0")/.." && pwd)
wrapper="$project/Vendor/KinoCinemaRemux"
version=8.0.1
archive="ffmpeg-$version.tar.xz"
sha=05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
scratch=${KINO_REMUX_BUILD_ROOT:-$(mktemp -d)}
cleanup() {
  if [[ -z ${KINO_REMUX_BUILD_ROOT:-} ]]; then rm -rf "$scratch"; fi
}
trap cleanup EXIT
mkdir -p "$scratch"
cd "$scratch"
if [[ ! -f "$archive" ]]; then curl --fail --location --silent --show-error "https://ffmpeg.org/releases/$archive" -o "$archive"; fi
printf '%s  %s\n' "$sha" "$archive" | shasum -a 256 -c -
if [[ ! -d "ffmpeg-$version" ]]; then tar -xJf "$archive"; fi

cat > "$scratch/clang-wrapper.sh" <<'WRAPPER'
#!/bin/bash
exec "$KINO_CLANG" -target "$KINO_TARGET" -isysroot "$KINO_SDK" "$@"
WRAPPER
chmod +x "$scratch/clang-wrapper.sh"

build_slice() (
  local slice=$1 sdk=$2 triple=$3 platform=$4
  export KINO_CLANG KINO_TARGET KINO_SDK
  KINO_CLANG=$(xcrun --sdk "$sdk" --find clang)
  KINO_TARGET=$triple
  KINO_SDK=$(xcrun --sdk "$sdk" --show-sdk-path)
  local build="$scratch/probe-codecs-$slice"
  mkdir -p "$build"
  cd "$build"
  if [[ ! -f config.h ]]; then
    "$scratch/ffmpeg-$version/configure" \
      --arch=aarch64 --target-os=darwin --enable-cross-compile \
      --cc="$scratch/clang-wrapper.sh" --ar=/usr/bin/ar --ranlib=/usr/bin/ranlib --nm=/usr/bin/nm \
      --disable-autodetect --disable-everything --disable-programs --disable-doc \
      --disable-network --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample \
      --disable-asm --disable-debug --enable-small --enable-pic \
      --enable-protocol=file --enable-demuxer=mpegts --enable-muxer=mp4 \
      --enable-parser=h264,hevc,aac,ac3 --enable-bsf=aac_adtstoasc,extract_extradata \
      --enable-decoder=h264,hevc,aac,ac3,eac3
  fi
  make -j4 libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a
  local framework="$scratch/$slice/KinoCinemaRemux.framework"
  mkdir -p "$framework/Headers" "$framework/Modules"
  cp "$wrapper/KinoCinemaRemux.h" "$framework/Headers/"
  cat > "$framework/Modules/module.modulemap" <<'MODULE'
framework module KinoCinemaRemux {
  umbrella header "KinoCinemaRemux.h"
  export *
}
MODULE
  cat > "$framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.kinopub.preview.CinemaRemux</string>
<key>CFBundleName</key><string>KinoCinemaRemux</string>
<key>CFBundleExecutable</key><string>KinoCinemaRemux</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
<key>MinimumOSVersion</key><string>26.0</string>
</dict></plist>
PLIST
  "$scratch/clang-wrapper.sh" -dynamiclib -O2 -fvisibility=hidden -I "$scratch/ffmpeg-$version" -I "$build" \
    "$wrapper/KinoCinemaRemux.c" libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a \
    -Wl,-dead_strip -Wl,-exported_symbol,_KinoCinemaRemuxTS \
    -install_name @rpath/KinoCinemaRemux.framework/KinoCinemaRemux -o "$framework/KinoCinemaRemux"
)
build_slice device xros arm64-apple-xros26.0 XROS
build_slice simulator xrsimulator arm64-apple-xros26.0-simulator XRSimulator
product="$scratch/KinoCinemaRemux.xcframework"
if [[ -d "$product" ]]; then rm -rf "$product"; fi
xcodebuild -create-xcframework \
  -framework "$scratch/device/KinoCinemaRemux.framework" \
  -framework "$scratch/simulator/KinoCinemaRemux.framework" -output "$product"
ditto "$product" "$wrapper/KinoCinemaRemux.xcframework"
