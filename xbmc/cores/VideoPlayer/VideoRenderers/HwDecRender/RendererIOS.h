/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#include "cores/VideoPlayer/VideoRenderers/BaseRenderer.h"
#include "cores/VideoPlayer/DVDCodecs/Video/DVDVideoCodec.h"
#include "platform/darwin/ios/IOSHDRVideo.h"

// Owns only decoded surfaces. All GL work is confined to RenderUpdate (the
// foreground GUI); PresentFrame also runs while the GUI is suspended.
class CRendererIOS final : public CBaseRenderer
{
public:
  ~CRendererIOS() override { UnInit(); }
  bool Configure(const VideoPicture&, float fps, unsigned int orientation) override;
  bool IsConfigured() override { return m_configured; }
  void AddVideoPicture(const VideoPicture& picture, int index) override;
  void ReleaseBuffer(int index) override { m_pictures[index].Reset(); }
  void UnInit() override;
  bool Flush(bool saveBuffers) override;
  CRenderInfo GetRenderInfo() override;
  void Update() override { ManageRenderArea(); }
  void RenderUpdate(int index, int index2, bool clear, unsigned int flags, unsigned int alpha) override;
  bool VideoBypassesFramebuffer() override { return true; }
  bool ConfigChanged(const VideoPicture& picture) override;
  bool SupportsMultiPassRendering() override { return false; }
  bool Supports(ERENDERFEATURE feature) const override;
  bool Supports(ESCALINGMETHOD method) const override;
  bool NeedsPresent(int index) const;
  void PresentFrame(int index, std::shared_ptr<IOSSubtitleBitmap> subtitles);
  int VideoWidth() const { return m_sourceWidth; }
  int VideoHeight() const { return m_sourceHeight; }

private:
  VideoPicture m_pictures[NUM_BUFFERS];
  uint64_t m_session{0};
  CVideoBuffer* m_lastBuffer{nullptr};
  double m_lastPTS{0};
  bool m_lastPiP{false};
  CGRect m_lastSource{CGRectZero};
  CGRect m_lastDestination{CGRectZero};
  bool m_configured{false};
  CGRect m_source{CGRectMake(0, 0, 1, 1)};
  CGRect m_destination{CGRectMake(0, 0, 1, 1)};
};
