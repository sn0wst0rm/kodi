/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "IOSHDRVideo.h"
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

namespace
{
// Used only on the serial native-video delivery queue. No decoder restart,
// CPU pixel loop, or additional pass is needed while HDR is enabled.
struct SDRTransfer
{
  VTPixelTransferSessionRef session{nullptr};
  CVPixelBufferPoolRef pool{nullptr};
  size_t width{0}, height{0};
  ~SDRTransfer()
  {
    if (pool) CVPixelBufferPoolRelease(pool);
    if (session)
    {
      VTPixelTransferSessionInvalidate(session);
      CFRelease(session);
    }
  }
  OSStatus Prepare(size_t w, size_t h)
  {
    if (!session)
    {
      OSStatus status = VTPixelTransferSessionCreate(nullptr, &session);
      if (status) return status;
      NSDictionary* properties = @{
        (id)kVTPixelTransferPropertyKey_DestinationColorPrimaries: (id)kCVImageBufferColorPrimaries_ITU_R_709_2,
        (id)kVTPixelTransferPropertyKey_DestinationTransferFunction: (id)kCVImageBufferTransferFunction_ITU_R_709_2,
        (id)kVTPixelTransferPropertyKey_DestinationYCbCrMatrix: (id)kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        (id)kVTPixelTransferPropertyKey_RealTime: @YES
      };
      status = VTSessionSetProperties(session, (__bridge CFDictionaryRef)properties);
      if (status)
      {
        VTPixelTransferSessionInvalidate(session);
        CFRelease(session);
        session = nullptr;
        return status;
      }
    }
    if (!pool || width != w || height != h)
    {
      if (pool) CVPixelBufferPoolRelease(pool);
      pool = nullptr;
      NSDictionary* attributes = @{
        (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
      };
      OSStatus status = CVPixelBufferPoolCreate(nullptr, nullptr,
          (__bridge CFDictionaryRef)attributes, &pool);
      if (status) return status;
      width = w;
      height = h;
    }
    return noErr;
  }
};
}

CVPixelBufferRef IOSConvertVideoToSDR(CVPixelBufferRef video, int32_t* error)
{
  if (error) *error = noErr;
  if (!video) return nullptr;
  static SDRTransfer transfer;
  OSStatus status = transfer.Prepare(CVPixelBufferGetWidth(video), CVPixelBufferGetHeight(video));
  CVPixelBufferRef output = nullptr;
  if (!status)
  {
    NSDictionary* limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @4};
    status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nullptr, transfer.pool,
        (__bridge CFDictionaryRef)limit, &output);
  }
  if (!status)
    status = VTPixelTransferSessionTransferImage(transfer.session, video, output);
  if (status)
  {
    if (error) *error = status;
    if (output) CVPixelBufferRelease(output);
    return nullptr;
  }

  // Pixel transfer can propagate unrecognised sideband metadata, including
  // Dolby Vision/HDR10 metadata. A genuinely SDR output must not carry that
  // metadata into AVFoundation and be interpreted as HDR again. Preserve only
  // geometry/interlace information; all three colour tags describe the result.
  CFStringRef geometry[] = {kCVImageBufferCleanApertureKey, kCVImageBufferPixelAspectRatioKey,
                            kCVImageBufferFieldCountKey, kCVImageBufferFieldDetailKey};
  CFTypeRef values[4]{};
  for (int i = 0; i < 4; ++i)
    values[i] = CVBufferCopyAttachment(output, geometry[i], nullptr);
  CVBufferRemoveAllAttachments(output);
  for (int i = 0; i < 4; ++i)
    if (values[i])
    {
      CVBufferSetAttachment(output, geometry[i], values[i], kCVAttachmentMode_ShouldPropagate);
      CFRelease(values[i]);
    }
  CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey,
      kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  return output;
}
