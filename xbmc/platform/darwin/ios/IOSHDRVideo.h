/*
 *  Copyright (C) 2026 Team Kodi
 *  SPDX-License-Identifier: GPL-2.0-or-later
 */

#pragma once

#include <CoreGraphics/CGGeometry.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <array>
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
CVPixelBufferRef IOSCompositeVideo(CVPixelBufferRef video, const IOSSubtitleBitmap& subtitles);

void IOSDeleteVideoTexture(unsigned int texture);
void IOSDrainVideoTextures();
