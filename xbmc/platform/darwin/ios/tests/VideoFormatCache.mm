/* Copyright (C) 2026 Team Kodi; SPDX-License-Identifier: GPL-2.0-or-later */
#include "IOSVideoFormatCache.h"
#include <CoreMedia/CMSampleBuffer.h>
#include <cassert>
#include <chrono>
#include <cstdio>

static CVPixelBufferRef Make(size_t width, OSType format, CFStringRef transfer)
{
  CVPixelBufferRef image = nullptr;
  assert(CVPixelBufferCreate(nullptr, width, 1080, format, nullptr, &image) == kCVReturnSuccess);
  CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, transfer,
                        kCVAttachmentMode_ShouldPropagate);
  return image;
}

int main()
{
  IOSVideoFormatCache cache;
  auto sdr = Make(1920, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  kCVImageBufferTransferFunction_ITU_R_709_2);
  auto sdr2 = Make(1920, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                   kCVImageBufferTransferFunction_ITU_R_709_2);
  auto hdr = Make(1920, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                  kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ);
  auto resized = Make(1280, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                      kCVImageBufferTransferFunction_ITU_R_709_2);
  CMVideoFormatDescriptionRef format = nullptr, reused = nullptr;
  assert(cache.Get(sdr, &format) == noErr);
  assert(cache.Get(sdr2, &reused) == noErr && format == reused);
  for (auto image : {hdr, resized, sdr, hdr})
  {
    assert(cache.Get(image, &format) == noErr);
    assert(CMVideoFormatDescriptionMatchesImageBuffer(format, image));
    assert(CMVideoFormatDescriptionGetDimensions(format).width == CVPixelBufferGetWidth(image));
    CMSampleBufferRef sample = nullptr;
    CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid};
    assert(CMSampleBufferCreateReadyWithImageBuffer(nullptr, image, format, &timing, &sample) == noErr);
    assert(CMSampleBufferGetImageBuffer(sample) == image); // no pixel copy
    CFRelease(sample);
  }
  // Colour changes on the same pixel buffer must invalidate the cached format.
  CVBufferSetAttachment(hdr, kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                        kCVAttachmentMode_ShouldPropagate);
  assert(cache.Get(hdr, &format) == noErr);
  assert(CFEqual(CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_TransferFunction),
                 kCVImageBufferTransferFunction_ITU_R_2100_HLG));
  const unsigned char mastering[24] = {1, 2, 3};
  CFDataRef metadata = CFDataCreate(nullptr, mastering, sizeof(mastering));
  CVBufferSetAttachment(hdr, kCVImageBufferMasteringDisplayColorVolumeKey, metadata,
                        kCVAttachmentMode_ShouldPropagate);
  assert(cache.Get(hdr, &format) == noErr);
  assert(CFEqual(CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_MasteringDisplayColorVolume), metadata));
  CFRelease(metadata);
  cache.Reset();
  assert(cache.Get(sdr, &format) == noErr);
  for (bool cached : {false, true})
  {
    auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < 100000; ++i)
    {
      if (cached)
        assert(cache.Get(sdr, &format) == noErr);
      else
      {
        assert(CMVideoFormatDescriptionCreateForImageBuffer(nullptr, sdr, &format) == noErr);
        CFRelease(format);
      }
    }
    printf("%s: %.3f us/frame (host microbenchmark)\n", cached ? "Cached format" : "New format",
        std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count() / 100000);
  }
  for (auto image : {sdr, sdr2, hdr, resized})
    CVPixelBufferRelease(image);
  puts("PASS: format reuse, resize, SDR/PQ/HLG, mastering metadata, reset and zero-copy sample wrapping");
}
