/*
 *  Copyright (C) 2010-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#include "WinSystemIOS.h"

#include "ServiceBroker.h"
#include "cores/DataCacheCore.h"
#include "VideoSyncIos.h"
#include "WinEventsIOS.h"
#include "cores/AudioEngine/Sinks/AESinkDARWINIOS.h"
#include "cores/RetroPlayer/process/ios/RPProcessInfoIOS.h"
#include "cores/RetroPlayer/rendering/VideoRenderers/RPRendererOpenGLES.h"
#include "cores/VideoPlayer/DVDCodecs/DVDFactoryCodec.h"
#include "cores/VideoPlayer/DVDCodecs/Video/VTB.h"
#include "cores/VideoPlayer/Process/ios/ProcessInfoIOS.h"
#include "cores/VideoPlayer/VideoRenderers/HwDecRender/RendererVTBGLES.h"
#include "cores/VideoPlayer/VideoRenderers/LinuxRendererGLES.h"
#include "cores/VideoPlayer/VideoRenderers/RenderFactory.h"
#include "filesystem/SpecialProtocol.h"
#include "guilib/DispResource.h"
#include "guilib/Texture.h"
#include "guilib/GUIComponent.h"
#include "guilib/GUIWindowManager.h"
#include "messaging/ApplicationMessenger.h"
#include "rendering/gles/ScreenshotSurfaceGLES.h"
#include "settings/DisplaySettings.h"
#include "settings/Settings.h"
#include "settings/SettingsComponent.h"
#include "utils/StringUtils.h"
#include "utils/log.h"
#include "windowing/GraphicContext.h"
#include "windowing/WindowSystemFactory.h"

#import "platform/darwin/ios/IOSScreenManager.h"
#include "platform/darwin/ios/IOSHDRVideo.h"
#import "platform/darwin/ios/XBMCController.h"

#include <memory>
#include <mutex>
#include <vector>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <thread>

#import <Foundation/Foundation.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <QuartzCore/CADisplayLink.h>
#import <dlfcn.h>

#define CONST_TOUCHSCREEN "Touchscreen"
#define CONST_EXTERNAL "External"

// IOSDisplayLinkCallback is declared in the lower part of the file
@interface IOSDisplayLinkCallback : NSObject
{
@private CVideoSyncIos *_videoSyncImpl;
}
@property (nonatomic, setter=SetVideoSyncImpl:) CVideoSyncIos *_videoSyncImpl;
- (void) runDisplayLink;
@end

using namespace KODI;
using namespace MESSAGING;

bool CWinSystemIOS::SetHDR(const VideoPicture* picture)
{
  if (!picture || !IOSSupportsHDRVideo())
    return false;
  auto* buffer = dynamic_cast<VTB::CVideoBufferVTB*>(picture->videoBuffer);
  return buffer && IOSIsTenBitVideo(buffer->GetPB()) &&
         (picture->color_transfer == AVCOL_TRC_SMPTE2084 ||
          picture->color_transfer == AVCOL_TRC_ARIB_STD_B67);
}

struct CADisplayLinkWrapper
{
  CADisplayLink* impl;
  IOSDisplayLinkCallback *callbackClass;
};

void CWinSystemIOS::Register()
{
  KODI::WINDOWING::CWindowSystemFactory::RegisterWindowSystem(CreateWinSystem);
}

std::unique_ptr<CWinSystemBase> CWinSystemIOS::CreateWinSystem()
{
  return std::make_unique<CWinSystemIOS>();
}

int CWinSystemIOS::GetDisplayIndexFromSettings()
{
  std::string currentScreen = CServiceBroker::GetSettingsComponent()->GetSettings()->GetString(CSettings::SETTING_VIDEOSCREEN_MONITOR);

  int screenIdx = 0;
  if (currentScreen == CONST_EXTERNAL)
  {
    if ([[UIScreen screens] count] > 1)
    {
      screenIdx = 1;
    }
    else// screen 1 is setup but not connected
    {
      // force internal screen
      MoveToTouchscreen();
    }
  }

  return screenIdx;
}

CWinSystemIOS::CWinSystemIOS() : CWinSystemBase()
{
  m_bIsBackgrounded = false;
  m_pDisplayLink = new CADisplayLinkWrapper;
  m_pDisplayLink->callbackClass = [[IOSDisplayLinkCallback alloc] init];
  m_winEvents = std::make_unique<CWinEventsIOS>();

  CAESinkDARWINIOS::Register();
}

CWinSystemIOS::~CWinSystemIOS()
{
  delete m_pDisplayLink;
}

bool CWinSystemIOS::InitWindowSystem()
{
	return CWinSystemBase::InitWindowSystem();
}

bool CWinSystemIOS::DestroyWindowSystem()
{
  return true;
}

bool CWinSystemIOS::CreateNewWindow(const std::string& name, bool fullScreen, RESOLUTION_INFO& res)
{
  //NSLog(@"%s", __PRETTY_FUNCTION__);

  if(!SetFullScreen(fullScreen, res, false))
    return false;

  [g_xbmcController setFramebuffer];

  m_bWindowCreated = true;

  m_eglext  = " ";

  const char *tmpExtensions = (const char*) glGetString(GL_EXTENSIONS);
  if (tmpExtensions != NULL)
  {
    m_eglext += tmpExtensions;
  }

  m_eglext += " ";

  CLog::Log(LOGDEBUG, "EGL_EXTENSIONS:{}", m_eglext);

  // register platform dependent objects
  CDVDFactoryCodec::ClearHWAccels();
  VTB::CDecoder::Register();
  VIDEOPLAYER::CRendererFactory::ClearRenderer();
  CLinuxRendererGLES::Register();
  CRendererVTB::Register();
  VIDEOPLAYER::CProcessInfoIOS::Register();
  RETRO::CRPProcessInfoIOS::Register();
  RETRO::CRPProcessInfoIOS::RegisterRendererFactory(new RETRO::CRendererFactoryOpenGLES);
  CScreenshotSurfaceGLES::Register();

  return true;
}

bool CWinSystemIOS::DestroyWindow()
{
  return true;
}

bool CWinSystemIOS::ResizeWindow(int newWidth, int newHeight, int newLeft, int newTop)
{
  //NSLog(@"%s", __PRETTY_FUNCTION__);

  if (m_nWidth != newWidth || m_nHeight != newHeight)
  {
    m_nWidth  = newWidth;
    m_nHeight = newHeight;
  }

  CRenderSystemGLES::ResetRenderSystem(newWidth, newHeight);

  return true;
}

bool CWinSystemIOS::SetFullScreen(bool fullScreen, RESOLUTION_INFO& res, bool blankOtherDisplays)
{
  //NSLog(@"%s", __PRETTY_FUNCTION__);

  m_nWidth      = res.iWidth;
  m_nHeight     = res.iHeight;
  m_bFullScreen = fullScreen;

  CLog::Log(LOGDEBUG, "About to switch to {} x {}", m_nWidth, m_nHeight);
  SwitchToVideoMode(res.iWidth, res.iHeight, static_cast<double>(res.fRefreshRate));
  CRenderSystemGLES::ResetRenderSystem(res.iWidth, res.iHeight);

  return true;
}

UIScreenMode *getModeForResolution(int width, int height, unsigned int screenIdx)
{
  auto screen = UIScreen.screens[screenIdx];
  for (UIScreenMode* mode in screen.availableModes)
  {
    //for main screen also find modes where width and height are
    //exchanged (because of the 90°degree rotated buildinscreens)
    auto modeSize = mode.size;
    if ((modeSize.width == width && modeSize.height == height) ||
        (screenIdx == 0 && modeSize.width == height && modeSize.height == width))
    {
      CLog::Log(LOGDEBUG, "Found matching mode: {} x {}", modeSize.width, modeSize.height);
      return mode;
    }
  }
  CLog::Log(LOGERROR,"No matching mode found!");
  return nil;
}

bool CWinSystemIOS::SwitchToVideoMode(int width, int height, double refreshrate)
{
  bool ret = false;
  int screenIdx = GetDisplayIndexFromSettings();

  // Scene geometry, not a physical display mode, determines the internal
  // drawable. Switching a screen mode here would undo fold/window resizing.
  if (screenIdx == 0)
    return true;

  //get the mode to pass to the controller
  UIScreenMode *newMode = getModeForResolution(width, height, screenIdx);

  if(newMode)
  {
    ret = [g_xbmcController changeScreen:screenIdx withMode:newMode];
  }
  return ret;
}

bool CWinSystemIOS::GetScreenResolution(int* w, int* h, double* fps, int screenIdx)
{
  UIScreen *screen = [[UIScreen screens] objectAtIndex:screenIdx];
  CGSize screenSize = [screen currentMode].size;
  *w = screenSize.width;
  *h = screenSize.height;
  *fps = 0.0;

  //if current mode is 0x0 (happens with external screens which aren't active)
  //then use the preferred mode
  if(*h == 0 || *w ==0)
  {
    UIScreenMode *firstMode = [screen preferredMode];
    *w = firstMode.size.width;
    *h = firstMode.size.height;
  }

  // for mainscreen use the eagl bounds from xbmcController
  // because mainscreen is might be 90° rotate dependend on
  // the device and eagl gives the correct values in all cases.
  if(screenIdx == 0)
  {
    if (![[IOSScreenManager sharedInstance] isExternalScreen])
    {
      const CGSize size = [g_xbmcController getScreenSize];
      m_internalTouchscreenResolutionWidth = size.width;
      m_internalTouchscreenResolutionHeight = size.height;
    }

    *w = m_internalTouchscreenResolutionWidth;
    *h = m_internalTouchscreenResolutionHeight;
  }
  CLog::Log(LOGDEBUG, "Current resolution Screen: {} with {} x {}", screenIdx, *w, *h);
  return true;
}

void CWinSystemIOS::UpdateResolutions()
{
  // Add display resolution
  int w, h;
  double fps;
  CWinSystemBase::UpdateResolutions();

  int screenIdx = GetDisplayIndexFromSettings();

  //first screen goes into the current desktop mode
  if(GetScreenResolution(&w, &h, &fps, screenIdx))
    UpdateDesktopResolution(CDisplaySettings::GetInstance().GetResolutionInfo(RES_DESKTOP), screenIdx == 0 ? CONST_TOUCHSCREEN : CONST_EXTERNAL, w, h, fps, 0);

  CDisplaySettings::GetInstance().ClearCustomResolutions();

  //now just fill in the possible resolutions for the attached screens
  //and push to the resolution info vector
  FillInVideoModes(screenIdx);
}

void CWinSystemIOS::FillInVideoModes(int screenIdx)
{
  // Add full screen settings for additional monitors
  RESOLUTION_INFO res;
  int w, h;
  // atm we don't get refreshrate info from iOS
  // but this may change in the future. In that case
  // we will adapt this code for filling some
  // useful info into this local var :)
  double refreshrate = 0.0;
  //screen 0 is mainscreen - 1 has to be the external one...
  UIScreen *aScreen = [[UIScreen screens]objectAtIndex:screenIdx];
  //found external screen
  for ( UIScreenMode *mode in [aScreen availableModes] )
  {
    w = mode.size.width;
    h = mode.size.height;

    UpdateDesktopResolution(res, screenIdx == 0 ? CONST_TOUCHSCREEN : CONST_EXTERNAL, w, h, refreshrate, 0);
    CLog::Log(LOGINFO, "Found possible resolution for display {} with {} x {}", screenIdx, w, h);

    CServiceBroker::GetWinSystem()->GetGfxContext().ResetOverscan(res);
    CDisplaySettings::GetInstance().AddResolutionInfo(res);
  }
}

bool CWinSystemIOS::IsExtSupported(const char* extension) const
{
  if(strncmp(extension, "EGL_", 4) != 0)
    return CRenderSystemGLES::IsExtSupported(extension);

  std::string name;

  name  = " ";
  name += extension;
  name += " ";

  return m_eglext.find(name) != std::string::npos;
}

bool CWinSystemIOS::BeginRender()
{
  bool rtn;

  if (![g_xbmcController setFramebuffer])
    return false;

  rtn = CRenderSystemGLES::BeginRender();
  return rtn;
}

void CWinSystemIOS::OnDrawableResized(int width, int height)
{
  if (width <= 0 || height <= 0 || (m_nWidth == width && m_nHeight == height))
    return;

  const bool external = [[IOSScreenManager sharedInstance] isExternalScreen];
  if (!external)
  {
    m_internalTouchscreenResolutionWidth = width;
    m_internalTouchscreenResolutionHeight = height;
  }
  auto& desktop = CDisplaySettings::GetInstance().GetResolutionInfo(RES_DESKTOP);
  UpdateDesktopResolution(desktop, external ? CONST_EXTERNAL : CONST_TOUCHSCREEN,
                          width, height, desktop.fRefreshRate, 0);
  GetGfxContext().ResetOverscan(desktop);
  [g_xbmcController setGUIInsetsFromMainThread:NO];
  GetGfxContext().SetVideoResolution(RES_DESKTOP, true);
  CLog::Log(LOGINFO, "iOS drawable resized to {} x {}", width, height);
}

bool CWinSystemIOS::EndRender()
{
  bool rtn;

  rtn = CRenderSystemGLES::EndRender();
  return rtn;
}

void CWinSystemIOS::Register(IDispResource *resource)
{
  std::unique_lock<CCriticalSection> lock(m_resourceSection);
  m_resources.push_back(resource);
}

void CWinSystemIOS::Unregister(IDispResource* resource)
{
  std::unique_lock<CCriticalSection> lock(m_resourceSection);
  std::vector<IDispResource*>::iterator i = find(m_resources.begin(), m_resources.end(), resource);
  if (i != m_resources.end())
    m_resources.erase(i);
}

void CWinSystemIOS::OnAppFocusChange(bool focus)
{
  std::unique_lock<CCriticalSection> lock(m_resourceSection);
  m_bIsBackgrounded = !focus;
  CLog::Log(LOGDEBUG, "CWinSystemIOS::OnAppFocusChange: {}", focus ? 1 : 0);
  for (std::vector<IDispResource *>::iterator i = m_resources.begin(); i != m_resources.end(); i++)
    (*i)->OnAppFocusChange(focus);
}

//--------------------------------------------------------------
//-------------------DisplayLink stuff
@implementation IOSDisplayLinkCallback
@synthesize _videoSyncImpl;
//--------------------------------------------------------------
- (void) runDisplayLink
{
  @autoreleasepool
  {
    if (_videoSyncImpl != nil)
    {
      _videoSyncImpl->IosVblankHandler();
    }
  }
}
@end

bool CWinSystemIOS::InitDisplayLink(CVideoSyncIos *syncImpl)
{
  //init with the appropriate display link for the
  //used screen
  if([[IOSScreenManager sharedInstance] isExternalScreen])
  {
    fprintf(stderr,"InitDisplayLink on external");
  }
  else
  {
    fprintf(stderr,"InitDisplayLink on internal");
  }

  unsigned int currentScreenIdx = [[IOSScreenManager sharedInstance] GetScreenIdx];
  UIScreen * currentScreen = [[UIScreen screens] objectAtIndex:currentScreenIdx];
  [m_pDisplayLink->callbackClass SetVideoSyncImpl:syncImpl];
  m_pDisplayLink->impl = [currentScreen displayLinkWithTarget:m_pDisplayLink->callbackClass selector:@selector(runDisplayLink)];

  [m_pDisplayLink->impl setPreferredFramesPerSecond:0];
  [m_pDisplayLink->impl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
  return m_pDisplayLink->impl != nil;
}

void CWinSystemIOS::DeinitDisplayLink(void)
{
  if (m_pDisplayLink->impl)
  {
    [m_pDisplayLink->impl invalidate];
    m_pDisplayLink->impl = nil;
    [m_pDisplayLink->callbackClass SetVideoSyncImpl:nil];
  }
}
//------------DisplayLink stuff end
//--------------------------------------------------------------

void CWinSystemIOS::PresentRender(bool rendered, bool videoLayer)
{
  const bool nativeVideo = IOSNativeVideoRenderingActive();
  bool videoOnly = nativeVideo && !rendered && !IOSIsPictureInPictureActive() &&
      GetGfxContext().IsFullScreenVideo() && !GetGfxContext().GetStereoMode() &&
      !CServiceBroker::GetDataCacheCore().GetGuiRender() &&
      !CServiceBroker::GetGUI()->GetWindowManager().HasVisibleControls();
  // Optional finite A/B/A/B experiment in a single uninterrupted playback.
  // Normal launches never take this path. After 90 seconds it stays enabled.
  static const bool compareComposition = std::getenv("KODI_NATIVE_COMPOSITION_AB") != nullptr;
  if (compareComposition && nativeVideo)
  {
    static const auto started = std::chrono::steady_clock::now();
    const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - started).count();
    if (seconds < 30 || (seconds >= 60 && seconds < 90))
      videoOnly = false;
  }
  IOSSetNativeVideoOnly(videoOnly);
  // With no GL swap there is no vsync wait. The generic idle delay is 40ms,
  // which would starve 50/60fps native playback; removing it without a paced
  // wait would instead busy-loop. Account for work already done this tick.
  if (!rendered && nativeVideo)
  {
    double fps = GetGfxContext().GetFPS();
    if (!std::isfinite(fps))
      fps = 60.0;
    fps = std::clamp(fps, 60.0, 240.0);
    const auto interval = std::chrono::duration_cast<std::chrono::steady_clock::duration>(
        std::chrono::duration<double>(1.0 / fps));
    std::this_thread::sleep_until(m_lastNativeFrameTick + interval);
  }
  CRenderSystemGLES::PresentRender(rendered, videoLayer || nativeVideo);
  const auto now = std::chrono::steady_clock::now();
  m_lastNativeFrameTick = now;

  // Opt-in aggregate counters for on-device cadence/power investigations.
  // No per-frame logs and no stream identifiers are recorded.
  static const bool collectStats = std::getenv("KODI_NATIVE_RENDER_STATS") != nullptr;
  if (collectStats && nativeVideo)
  {
    const auto frames = IOSNativeVideoEnqueuedFrames();
    if (m_nativeStatsStart == std::chrono::steady_clock::time_point{})
    {
      m_nativeStatsStart = now;
      m_nativeStatsFrames = frames;
      m_nativeStatsTicks = m_nativeStatsGui = 0;
    }
    ++m_nativeStatsTicks;
    m_nativeStatsGui += rendered;
    const double seconds = std::chrono::duration<double>(now - m_nativeStatsStart).count();
    if (seconds >= 10.0)
    {
      CLog::Log(LOGINFO, "iOS native cadence: video={:.2f} fps, GUI={:.2f} fps, loop={:.2f} Hz",
                (frames - m_nativeStatsFrames) / seconds, m_nativeStatsGui / seconds,
                m_nativeStatsTicks / seconds);
      m_nativeStatsStart = {};
    }
  }
  else
    m_nativeStatsStart = {};
}

void CWinSystemIOS::PresentRenderImpl(bool rendered)
{
  //glFlush;
  if (rendered)
    [g_xbmcController presentFramebuffer];
}

bool CWinSystemIOS::HasCursor()
{
  // apple touch devices
  return false;
}

void CWinSystemIOS::NotifyAppActiveChange(bool bActivated)
{
  if (bActivated && m_bWasFullScreenBeforeMinimize && !CServiceBroker::GetWinSystem()->GetGfxContext().IsFullScreenRoot())
    CServiceBroker::GetAppMessenger()->PostMsg(TMSG_TOGGLEFULLSCREEN);
}

bool CWinSystemIOS::Minimize()
{
  m_bWasFullScreenBeforeMinimize = CServiceBroker::GetWinSystem()->GetGfxContext().IsFullScreenRoot();
  if (m_bWasFullScreenBeforeMinimize)
    CServiceBroker::GetAppMessenger()->PostMsg(TMSG_TOGGLEFULLSCREEN);

  return true;
}

bool CWinSystemIOS::Restore()
{
  return false;
}

bool CWinSystemIOS::Hide()
{
  return true;
}

bool CWinSystemIOS::Show(bool raise)
{
  return true;
}

CVEAGLContext CWinSystemIOS::GetEAGLContextObj()
{
  return [g_xbmcController getEAGLContextObj];
}

std::vector<std::string> CWinSystemIOS::GetConnectedOutputs()
{
  std::vector<std::string> outputs;
  outputs.emplace_back("Default");
  outputs.emplace_back(CONST_TOUCHSCREEN);
  if ([[UIScreen screens] count] > 1)
  {
    outputs.emplace_back(CONST_EXTERNAL);
  }

  return outputs;
}

void CWinSystemIOS::MoveToTouchscreen()
{
  CDisplaySettings::GetInstance().SetMonitor(CONST_TOUCHSCREEN);
}

std::unique_ptr<CVideoSync> CWinSystemIOS::GetVideoSync(CVideoReferenceClock* clock)
{
  std::unique_ptr<CVideoSync> pVSync(new CVideoSyncIos(clock, *this));
  return pVSync;
}

bool CWinSystemIOS::MessagePump()
{
  return m_winEvents->MessagePump();
}
