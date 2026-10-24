/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "IOSHDRVideo.h"
#include <CoreVideo/CVPixelBufferPool.h>
#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cmath>
#include <unordered_map>

namespace
{
struct SubtitleColor { int y, u, v, alpha; };

template<typename Pixel>
void BlendSubtitles(CVPixelBufferRef output, const IOSSubtitleBitmap& subtitles,
                    bool fullRange, bool pq, bool hlg, bool bt2020, bool bt601)
{
  // Convert subtitle colours only, never the video. The source is sRGB;
  // HDR text uses diffuse white (203 nits for PQ, 75% signal for HLG).
  constexpr int shift = sizeof(Pixel) == 2 ? 6 : 0;
  constexpr int factor = sizeof(Pixel) == 2 ? 4 : 1;
  const double maximum = sizeof(Pixel) == 2 ? 1023 : 255;
  const double yRange = fullRange ? maximum : 219 * factor;
  const double uvRange = fullRange ? maximum : 224 * factor;
  const double yOffset = fullRange ? 0 : 16 * factor;
  const double midpoint = 128 * factor;
  const double kr = bt2020 ? 0.2627 : (bt601 ? 0.299 : 0.2126);
  const double kb = bt2020 ? 0.0593 : (bt601 ? 0.114 : 0.0722);
  const auto linear = [](double value) {
    return value <= 0.04045 ? value / 12.92 : std::pow((value + 0.055) / 1.055, 2.4);
  };
  const auto transfer = [pq, hlg](double value) {
    value = std::max(0.0, value);
    if (pq)
    {
      const double power = std::pow(value * 203.0 / 10000.0, 2610.0 / 16384.0);
      return std::pow((3424.0 / 4096.0 + 2413.0 / 128.0 * power) /
                     (1 + 2392.0 / 128.0 * power), 2523.0 / 32.0);
    }
    if (hlg)
    {
      value *= 0.26496256;
      return value <= 1.0 / 12 ? std::sqrt(3 * value) :
          0.17883277 * std::log(12 * value - 0.28466892) + 0.55991073;
    }
    return value < 0.018 ? 4.5 * value : 1.099 * std::pow(value, 0.45) - 0.099;
  };
  std::unordered_map<uint32_t, SubtitleColor> palette;
  const auto colourAt = [&](int x, int y) -> SubtitleColor {
    const auto* rgba = subtitles.rgba.data() + (y * subtitles.width + x) * 4;
    const int alpha = rgba[3];
    if (!alpha) return {0, 0, 0, 0};
    const uint32_t key = (uint32_t(rgba[0]) << 24) | (rgba[1] << 16) | (rgba[2] << 8) | alpha;
    if (auto found = palette.find(key); found != palette.end()) return found->second;
    double r = linear(std::min(1.0, double(rgba[0]) / alpha));
    double g = linear(std::min(1.0, double(rgba[1]) / alpha));
    double b = linear(std::min(1.0, double(rgba[2]) / alpha));
    if (bt2020)
    {
      const double nr = 0.627404 * r + 0.329283 * g + 0.043313 * b;
      const double ng = 0.069097 * r + 0.919540 * g + 0.011362 * b;
      b = 0.016391 * r + 0.088013 * g + 0.895595 * b;
      r = nr;
      g = ng;
    }
    r = transfer(r); g = transfer(g); b = transfer(b);
    const double luma = kr * r + (1 - kr - kb) * g + kb * b;
    SubtitleColor colour{int(std::lround(yOffset + yRange * luma)),
        int(std::lround(midpoint + uvRange * (b - luma) / (2 * (1 - kb)))),
        int(std::lround(midpoint + uvRange * (r - luma) / (2 * (1 - kr)))), alpha};
    colour.y = std::clamp(colour.y, 0, int(maximum));
    colour.u = std::clamp(colour.u, 0, int(maximum));
    colour.v = std::clamp(colour.v, 0, int(maximum));
    palette.emplace(key, colour);
    return colour;
  };
  const auto blend = [](Pixel& sample, int value, int alpha) {
    sample = Pixel((((int(sample) >> shift) * (255 - alpha) + value * alpha + 127) / 255) << shift);
  };
  auto* yBase = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(output, 0));
  auto* uvBase = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(output, 1));
  for (int y = 0; y < subtitles.height; y += 2)
  {
    auto* row0 = reinterpret_cast<Pixel*>(yBase + y * CVPixelBufferGetBytesPerRowOfPlane(output, 0));
    auto* row1 = reinterpret_cast<Pixel*>(yBase + (y + 1) * CVPixelBufferGetBytesPerRowOfPlane(output, 0));
    auto* uv = reinterpret_cast<Pixel*>(uvBase + (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(output, 1));
    for (int x = 0; x < subtitles.width; x += 2)
    {
      int alpha = 0, u = 0, v = 0;
      for (int dy = 0; dy < 2; ++dy)
        for (int dx = 0; dx < 2; ++dx)
        {
          const auto colour = colourAt(x + dx, y + dy);
          if (!colour.alpha) continue;
          blend(dy ? row1[x + dx] : row0[x + dx], colour.y, colour.alpha);
          alpha += colour.alpha;
          u += colour.u * colour.alpha;
          v += colour.v * colour.alpha;
        }
      if (alpha)
      {
        blend(uv[x], (u + alpha / 2) / alpha, (alpha + 2) / 4);
        blend(uv[x + 1], (v + alpha / 2) / alpha, (alpha + 2) / 4);
      }
    }
  }
}
}

