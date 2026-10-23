/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "RendererIOS.h"
#include "ServiceBroker.h"
#include "cores/VideoPlayer/DVDCodecs/Video/VTB.h"
#include "rendering/gles/RenderSystemGLES.h"
#include "windowing/GraphicContext.h"
#include "windowing/WinSystem.h"
#include <OpenGLES/ES2/gl.h>
#include <algorithm>
#include <cmath>

bool CRendererIOS::Configure(const VideoPicture& picture, float fps, unsigned int orientation)
{
  UnInit();
  m_sourceWidth = picture.iWidth;
  m_sourceHeight = picture.iHeight;
  m_renderOrientation = orientation;
  m_fps = fps;
  m_format = picture.videoBuffer->GetFormat();
  CalculateFrameAspectRatio(picture.iDisplayWidth, picture.iDisplayHeight);
  SetViewMode(m_videoSettings.m_ViewMode);
  ManageRenderArea();
  m_session = IOSBeginHDRVideo();
  m_configured = true;
  return true;
}

void CRendererIOS::AddVideoPicture(const VideoPicture& picture, int index)
{
  m_pictures[index].Reset();
  m_pictures[index].CopyRef(picture);
}

void CRendererIOS::UnInit()
{
  IOSEndHDRVideo(m_session);
  m_session = 0;
  m_lastBuffer = nullptr;
  m_configured = false;
  for (auto& picture : m_pictures)
    picture.Reset();
}

bool CRendererIOS::Flush(bool saveBuffers)
{
  // Keep the AVKit content source alive across seeks. A generation change
  // drops late frames and flushes the sample queue without stopping PiP.
  if (m_session)
    m_session = IOSBeginHDRVideo();
  m_lastBuffer = nullptr;
  for (auto& picture : m_pictures)
    picture.Reset();
  return false;
}

CRenderInfo CRendererIOS::GetRenderInfo()
{
  CRenderInfo info;
  info.max_buffer_size = NUM_BUFFERS;
  info.formats = {AV_PIX_FMT_VIDEOTOOLBOX};
  info.m_deintMethods = {VS_INTERLACEMETHOD_NONE};
  return info;
}

bool CRendererIOS::ConfigChanged(const VideoPicture& picture)
{
  return !dynamic_cast<VTB::CVideoBufferVTB*>(picture.videoBuffer);
}

bool CRendererIOS::Supports(ERENDERFEATURE feature) const
{
  return feature == RENDERFEATURE_ZOOM || feature == RENDERFEATURE_VERTICAL_SHIFT ||
         feature == RENDERFEATURE_PIXEL_RATIO || feature == RENDERFEATURE_STRETCH ||
         feature == RENDERFEATURE_ROTATION;
}

bool CRendererIOS::Supports(ESCALINGMETHOD method) const
{
  return method == VS_SCALINGMETHOD_LINEAR || method == VS_SCALINGMETHOD_AUTO;
}

bool CRendererIOS::NeedsPresent(int index) const
{
  const auto& picture = m_pictures[index];
  return picture.videoBuffer && (picture.videoBuffer != m_lastBuffer || picture.pts != m_lastPTS ||
      m_lastPiP != IOSIsPictureInPictureActive() || !CGRectEqualToRect(m_source, m_lastSource) ||
      !CGRectEqualToRect(m_destination, m_lastDestination));
}

void CRendererIOS::PresentFrame(int index, std::shared_ptr<IOSSubtitleBitmap> subtitles)
{
  const auto& picture = m_pictures[index];
  auto* buffer = dynamic_cast<VTB::CVideoBufferVTB*>(picture.videoBuffer);
  if (!buffer || !m_session)
    return;
  IOSHDRVideoMetadata metadata;
  metadata.primaries = picture.color_primaries;
  metadata.transfer = picture.color_transfer;
  metadata.matrix = picture.color_space;
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

  m_lastBuffer = picture.videoBuffer;
  m_lastPTS = picture.pts;
  m_lastPiP = IOSIsPictureInPictureActive();
  m_lastSource = m_source;
  m_lastDestination = m_destination;
  IOSPresentHDRVideo(m_session, buffer->GetPB(), metadata, m_source, m_destination,
                     m_renderOrientation, std::move(subtitles));
}

void CRendererIOS::RenderUpdate(int index, int index2, bool clear, unsigned int flags, unsigned int alpha)
{
  ManageRenderArea();
  auto& gfx = CServiceBroker::GetWinSystem()->GetGfxContext();
  const int width = gfx.GetWidth(), height = gfx.GetHeight();
  if (!width || !height || !m_sourceWidth || !m_sourceHeight)
    return;
  auto* render = CServiceBroker::GetRenderSystem();
  CRect destination = m_destRect;
  float z = 0;
  render->Project(destination.x1, destination.y1, z);
  render->Project(destination.x2, destination.y2, z);
  CRect viewport;
  render->GetViewPort(viewport);
  destination.y1 += viewport.y1;
  destination.y2 += viewport.y1;
  m_source = CGRectMake(m_sourceRect.x1 / m_sourceWidth, m_sourceRect.y1 / m_sourceHeight,
                        m_sourceRect.Width() / m_sourceWidth, m_sourceRect.Height() / m_sourceHeight);
  m_destination = CGRectMake(destination.x1 / width, destination.y1 / height,
                             destination.Width() / width, destination.Height() / height);

  GLint scissor[4];
  GLfloat color[4];
  GLboolean mask[4];
  const GLboolean enabled = glIsEnabled(GL_SCISSOR_TEST);
  glGetIntegerv(GL_SCISSOR_BOX, scissor);
  glGetFloatv(GL_COLOR_CLEAR_VALUE, color);
  glGetBooleanv(GL_COLOR_WRITEMASK, mask);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  if (clear)
  {
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
  }
  if (enabled)
    destination.Intersect(CRect(scissor[0], height - scissor[1] - scissor[3],
                               scissor[0] + scissor[2], height - scissor[1]));
  destination.Intersect(CRect(0, 0, width, height));
  if (!destination.IsEmpty())
  {
    glEnable(GL_SCISSOR_TEST);
    glScissor(std::lround(destination.x1), std::lround(height - destination.y2),
              std::lround(destination.Width()), std::lround(destination.Height()));
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
  }
  glClearColor(color[0], color[1], color[2], color[3]);
  glColorMask(mask[0], mask[1], mask[2], mask[3]);
  glScissor(scissor[0], scissor[1], scissor[2], scissor[3]);
  if (!enabled) glDisable(GL_SCISSOR_TEST);
}
