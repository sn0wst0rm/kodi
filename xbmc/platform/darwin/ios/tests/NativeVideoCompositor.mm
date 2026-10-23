#import <Foundation/Foundation.h>
#include "IOSHDRVideo.h"
#include <cassert>
#include <cstring>
#include <cstdio>
#include <chrono>

static unsigned luma(CVPixelBufferRef pixel, int x, int y, bool tenBit)
{
  auto* row = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel, 0)) +
      y * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0);
  return tenBit ? reinterpret_cast<uint16_t*>(row)[x] >> 6 : row[x];
}
int main(int argc, char**)
{
  @autoreleasepool {
    for (bool tenBit : {false, true}) for (bool fullRange : {false, true})
      for (bool hlg : {false, true}) {
      if (!tenBit && hlg) continue;
      const bool large = argc > 1;
      const int subScale = large ? 15 : 1;
      CVPixelBufferRef input = nullptr;
      NSDictionary* attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
          (id)kCVPixelBufferMetalCompatibilityKey: @YES};
      OSType format = tenBit ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) :
          (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
      assert(CVPixelBufferCreate(nullptr, large ? 3840 : 128, large ? 2160 : 72, format, (__bridge CFDictionaryRef)attributes, &input) == 0);
      CVBufferSetAttachment(input, kCVImageBufferTransferFunctionKey,
          tenBit ? (hlg ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) : kCVImageBufferTransferFunction_ITU_R_709_2,
          kCVAttachmentMode_ShouldPropagate);
      CVBufferSetAttachment(input, kCVImageBufferColorPrimariesKey,
          tenBit ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2,
          kCVAttachmentMode_ShouldPropagate);
      CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey,
          tenBit ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2,
          kCVAttachmentMode_ShouldPropagate);
      NSDictionary* aperture = @{(id)kCVImageBufferCleanApertureWidthKey: @(CVPixelBufferGetWidth(input)),
          (id)kCVImageBufferCleanApertureHeightKey: @(CVPixelBufferGetHeight(input)),
          (id)kCVImageBufferCleanApertureHorizontalOffsetKey: @0,
          (id)kCVImageBufferCleanApertureVerticalOffsetKey: @0};
      CVBufferSetAttachment(input, kCVImageBufferCleanApertureKey, (__bridge CFDictionaryRef)aperture,
          kCVAttachmentMode_ShouldPropagate);
      CVPixelBufferLockBaseAddress(input, 0);
      for (int plane=0; plane<2; ++plane) {
        auto* data = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(input, plane));
        size_t length = CVPixelBufferGetBytesPerRowOfPlane(input, plane) * CVPixelBufferGetHeightOfPlane(input, plane);
        if (tenBit) for(size_t i=0; i<length/2; ++i) reinterpret_cast<uint16_t*>(data)[i] = (plane ? 512 : (fullRange ? 0 : 64)) << 6;
        else memset(data, plane ? 128 : (fullRange ? 0 : 16), length);
      }
      CVPixelBufferUnlockBaseAddress(input, 0);
      IOSSubtitleBitmap sub;
      sub.width=64*subScale; sub.height=36*subScale; sub.rgba.resize(sub.width*sub.height*4);
      for(int y=3*subScale; y<12*subScale; ++y) for(int x=4*subScale; x<20*subScale; ++x)
        memset(sub.rgba.data()+(y*sub.width+x)*4, 255, 4);
      const auto started = std::chrono::steady_clock::now();
      for(int frame=0; frame<20; ++frame) {
        CVPixelBufferRef output=IOSCompositeVideo(input, sub);
        assert(output && CVPixelBufferGetPixelFormatType(output)==format);
        assert(CVPixelBufferGetWidth(output)==size_t(sub.width) && CVPixelBufferGetHeight(output)==size_t(sub.height));
        CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
        unsigned white=luma(output, 10*subScale, 6*subScale, tenBit), black=luma(output,10*subScale,30*subScale,tenBit);
        if(frame==0) printf("%s %s %s: top subtitle=%u bottom black=%u\n",tenBit?"P010":"NV12",fullRange?"full":"limited",tenBit?(hlg?"HLG":"PQ"):"SDR",white,black);
        assert(white > black + (tenBit ? 150 : 100));
        assert(black < (fullRange ? 10 : (tenBit ? 80 : 25)));
        assert(white < (tenBit ? 1024 : 256));
        CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
        assert(CVBufferHasAttachment(output,kCVImageBufferTransferFunctionKey));
        CFTypeRef outputAperture = CVBufferCopyAttachment(output, kCVImageBufferCleanApertureKey, nullptr);
        NSDictionary* scaled = (__bridge NSDictionary*)outputAperture;
        assert([scaled[(id)kCVImageBufferCleanApertureWidthKey] intValue] == sub.width);
        assert([scaled[(id)kCVImageBufferCleanApertureHeightKey] intValue] == sub.height);
        CFRelease(outputAperture);
        CVPixelBufferRelease(output);
      }
      const double milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-started).count()/20;
      printf("  compositor %.3f ms/frame (Mac host, synthetic frame)\n", milliseconds);
      IOSSubtitleBitmap invalid;
      assert(!IOSCompositeVideo(input, invalid));
      CVPixelBufferRelease(input);
    }
    puts("PASS: SDR/PQ/HLG compositing without background GPU commands, subtitle placement, metadata and buffer reuse");
  }
}
