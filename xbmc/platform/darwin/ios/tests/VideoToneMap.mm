/* SPDX-License-Identifier: GPL-2.0-or-later */
#import <Foundation/Foundation.h>
#include "IOSHDRVideo.h"
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>

static unsigned Luma(CVPixelBufferRef video, int x)
{
  CVPixelBufferLockBaseAddress(video, kCVPixelBufferLock_ReadOnly);
  unsigned sample = static_cast<uint16_t*>(CVPixelBufferGetBaseAddressOfPlane(video, 0))[x] >> 6;
  CVPixelBufferUnlockBaseAddress(video, kCVPixelBufferLock_ReadOnly);
  return sample;
}

int main(int argc, char**)
{
  @autoreleasepool
  {
    for (bool hlg : {false, true}) for (bool full : {false, true})
    {
      int width = argc > 1 ? 3840 : 128, height = argc > 1 ? 2160 : 72;
      CVPixelBufferRef source = nullptr;
      NSDictionary* attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
      assert(!CVPixelBufferCreate(nullptr, width, height,
          full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
          (__bridge CFDictionaryRef)attributes, &source));
      CFStringRef transfer = hlg ? kCVImageBufferTransferFunction_ITU_R_2100_HLG :
                                  kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
      CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
      CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey, transfer, kCVAttachmentMode_ShouldPropagate);
      CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
      uint8_t light[] = {3, 232, 1, 144};
      CFDataRef data = CFDataCreate(nullptr, light, 4);
      CVBufferSetAttachment(source, kCVImageBufferContentLightLevelInfoKey, data, kCVAttachmentMode_ShouldPropagate);
      CFRelease(data);
      CVBufferSetAttachment(source, CFSTR("TestHDRSideband"), kCFBooleanTrue, kCVAttachmentMode_ShouldPropagate);
      NSDictionary* aspect = @{(id)kCVImageBufferPixelAspectRatioHorizontalSpacingKey: @1,
                                (id)kCVImageBufferPixelAspectRatioVerticalSpacingKey: @1};
      CVBufferSetAttachment(source, kCVImageBufferPixelAspectRatioKey, (__bridge CFDictionaryRef)aspect, kCVAttachmentMode_ShouldPropagate);
      const double nits[] = {0, 1, 10, 50, 100, 200, 500, 1000};
      CVPixelBufferLockBaseAddress(source, 0);
      for (int y = 0; y < height; ++y)
      {
        auto* row = reinterpret_cast<uint16_t*>(static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(source, 0)) + y * CVPixelBufferGetBytesPerRowOfPlane(source, 0));
        for (int x = 0; x < width; ++x)
        {
          const double n = nits[x / (width / 8)];
          const double p = std::pow(n / 10000, 2610.0 / 16384);
          const double signal = hlg ? (n <= 1000.0 / 12 ? std::sqrt(3 * n / 1000) :
              0.17883277 * std::log(12 * n / 1000 - 0.28466892) + 0.55991073) :
              std::pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32);
          row[x] = unsigned(std::lround((full ? 0 : 64) + (full ? 1023 : 876) * signal)) << 6;
        }
      }
      for (int y = 0; y < height / 2; ++y)
      {
        auto* row = reinterpret_cast<uint16_t*>(static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(source, 1)) + y * CVPixelBufferGetBytesPerRowOfPlane(source, 1));
        for (int x = 0; x < width; ++x) row[x] = 512 << 6;
      }
      CVPixelBufferUnlockBaseAddress(source, 0);
      const unsigned originalWhite = Luma(source, width / 2 + 1);
      const auto started = std::chrono::steady_clock::now();
      for (int frame = 0; frame < 12; ++frame)
      {
        int32_t error = 0;
        CVPixelBufferRef output = IOSConvertVideoToSDR(source, &error);
        assert(output && !error && output != source);
        assert(CVPixelBufferGetWidth(output) == size_t(width) && CVPixelBufferGetHeight(output) == size_t(height));
        assert(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
        CFTypeRef tag = CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nullptr);
        assert(tag && CFEqual(tag, kCVImageBufferTransferFunction_ITU_R_709_2));
        CFRelease(tag);
        assert(!CVBufferHasAttachment(output, kCVImageBufferContentLightLevelInfoKey));
        assert(!CVBufferHasAttachment(output, CFSTR("TestHDRSideband")));
        assert(CVBufferHasAttachment(output, kCVImageBufferPixelAspectRatioKey));
        assert(Luma(output, 1) >= 60 && Luma(output, 1) <= 68);
        unsigned previous = 0;
        for (int i = 0; i < 8; ++i)
        {
          unsigned value = Luma(output, i * (width / 8) + 1);
          assert(value >= previous && value <= 942);
          previous = value;
        }
        assert(Luma(output, width / 2 + 1) != originalWhite);
        assert(Luma(output, width - 2) > 850);
        CVPixelBufferRelease(output);
      }
      assert(Luma(source, width / 2 + 1) == originalWhite);
      assert(CVBufferHasAttachment(source, kCVImageBufferContentLightLevelInfoKey));
      printf("PASS: %s %s -> SDR10, monotonic highlights, clean tags, source unchanged, %.3f ms/frame (%dx%d Mac)\n",
          hlg ? "HLG" : "PQ", full ? "full" : "limited",
          std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count() / 12,
          width, height);
      CVPixelBufferRelease(source);
    }
  }
}
