/*
 *  Copyright (C) 2007-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

#include "cores/VideoPlayer/VideoRenderers/LinuxRendererGLES.h"

#include <CoreVideo/CVOpenGLESTextureCache.h>

class CRendererVTB : public CLinuxRendererGLES
{
public:
  CRendererVTB();
  ~CRendererVTB() override;

  static CBaseRenderer* Create(CVideoBuffer *buffer);
  static bool Register();

  // Player functions
  bool Configure(const VideoPicture& picture, float fps, unsigned int orientation) override;
  bool ConfigChanged(const VideoPicture& picture) override;
  void UnInit() override;
  bool Flush(bool saveBuffers) override;
  bool RenderCapture(int index, CRenderCapture* capture) override;
  bool Supports(ERENDERFEATURE feature) const override;
  bool Supports(ESCALINGMETHOD method) const override;
  bool SupportsMultiPassRendering() override;
  void ReleaseBuffer(int idx) override;
  bool NeedBuffer(int idx) override;

protected:
  // hooks for hw dec renderer
  bool LoadShadersHook() override;
  bool RenderHook(int idx) override;
  void AfterRenderHook(int idx) override;
  EShaderFormat GetShaderFormat() override;

  // textures
  bool UploadTexture(int index) override;
  void DeleteTexture(int index) override;
  bool CreateTexture(int index) override;

  CVOpenGLESTextureCacheRef m_textureCache = nullptr;
  struct CRenderBuffer
  {
    CVOpenGLESTextureRef m_textureY;
    CVOpenGLESTextureRef m_textureUV;
    CVBufferRef m_videoBuffer;
    GLsync m_fence;
  };
  CRenderBuffer m_vtbBuffers[NUM_BUFFERS];
  CVEAGLContext m_glContext;
  bool m_nativeHDR{false};
  uint64_t m_hdrSession{0};
};

