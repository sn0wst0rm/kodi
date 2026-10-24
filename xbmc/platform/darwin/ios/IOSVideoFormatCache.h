/*
 *  Copyright (C) 2026 Team Kodi
 *  SPDX-License-Identifier: GPL-2.0-or-later
 */

#pragma once

#include <CoreMedia/CMFormatDescription.h>
#include <CoreVideo/CVPixelBuffer.h>

// Confined to the presentation thread. Image buffers retain their own dynamic
// metadata; reuse only the format description when CoreMedia confirms a match.
class IOSVideoFormatCache
{
public:
  IOSVideoFormatCache() = default;
  IOSVideoFormatCache(const IOSVideoFormatCache&) = delete;
  IOSVideoFormatCache& operator=(const IOSVideoFormatCache&) = delete;
  ~IOSVideoFormatCache() { Reset(); }

  void Reset()
  {
    if (m_format)
      CFRelease(m_format);
    m_format = nullptr;
  }

  OSStatus Get(CVPixelBufferRef image, CMVideoFormatDescriptionRef* format)
  {
    *format = nullptr;
    if (!m_format || !CMVideoFormatDescriptionMatchesImageBuffer(m_format, image))
    {
      Reset();
      const OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(nullptr, image, &m_format);
      if (status != noErr)
        return status;
    }
    *format = m_format; // borrowed until Reset or a subsequent format change
    return noErr;
  }

private:
  CMVideoFormatDescriptionRef m_format{nullptr};
};
