/*
 *  Copyright (C) 2007-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#include "RendererVTBGLES.h"

#include "../RenderFactory.h"
#include "ServiceBroker.h"
#include "cores/IPlayer.h"
#include "cores/VideoPlayer/DVDCodecs/Video/VTB.h"
#include "settings/MediaSettings.h"
#include "utils/GLUtils.h"
#include "utils/log.h"
#if defined(TARGET_DARWIN_IOS)
#include "platform/darwin/ios/IOSHDRVideo.h"
#include "RendererIOS.h"
#include "windowing/ios/WinSystemIOS.h"
#define WIN_SYSTEM_CLASS CWinSystemIOS
#elif defined(TARGET_DARWIN_TVOS)
#include "windowing/tvos/WinSystemTVOS.h"
#define WIN_SYSTEM_CLASS CWinSystemTVOS
#endif

#include <CoreVideo/CVBuffer.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <OpenGLES/ES2/glext.h>
#include <algorithm>
#include <cmath>

CBaseRenderer* CRendererVTB::Create(CVideoBuffer *buffer)
{
  VTB::CVideoBufferVTB *vb = dynamic_cast<VTB::CVideoBufferVTB*>(buffer);
  if (vb)
  {
#if defined(TARGET_DARWIN_IOS)
    if (IOSSupportsHDRVideo())
      return new CRendererIOS();
#endif
    return new CRendererVTB();
  }

  return nullptr;
}

bool CRendererVTB::Register()
{
  VIDEOPLAYER::CRendererFactory::RegisterRenderer("vtbgles", CRendererVTB::Create);
  return true;
}

CRendererVTB::CRendererVTB()
{
  auto winSystem = dynamic_cast<WIN_SYSTEM_CLASS*>(CServiceBroker::GetWinSystem());
  m_glContext = winSystem->GetEAGLContextObj();
  CVReturn ret = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault,
                                              NULL,
                                              m_glContext,
                                              NULL,
                                              &m_textureCache);
  if (ret != kCVReturnSuccess)
  {
    CLog::Log(LOGERROR, "CRendererVTB::CRendererVTB - Error creating texture cache (err: {})", ret);
  }

  for (auto &buf : m_vtbBuffers)
  {
    buf.m_textureY = nullptr;
    buf.m_textureUV = nullptr;
    buf.m_videoBuffer = nullptr;
    buf.m_fence = nullptr;
  }
}

CRendererVTB::~CRendererVTB()
{
#if defined(TARGET_DARWIN_IOS)
  IOSEndHDRVideo(m_hdrSession);
#endif
  if (m_textureCache)
    CFRelease(m_textureCache);

  for (int i = 0; i < NUM_BUFFERS; ++i)
  {
    DeleteTexture(i);
  }
}

bool CRendererVTB::Configure(const VideoPicture& picture, float fps, unsigned int orientation)
{
#if defined(TARGET_DARWIN_IOS)
  IOSEndHDRVideo(m_hdrSession);
  auto* buffer = dynamic_cast<VTB::CVideoBufferVTB*>(picture.videoBuffer);
  m_nativeHDR = buffer && IOSSupportsHDRVideo() && IOSIsTenBitVideo(buffer->GetPB());
  m_hdrSession = m_nativeHDR ? IOSBeginHDRVideo() : 0;
#endif
  return CLinuxRendererGLES::Configure(picture, fps, orientation);
}

bool CRendererVTB::ConfigChanged(const VideoPicture& picture)
{
#if defined(TARGET_DARWIN_IOS)
  auto* buffer = dynamic_cast<VTB::CVideoBufferVTB*>(picture.videoBuffer);
  if ((buffer && IOSIsTenBitVideo(buffer->GetPB())) != m_nativeHDR)
    return true;
#endif
  return CLinuxRendererGLES::ConfigChanged(picture);
}

void CRendererVTB::UnInit()
{
#if defined(TARGET_DARWIN_IOS)
  IOSEndHDRVideo(m_hdrSession);
  m_hdrSession = 0;
#endif
  CLinuxRendererGLES::UnInit();
}

bool CRendererVTB::Flush(bool saveBuffers)
{
#if defined(TARGET_DARWIN_IOS)
  IOSEndHDRVideo(m_hdrSession);
  m_hdrSession = m_nativeHDR ? IOSBeginHDRVideo() : 0;
#endif
  return CLinuxRendererGLES::Flush(saveBuffers);
}

bool CRendererVTB::RenderCapture(int index, CRenderCapture* capture)
{
  // A GLES FBO cannot capture the separate system HDR plane.
  return !m_nativeHDR && CLinuxRendererGLES::RenderCapture(index, capture);
}

bool CRendererVTB::Supports(ERENDERFEATURE feature) const
{
  if (m_nativeHDR && (feature == RENDERFEATURE_BRIGHTNESS ||
                      feature == RENDERFEATURE_CONTRAST ||
                      feature == RENDERFEATURE_TONEMAP || feature == RENDERFEATURE_POSTPROCESS))
    return false; // The system compositor performs HDR display mapping.
  return CLinuxRendererGLES::Supports(feature);
}

bool CRendererVTB::Supports(ESCALINGMETHOD method) const
{
  return m_nativeHDR ? method == VS_SCALINGMETHOD_LINEAR : CLinuxRendererGLES::Supports(method);
}

bool CRendererVTB::SupportsMultiPassRendering()
{
  return !m_nativeHDR;
}

void CRendererVTB::ReleaseBuffer(int idx)
{
  CPictureBuffer &buf = m_buffers[idx];
  CRenderBuffer &renderBuf = m_vtbBuffers[idx];
  if (buf.videoBuffer)
  {
    if (renderBuf.m_fence && glIsSyncAPPLE(renderBuf.m_fence))
    {
      glDeleteSyncAPPLE(renderBuf.m_fence);
      renderBuf.m_fence = 0;
    }
    buf.videoBuffer->Release();
    buf.videoBuffer = nullptr;
  }
}

EShaderFormat CRendererVTB::GetShaderFormat()
{
  return SHADER_YV12;
}

bool CRendererVTB::LoadShadersHook()
{
  if (m_nativeHDR)
  {
    m_renderMethod = RENDER_CUSTOM;
    CLog::Log(LOGINFO, "VTB: native 10-bit HDR video plane with GLES GUI overlay");
    return true;
  }
  CLog::Log(LOGINFO, "GL: Using CVBREF render method");
  m_textureTarget = GL_TEXTURE_2D;
  m_renderMethod = RENDER_CUSTOM;

  if (!m_textureCache)
  {
    CLog::Log(LOGINFO, "CRendererVTB::LoadShadersHook: no texture cache");
    return false;
  }

  return false;
}

bool CRendererVTB::RenderHook(int idx)
{
#if defined(TARGET_DARWIN_IOS)
  if (m_nativeHDR)
  {
    auto& picture = m_buffers[idx];
    auto* buffer = dynamic_cast<VTB::CVideoBufferVTB*>(picture.videoBuffer);
    if (!buffer)
      return true;

    IOSHDRVideoMetadata metadata;
    metadata.primaries = picture.m_srcPrimaries;
    metadata.transfer = picture.m_srcColTransfer;
    metadata.matrix = picture.m_srcColSpace;
    const auto write16 = [](uint8_t* out, unsigned int value) {
      value = std::min(value, 65535u);
      out[0] = value >> 8;
      out[1] = value;
    };
    const auto write32 = [](uint8_t* out, uint32_t value) {
      out[0] = value >> 24;
      out[1] = value >> 16;
      out[2] = value >> 8;
      out[3] = value;
    };
    const auto quantise = [](AVRational value, double scale) -> uint32_t {
      return std::llround(std::clamp(av_q2d(value) * scale, 0.0, 4294967295.0));
    };
    if (picture.hasDisplayMetadata && picture.displayMetadata.has_primaries &&
        picture.displayMetadata.has_luminance)
    {
      metadata.hasMastering = true;
      // ISO/IEC 23008-2 D.2.28 stores primaries in G, B, R order.
      for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 2; ++j)
          write16(metadata.mastering.data() + i * 4 + j * 2,
                  quantise(picture.displayMetadata.display_primaries[(i + 1) % 3][j], 50000));
      for (int j = 0; j < 2; ++j)
        write16(metadata.mastering.data() + 12 + j * 2,
                quantise(picture.displayMetadata.white_point[j], 50000));
      write32(metadata.mastering.data() + 16, quantise(picture.displayMetadata.max_luminance, 10000));
      write32(metadata.mastering.data() + 20, quantise(picture.displayMetadata.min_luminance, 10000));
    }
    if (picture.hasLightMetadata)
    {
      metadata.hasLight = true;
      write16(metadata.light.data(), picture.lightMetadata.MaxCLL);
      write16(metadata.light.data() + 2, picture.lightMetadata.MaxFALL);
    }

    const auto& gfx = CServiceBroker::GetWinSystem()->GetGfxContext();
    const int width = gfx.GetWidth();
    const int height = gfx.GetHeight();
    if (width <= 0 || height <= 0 || m_sourceWidth == 0 || m_sourceHeight == 0)
      return true;
    CRect destination = m_destRect;
    float z = 0;
    m_renderSystem->Project(destination.x1, destination.y1, z);
    m_renderSystem->Project(destination.x2, destination.y2, z);
    CRect viewport;
    m_renderSystem->GetViewPort(viewport);
    // Project() includes viewport X but returns Y relative to its top edge.
    destination.y1 += viewport.y1;
    destination.y2 += viewport.y1;
    CGRect source = CGRectMake(m_sourceRect.x1 / m_sourceWidth, m_sourceRect.y1 / m_sourceHeight,
        m_sourceRect.Width() / m_sourceWidth, m_sourceRect.Height() / m_sourceHeight);
    IOSPresentHDRVideo(m_hdrSession, buffer->GetPB(), metadata, source,
        CGRectMake(destination.x1 / width, destination.y1 / height,
                   destination.Width() / width, destination.Height() / height), m_renderOrientation);

    // Punch a hole only where Kodi would draw video. Later GUI/OSD rendering
    // remains on top, including subtitles and modal settings dialogs.
    GLint scissor[4];
    GLfloat clearColor[4];
    GLboolean colorMask[4];
    const GLboolean scissorEnabled = glIsEnabled(GL_SCISSOR_TEST);
    glGetIntegerv(GL_SCISSOR_BOX, scissor);
    glGetFloatv(GL_COLOR_CLEAR_VALUE, clearColor);
    glGetBooleanv(GL_COLOR_WRITEMASK, colorMask);
    if (scissorEnabled)
      destination.Intersect(CRect(scissor[0], height - scissor[1] - scissor[3],
                                 scissor[0] + scissor[2], height - scissor[1]));
    destination.Intersect(CRect(0, 0, width, height));
    if (!destination.IsEmpty())
    {
      glEnable(GL_SCISSOR_TEST);
      glScissor(std::lround(destination.x1), std::lround(height - destination.y2),
                std::lround(destination.Width()), std::lround(destination.Height()));
      glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
      glClearColor(0, 0, 0, 0);
      glClear(GL_COLOR_BUFFER_BIT);
      glClearColor(clearColor[0], clearColor[1], clearColor[2], clearColor[3]);
      glColorMask(colorMask[0], colorMask[1], colorMask[2], colorMask[3]);
      glScissor(scissor[0], scissor[1], scissor[2], scissor[3]);
      if (!scissorEnabled)
        glDisable(GL_SCISSOR_TEST);
    }
    return true;
  }
#endif
  return false;
}

bool CRendererVTB::CreateTexture(int index)
{
  CPictureBuffer &buf = m_buffers[index];
  YuvImage &im = buf.image;
  CYuvPlane (&planes)[YuvImage::MAX_PLANES] = buf.fields[0];

  DeleteTexture(index);

  memset(&im    , 0, sizeof(im));
  memset(&planes, 0, sizeof(CYuvPlane[YuvImage::MAX_PLANES]));

  im.height = m_sourceHeight;
  im.width = m_sourceWidth;

  planes[0].texwidth  = im.width;
  planes[0].texheight = im.height;
  planes[1].texwidth  = planes[0].texwidth >> im.cshift_x;
  planes[1].texheight = planes[0].texheight >> im.cshift_y;
  planes[2].texwidth  = planes[1].texwidth;
  planes[2].texheight = planes[1].texheight;

  for (int p = 0; p < 3; p++)
  {
    planes[p].pixpertex_x = 1;
    planes[p].pixpertex_y = 1;
  }

  planes[0].id = 1;
  return true;
}

void CRendererVTB::DeleteTexture(int index)
{
  CRenderBuffer &renderBuf = m_vtbBuffers[index];
  CYuvPlane (&planes)[YuvImage::MAX_PLANES] = m_buffers[index].fields[0];

  if (renderBuf.m_textureY)
    CFRelease(renderBuf.m_textureY);
  renderBuf.m_textureY = nullptr;

  if (renderBuf.m_textureUV)
    CFRelease(renderBuf.m_textureUV);
  renderBuf.m_textureUV = nullptr;

  ReleaseBuffer(index);

  planes[0].id = 0;
  planes[1].id = 0;
  planes[2].id = 0;
}

bool CRendererVTB::UploadTexture(int index)
{
  CRenderBuffer &renderBuf = m_vtbBuffers[index];
  CPictureBuffer &buf = m_buffers[index];
  CYuvPlane (&planes)[YuvImage::MAX_PLANES] = m_buffers[index].fields[0];
  YuvImage &im = m_buffers[index].image;

  VTB::CVideoBufferVTB *vb = dynamic_cast<VTB::CVideoBufferVTB*>(buf.videoBuffer);
  if (!vb)
  {
    return false;
  }

  if (m_nativeHDR)
    return true;

  CVOpenGLESTextureCacheFlush(m_textureCache, 0);

  if (renderBuf.m_textureY)
    CFRelease(renderBuf.m_textureY);
  renderBuf.m_textureY = nullptr;

  if (renderBuf.m_textureUV)
    CFRelease(renderBuf.m_textureUV);
  renderBuf.m_textureUV = nullptr;

  CVReturn ret;
  ret = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                     m_textureCache,
                                                     vb->GetPB(), nullptr, GL_TEXTURE_2D, GL_LUMINANCE,
                                                     im.width, im.height, GL_LUMINANCE, GL_UNSIGNED_BYTE,
                                                     0,
                                                     &renderBuf.m_textureY);

  if (ret != kCVReturnSuccess)
  {
    CLog::Log(LOGERROR, "CRendererVTB::UploadTexture - Error uploading texture Y (err: {})", ret);
    return false;
  }

  ret = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                     m_textureCache,
                                                     vb->GetPB(), nullptr, GL_TEXTURE_2D, GL_LUMINANCE_ALPHA,
                                                     im.width/2, im.height/2, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE,
                                                     1,
                                                     &renderBuf.m_textureUV);

  if (ret != kCVReturnSuccess)
  {
    CLog::Log(LOGERROR, "CRendererVTB::UploadTexture - Error uploading texture UV (err: {})", ret);
    return false;
  }

  // set textures
  planes[0].id = CVOpenGLESTextureGetName(renderBuf.m_textureY);
  planes[1].id = CVOpenGLESTextureGetName(renderBuf.m_textureUV);
  planes[2].id = CVOpenGLESTextureGetName(renderBuf.m_textureUV);

  for (int p=0; p<2; p++)
  {
    glBindTexture(m_textureTarget, planes[p].id);
    glTexParameteri(m_textureTarget, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(m_textureTarget, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(m_textureTarget, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(m_textureTarget, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glBindTexture(m_textureTarget, 0);
    VerifyGLState();
  }

  CalculateTextureSourceRects(index, 3);
  return true;
}

void CRendererVTB::AfterRenderHook(int idx)
{
  if (m_nativeHDR)
    return;
  CRenderBuffer &renderBuf = m_vtbBuffers[idx];
  if (renderBuf.m_fence && glIsSyncAPPLE(renderBuf.m_fence))
  {
    glDeleteSyncAPPLE(renderBuf.m_fence);
  }
  renderBuf.m_fence = glFenceSyncAPPLE(GL_SYNC_GPU_COMMANDS_COMPLETE_APPLE, 0);
}

bool CRendererVTB::NeedBuffer(int idx)
{
  CRenderBuffer &renderBuf = m_vtbBuffers[idx];
  if (renderBuf.m_fence && glIsSyncAPPLE(renderBuf.m_fence))
  {
    int syncState = GL_UNSIGNALED_APPLE;
    glGetSyncivAPPLE(renderBuf.m_fence, GL_SYNC_STATUS_APPLE, 1, nullptr, &syncState);
    if (syncState != GL_SIGNALED_APPLE)
      return true;
  }

  return false;
}

