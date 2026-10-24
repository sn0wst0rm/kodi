/*
 *  Copyright (C) 2026 Team Kodi
 *  SPDX-License-Identifier: GPL-2.0-or-later
 */

#pragma once

#include <CoreGraphics/CGGeometry.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <array>
#include <algorithm>
#include <cstdint>
#include <memory>
#include <vector>

struct IOSSubtitleBitmap
{
  int width{0};
  int height{0};
  std::vector<uint8_t> rgba; // premultiplied RGBA, top row first
};

struct IOSHDRVideoMetadata
{
  int primaries{0};
  int transfer{0};
  int matrix{0};
  bool hasMastering{false};
  bool hasLight{false};
  std::array<uint8_t, 24> mastering{};
  std::array<uint8_t, 4> light{};
};

inline double IOSHDRContentHeadroom(const IOSHDRVideoMetadata& metadata)
{
  // CTA-861.3 MaxCLL is uint16 big-endian nits. ST 2086 maximum luminance
  // is uint32 big-endian in 0.0001 nits at byte16 (after primaries/white point).
  // Prefer the actual content peak over the mastering monitor's capability.
  double peak = metadata.hasLight ? (uint16_t(metadata.light[0]) << 8 | metadata.light[1]) : 0;
  if (peak <= 0 && metadata.hasMastering)
    peak = ((uint32_t(metadata.mastering[16]) << 24) |
            (uint32_t(metadata.mastering[17]) << 16) |
            (uint32_t(metadata.mastering[18]) << 8) | metadata.mastering[19]) / 10000.0;
  if (peak <= 0) peak = 1000.0; // conservative PQ/HLG fallback without metadata
  // Native Apple PQ video maps 100 nit reference white to EDR 1.0.
  // 203 nits is HDR diffuse white, not the reference of this video pipeline.
  return std::clamp(peak / 100.0, 1.0, 100.0);
}

// Only decoded, IOSurface-backed buffers are passed to AVFoundation. Kodi
// remains responsible for decode, audio synchronisation and frame scheduling.
bool IOSSupportsHDRVideo();
bool IOSIsTenBitVideo(CVPixelBufferRef buffer);
uint64_t IOSBeginHDRVideo();
void IOSPresentHDRVideo(uint64_t session, CVPixelBufferRef buffer,
                        const IOSHDRVideoMetadata& metadata, CGRect source, CGRect destination,
                        unsigned int orientation,
                        std::shared_ptr<IOSSubtitleBitmap> subtitles = {});
void IOSEndHDRVideo(uint64_t session);
bool IOSIsPictureInPictureActive();
bool IOSNativeVideoRenderingActive();
uint64_t IOSNativeVideoEnqueuedFrames();
// Called on Kodi's render thread after processing controls/subtitles. UIKit
// applies only transitions; touch delivery remains attached to the GL view.
void IOSSetNativeVideoOnly(bool videoOnly);
CVPixelBufferRef IOSCompositeVideo(CVPixelBufferRef video, const IOSSubtitleBitmap& subtitles);
// Returns an owned, 10-bit BT.709 surface, or nullptr with a VideoToolbox error.
// Calls must be serialised on the native-video delivery queue.
CVPixelBufferRef IOSConvertVideoToSDR(CVPixelBufferRef video, int32_t* error);

void IOSDeleteVideoTexture(unsigned int texture);
void IOSDrainVideoTextures();