CVPixelBufferRef IOSCompositeVideo(CVPixelBufferRef video, const IOSSubtitleBitmap& subtitles)
{
  // The decoder remains hardware-backed. Only when PiP subtitles are visible,
  // scale its YUV planes to <=960x540 and blend the glyphs. vImage uses the CPU
  // and is safe when iOS prohibits background Metal/OpenGL command submission.
  // No full-resolution RGB conversion or second video decoder is involved.
  if (!video || subtitles.width < 2 || subtitles.height < 2 || (subtitles.width & 1) ||
      (subtitles.height & 1) || subtitles.width > 960 || subtitles.height > 540 ||
      subtitles.rgba.size() != size_t(subtitles.width * subtitles.height * 4)) return nullptr;
  const OSType format = CVPixelBufferGetPixelFormatType(video);
  const bool tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                      format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
  const bool fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                         format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
  if (!tenBit && format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
      format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return nullptr;
  // All calls run on the serial native-video queue.
  static CVPixelBufferPoolRef pool = nullptr;
  static int poolWidth = 0, poolHeight = 0;
  static OSType poolFormat = 0;
  if (!pool || poolWidth != subtitles.width || poolHeight != subtitles.height || poolFormat != format)
  {
    if (pool) CVPixelBufferPoolRelease(pool);
    pool = nullptr;
    NSDictionary* attributes = @{
      (id)kCVPixelBufferWidthKey: @(subtitles.width),
      (id)kCVPixelBufferHeightKey: @(subtitles.height),
      (id)kCVPixelBufferPixelFormatTypeKey: @(format),
      (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    if (CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)attributes, &pool))
      return nullptr;
    poolWidth = subtitles.width;
    poolHeight = subtitles.height;
    poolFormat = format;
  }
  CVPixelBufferRef output = nullptr;
  NSDictionary* limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @4};
  if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nullptr, pool,
      (__bridge CFDictionaryRef)limit, &output)) return nullptr;
  CVBufferPropagateAttachments(video, output);
  // VideoToolbox may attach a clean aperture in source pixels. Preserve its
  // crop, scaled to the PiP surface instead of copying 4K dimensions verbatim.
  CFTypeRef aperture = CVBufferCopyAttachment(video, kCVImageBufferCleanApertureKey, nullptr);
  if (aperture && CFGetTypeID(aperture) == CFDictionaryGetTypeID())
  {
    NSMutableDictionary* scaled = [(__bridge NSDictionary*)aperture mutableCopy];
    const double sx = double(subtitles.width) / CVPixelBufferGetWidth(video);
    const double sy = double(subtitles.height) / CVPixelBufferGetHeight(video);
    for (NSString* key in @[(id)kCVImageBufferCleanApertureWidthKey,
                            (id)kCVImageBufferCleanApertureHorizontalOffsetKey])
      if (scaled[key]) scaled[key] = @([scaled[key] doubleValue] * sx);
    for (NSString* key in @[(id)kCVImageBufferCleanApertureHeightKey,
                            (id)kCVImageBufferCleanApertureVerticalOffsetKey])
      if (scaled[key]) scaled[key] = @([scaled[key] doubleValue] * sy);
    CVBufferSetAttachment(output, kCVImageBufferCleanApertureKey,
        (__bridge CFDictionaryRef)scaled, kCVAttachmentMode_ShouldPropagate);
  }
  if (aperture) CFRelease(aperture);
  if (CVPixelBufferLockBaseAddress(video, kCVPixelBufferLock_ReadOnly))
  {
    CVPixelBufferRelease(output);
    return nullptr;
  }
  if (CVPixelBufferLockBaseAddress(output, 0))
  {
    CVPixelBufferUnlockBaseAddress(video, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(output);
    return nullptr;
  }
  vImage_Error error = kvImageNoError;
  for (int plane = 0; plane < 2 && !error; ++plane)
  {
    vImage_Buffer input{CVPixelBufferGetBaseAddressOfPlane(video, plane),
        CVPixelBufferGetHeightOfPlane(video, plane), CVPixelBufferGetWidthOfPlane(video, plane),
        CVPixelBufferGetBytesPerRowOfPlane(video, plane)};
    vImage_Buffer destination{CVPixelBufferGetBaseAddressOfPlane(output, plane),
        CVPixelBufferGetHeightOfPlane(output, plane), CVPixelBufferGetWidthOfPlane(output, plane),
        CVPixelBufferGetBytesPerRowOfPlane(output, plane)};
    error = tenBit ? (plane ? vImageScale_CbCr16U : vImageScale_Planar16U)(
        &input, &destination, nullptr, kvImageNoFlags) :
        (plane ? vImageScale_CbCr8 : vImageScale_Planar8)(
        &input, &destination, nullptr, kvImageNoFlags);
  }
  CVPixelBufferUnlockBaseAddress(video, kCVPixelBufferLock_ReadOnly);
  const auto matches = [video](CFStringRef key, CFStringRef value) {
    CFTypeRef attachment = CVBufferCopyAttachment(video, key, nullptr);
    const bool equal = attachment && CFEqual(attachment, value);
    if (attachment) CFRelease(attachment);
    return equal;
  };
  if (!error)
  {
    const bool pq = matches(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ);
    const bool hlg = matches(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG);
    const bool bt2020 = matches(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020);
    const bool bt601 = matches(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4);
    if (tenBit) BlendSubtitles<uint16_t>(output, subtitles, fullRange, pq, hlg, bt2020, bt601);
    else BlendSubtitles<uint8_t>(output, subtitles, fullRange, pq, hlg, bt2020, bt601);
  }
  CVPixelBufferUnlockBaseAddress(output, 0);
  if (error)
  {
    CVPixelBufferRelease(output);
    return nullptr;
  }
  return output;
}
