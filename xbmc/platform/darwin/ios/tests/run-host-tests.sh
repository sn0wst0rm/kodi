#!/bin/sh
set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS_DIR=$(dirname "$TEST_DIR")
TEST_OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/kodi-ios-pip-tests.XXXXXX")
trap 'rm -rf "$TEST_OUTPUT"' EXIT
xcrun --sdk macosx clang++ -O2 -std=c++17 -I "$IOS_DIR" \
  "$TEST_DIR/PlaybackPolicy.cpp" -o "$TEST_OUTPUT/playback-policy"
"$TEST_OUTPUT/playback-policy"
xcrun --sdk macosx clang++ -O2 -std=c++17 -I "$IOS_DIR" \
  "$TEST_DIR/HDRHeadroom.cpp" -o "$TEST_OUTPUT/hdr-headroom"
"$TEST_OUTPUT/hdr-headroom"
xcrun --sdk macosx clang++ -O2 -std=c++17 -fobjc-arc -I "$IOS_DIR" \
  "$TEST_DIR/NativeVideoCompositor.mm" "$IOS_DIR/IOSVideoCompositor.mm" \
  -framework Foundation -framework Accelerate -framework CoreVideo -framework CoreGraphics \
  -o "$TEST_OUTPUT/native-video-compositor"
"$TEST_OUTPUT/native-video-compositor"
"$TEST_OUTPUT/native-video-compositor" benchmark-4k
xcrun --sdk macosx clang++ -O2 -std=c++17 -fobjc-arc -I "$IOS_DIR" \
  "$TEST_DIR/VideoToneMap.mm" "$IOS_DIR/IOSVideoToneMap.mm" \
  -framework Foundation -framework VideoToolbox -framework CoreVideo -framework CoreGraphics \
  -o "$TEST_OUTPUT/video-tone-map"
"$TEST_OUTPUT/video-tone-map"
"$TEST_OUTPUT/video-tone-map" benchmark-4k
