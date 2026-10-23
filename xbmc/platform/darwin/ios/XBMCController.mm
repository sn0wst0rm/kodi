/*
 *  Copyright (C) 2010-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "XBMCController.h"

#include "CompileInfo.h"
#include "FileItem.h"
#include "ServiceBroker.h"
#include "Util.h"
#include "application/AppInboundProtocol.h"
#include "application/ApplicationComponents.h"
#include "application/Application.h"
#include "application/ApplicationPlayer.h"
#include "cores/VideoPlayer/Interface/StreamInfo.h"
#include "cores/DataCacheCore.h"
#include "cores/AudioEngine/Interfaces/AE.h"
#include "filesystem/SpecialProtocol.h"
#include "guilib/GUIControl.h"
#include "guilib/GUIComponent.h"
#include "guilib/GUIDialog.h"
#include "guilib/GUIWindowManager.h"
#include "guilib/WindowIDs.h"
#include "input/actions/Action.h"
#include "input/actions/ActionIDs.h"
#include "input/keyboard/XBMC_keysym.h"
#include "input/touch/generic/GenericTouchActionHandler.h"
#include "messaging/ApplicationMessenger.h"
#include "music/tags/MusicInfoTag.h"
#include "playlists/PlayList.h"
#include "settings/AdvancedSettings.h"
#include "settings/DisplaySettings.h"
#include "settings/Settings.h"
#include "settings/SettingsComponent.h"
#include "settings/lib/ISettingCallback.h"
#include "settings/lib/Setting.h"
#include "threads/Event.h"
#include "utils/StringUtils.h"
#include "utils/TimeUtils.h"
#include "utils/URIUtils.h"
#include "utils/log.h"
#include "windowing/XBMC_events.h"
#import "windowing/ios/WinSystemIOS.h"

#import "platform/darwin/NSLogDebugHelpers.h"
#import "platform/darwin/ios-common/DarwinEmbedNowPlayingInfoManager.h"
#import "platform/darwin/ios/IOSEAGLView.h"
#include "platform/darwin/ios/IOSHDRVideo.h"
#include "platform/darwin/ios/IOSPlaybackPolicy.h"
#import "platform/darwin/ios/IOSScreenManager.h"
#import "platform/darwin/ios/XBMCApplication.h"

#define id _id
#include "TextureCache.h"
#undef id

#include <math.h>
#include <algorithm>
#include <mutex>
#include <atomic>
#include <functional>
#include <signal.h>

#import <AVFoundation/AVAudioSession.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVSampleBufferDisplayLayer.h>
#import <AVFoundation/AVSampleBufferVideoRenderer.h>
#include <sys/resource.h>

#ifndef M_PI
#define M_PI 3.1415926535897932384626433832795028842
#endif
#define RADIANS_TO_DEGREES(radians) ((radians) * (180.0 / M_PI))

XBMCController *g_xbmcController;

namespace
{
struct IOSHDRFrame
{
  IOSHDRFrame(CVPixelBufferRef image) : buffer(CVPixelBufferRetain(image)) {}
  ~IOSHDRFrame() { CVPixelBufferRelease(buffer); }
  CVPixelBufferRef buffer;
  uint64_t session{0};
  IOSHDRVideoMetadata metadata;
  std::shared_ptr<IOSSubtitleBitmap> subtitles;
  CGRect source;
  CGRect destination;
  unsigned int orientation{0};
};

// A single latest-frame slot bounds both retained decoder surfaces and UIKit
// work when its thread is busy. No render/graphics lock waits on the main queue.
std::mutex hdrMutex;
std::shared_ptr<IOSHDRFrame> hdrPendingFrame;
uint64_t hdrSessionCounter{0};
uint64_t hdrActiveSession{0};
bool hdrDeliveryScheduled{false};
std::atomic_bool pipActive{false};
void ScheduleHDRDelivery(); // caller holds hdrMutex
}

bool IOSSupportsHDRVideo()
{
  if (@available(iOS 17.0, *))
    return true;
  return false;
}

bool IOSIsTenBitVideo(CVPixelBufferRef buffer)
{
  if (!buffer)
    return false;
  OSType format = CVPixelBufferGetPixelFormatType(buffer);
  return format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
         format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
}

uint64_t IOSBeginHDRVideo()
{
  std::lock_guard<std::mutex> lock(hdrMutex);
  hdrActiveSession = ++hdrSessionCounter;
  hdrPendingFrame.reset();
  ScheduleHDRDelivery();
  return hdrActiveSession;
}

void IOSPresentHDRVideo(uint64_t session, CVPixelBufferRef buffer,
                        const IOSHDRVideoMetadata& metadata, CGRect source, CGRect destination,
                        unsigned int orientation, std::shared_ptr<IOSSubtitleBitmap> subtitles)
{
  if (!session || !buffer || CGRectIsEmpty(source) || CGRectIsEmpty(destination))
    return;
  auto frame = std::make_shared<IOSHDRFrame>(buffer);
  frame->session = session;
  frame->metadata = metadata;
  frame->source = source;
  frame->destination = destination;
  frame->orientation = orientation;
  frame->subtitles = std::move(subtitles);
  std::lock_guard<std::mutex> lock(hdrMutex);
  if (session != hdrActiveSession)
    return;
  hdrPendingFrame = std::move(frame);
  ScheduleHDRDelivery();
}

void IOSEndHDRVideo(uint64_t session)
{
  std::lock_guard<std::mutex> lock(hdrMutex);
  if (!session || session != hdrActiveSession)
    return;
  hdrActiveSession = 0;
  hdrPendingFrame.reset();
  ScheduleHDRDelivery();
}

// Resolve the current dialog on Kodi's GUI thread, including taps made while
// a modal dialog is running. Never take the graphics lock on UIKit's thread.
static void ToggleFoldWindow(int windowId)
{
  struct ToggleRequest
  {
    KODI::MESSAGING::ThreadMessageCallback message;
    int window;
  };
  auto* request = new ToggleRequest;
  request->window = windowId;
  request->message.userptr = request;
  request->message.callback = [](void* context) {
    std::unique_ptr<ToggleRequest> request(static_cast<ToggleRequest*>(context));
    auto* gui = CServiceBroker::GetGUI();
    if (!gui)
      return;
    auto& manager = gui->GetWindowManager();
    CGUIWindow* window = manager.GetWindow(request->window);
    if (!window)
      return;
    if (manager.IsWindowActive(request->window))
    {
      if (window->IsDialog())
        static_cast<CGUIDialog*>(window)->Close();
      else
        manager.PreviousWindow();
    }
    else
      manager.ActivateWindow(request->window);
  };
  CServiceBroker::GetAppMessenger()->PostMsg(TMSG_CALLBACK, -1, -1, &request->message);
}

// Player/GUI queries run on Kodi's thread. UIKit never waits for its locks.
static void PostFoldTask(std::function<void()> task)
{
  struct Request
  {
    KODI::MESSAGING::ThreadMessageCallback message;
    std::function<void()> task;
  };
  auto* request = new Request;
  request->task = std::move(task);
  request->message.userptr = request;
  request->message.callback = [](void* context) {
    std::unique_ptr<Request> request(static_cast<Request*>(context));
    request->task();
  };
  CServiceBroker::GetAppMessenger()->PostMsg(TMSG_CALLBACK, -1, -1, &request->message);
}

struct FoldPlaybackSettings
{
  std::string path;
  bool playing{false};
  bool canTempo{false};
  float tempo{1};
  int selected{-1};
  std::vector<VideoStreamInfo> streams;
};

class DebugLogSharingPresenter : ISettingCallback
{
public:
  DebugLogSharingPresenter() : ISettingCallback()
  {
    CServiceBroker::GetSettingsComponent()->GetSettings()->RegisterCallback(
        this, std::set<std::string>{CSettings::SETTING_DEBUG_SHARE_LOG});
  }
  virtual ~DebugLogSharingPresenter()
  {
    CServiceBroker::GetSettingsComponent()->GetSettings()->UnregisterCallback(this);
  }

  void OnSettingAction(const std::shared_ptr<const CSetting>& setting) override
  {
    if (!setting || setting->GetId() != CSettings::SETTING_DEBUG_SHARE_LOG)
      return;

    auto lowerAppName = std::string{CCompileInfo::GetAppName()};
    StringUtils::ToLower(lowerAppName);
    auto path = URIUtils::AddFileToFolder(CSpecialProtocol::TranslatePath("special://logpath/"),
                                          lowerAppName + ".log");

    dispatch_async(dispatch_get_main_queue(), ^{
      auto infoDic = NSBundle.mainBundle.infoDictionary;
      auto subject = [NSString
          stringWithFormat:@"iOS log - Kodi %@ %@", infoDic[@"CFBundleShortVersionString"],
                           infoDic[static_cast<NSString*>(kCFBundleVersionKey)]];

      auto activityVc = [[UIActivityViewController alloc]
          initWithActivityItems:@[ [NSURL fileURLWithPath:@(path.c_str())] ]
          applicationActivities:nil];
      // hacky way to set email subject instead of providing UIActivityItemSource object
      [activityVc setValue:subject forKey:@"subject"];

      // make sure that the sharing sheet is displayed on iOS device's screen
      auto iosDeviceWindow = g_xbmcController.view.window;
      if (!iosDeviceWindow)
        return;

      auto rootVc = iosDeviceWindow.rootViewController;
      [rootVc presentViewController:activityVc animated:YES completion:nil];

      // iPad must present the sharing sheet in a popover
      activityVc.popoverPresentationController.sourceView = rootVc.view;
      activityVc.popoverPresentationController.sourceRect = CGRectMake(0.0, 0.0, 10.0, 10.0);
    });
  }
};

//--------------------------------------------------------------
//

@interface XBMCController () <AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>
{
  std::unique_ptr<DebugLogSharingPresenter> m_debugLogSharingPresenter;
  UIStackView* m_foldControls;
  NSArray<UIView*>* m_foldMainRows;
  UIStackView* m_foldSettingsPanel;
  NSInteger m_foldSettingsPage; // 0 controls, 1 settings, 2 quality, 3 speed
  BOOL m_foldSettingsPending;
  std::shared_ptr<FoldPlaybackSettings> m_foldSettingsState;
  NSString* m_foldSettingsSignature;
  UISlider* m_foldScrubber;
  UILabel* m_foldElapsed;
  UIButton* m_foldDuration;
  BOOL m_foldShowRemaining;
  UIButton* m_foldPlayPause;
  UIButton* m_foldPiP;
  AVPictureInPictureController* m_pipController;
  CMTimebaseRef m_pipTimebase;
  NSTimer* m_pipTimer;
  BOOL m_restoringPiP;
  IOSPlaybackPolicy m_audioPolicy;
  uint64_t m_pipStateSession;
  BOOL m_pipStatePaused;
  int64_t m_pipStateMaximum;
  UIButton* m_foldBackward;
  UIButton* m_foldForward;
  NSArray<UIButton*>* m_foldPlaybackButtons;
  NSTimer* m_foldTimer;
  BOOL m_foldScrubbing;
  BOOL m_foldSceneActive;
  int64_t m_foldSeekMinimum;
  int64_t m_foldSeekMaximum;
  BOOL m_hasActiveFold;
  BOOL m_foldPostureConfirmed;
  UIInterfaceOrientation m_lastLandscapeOrientation;
  UIView* m_hdrCanvas;
  UIView* m_hdrCrop;
  AVSampleBufferDisplayLayer* m_hdrLayer;
  std::shared_ptr<IOSHDRFrame> m_hdrDisplayedFrame;
  std::shared_ptr<IOSHDRFrame> m_hdrEnqueuedFrame;
  uint64_t m_hdrPresentedSession;
  CFTimeInterval m_hdrStartedAt;
  BOOL m_hdrReported;
  BOOL m_hdrFailed;
  CGSize m_hdrSceneSize;
  CGSize m_hdrCanvasSize;
}
- (void)rescheduleNetworkAutoSuspend;
- (void)updateFoldPlaybackState;
- (void)updateFoldTimer;
- (void)refreshFoldSettings;
- (void)renderFoldSettings;
- (void)applyHDRPreference;
- (void)displayHDRFrame:(const std::shared_ptr<IOSHDRFrame>&)frame;
- (void)layoutHDRVideo;
- (void)resetHDRVideo;
- (void)updatePictureInPictureState;
@end

bool IOSIsPictureInPictureActive() { return pipActive.load(); }
bool IOSNativeVideoRenderingActive()
{
  std::lock_guard<std::mutex> lock(hdrMutex);
  return hdrActiveSession != 0;
}

namespace
{
void FillVideoMetadata(const IOSHDRFrame& frame)
{
  CVPixelBufferRef pixel = frame.buffer;
  const auto& metadata = frame.metadata;
  const auto setMissing = [pixel](CFStringRef key, CFTypeRef value) {
    if (value && !CVBufferHasAttachment(pixel, key))
      CVBufferSetAttachment(pixel, key, value, kCVAttachmentMode_ShouldPropagate);
  };
  // Preserve per-frame metadata already propagated by VideoToolbox,
  // including Dolby Vision. Fill missing colour/HDR10 signalling only.
  setMissing(kCVImageBufferColorPrimariesKey,
             CVColorPrimariesGetStringForIntegerCodePoint(metadata.primaries));
  setMissing(kCVImageBufferTransferFunctionKey,
             CVTransferFunctionGetStringForIntegerCodePoint(metadata.transfer));
  setMissing(kCVImageBufferYCbCrMatrixKey,
             CVYCbCrMatrixGetStringForIntegerCodePoint(metadata.matrix));
  if (metadata.hasMastering)
  {
    CFDataRef data = CFDataCreate(nullptr, metadata.mastering.data(), metadata.mastering.size());
    setMissing(kCVImageBufferMasteringDisplayColorVolumeKey, data);
    CFRelease(data);
  }
  if (metadata.hasLight)
  {
    CFDataRef data = CFDataCreate(nullptr, metadata.light.data(), metadata.light.size());
    setMissing(kCVImageBufferContentLightLevelInfoKey, data);
    CFRelease(data);
  }
}

void ScheduleHDRDelivery()
{
  if (hdrDeliveryScheduled)
    return;
  hdrDeliveryScheduled = true;
  static dispatch_queue_t deliveryQueue = dispatch_queue_create("org.kodi.native-video", DISPATCH_QUEUE_SERIAL);
  dispatch_async(deliveryQueue, ^{
    @autoreleasepool
    {
      std::shared_ptr<IOSHDRFrame> frame;
      {
        std::lock_guard<std::mutex> lock(hdrMutex);
        frame = std::move(hdrPendingFrame);
      }
      if (frame) FillVideoMetadata(*frame);
      if (frame && frame->subtitles && IOSIsPictureInPictureActive())
      {
        CVPixelBufferRef composited = IOSCompositeVideo(frame->buffer, *frame->subtitles);
        if (composited)
        {
          CVPixelBufferRelease(frame->buffer);
          frame->buffer = composited;
        }
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        bool current;
        {
          std::lock_guard<std::mutex> lock(hdrMutex);
          current = frame && frame->session == hdrActiveSession;
          hdrDeliveryScheduled = false;
          if (hdrPendingFrame) ScheduleHDRDelivery();
        }
        if (current)
          [g_xbmcController displayHDRFrame:frame];
        else if (!IOSNativeVideoRenderingActive())
          [g_xbmcController resetHDRVideo];
      });
    }
  });
}
}

@interface UIApplication (extended)
-(void) terminateWithSuccess;
@end

@implementation XBMCController
@synthesize animating;
@synthesize lastGesturePoint;
@synthesize screenScale;
@synthesize touchBeginSignaled;
@synthesize m_screenIdx;
@synthesize screensize;
@synthesize m_networkAutoSuspendTimer;
@synthesize MPNPInfoManager;
@synthesize nativeKeyboardActive;

- (void)resetHDRVideo
{
  if (@available(iOS 17.0, *))
    [m_hdrLayer.sampleBufferRenderer flushWithRemovalOfDisplayedImage:YES completionHandler:nil];
  m_hdrCanvas.hidden = YES;
  m_hdrDisplayedFrame.reset();
  m_hdrEnqueuedFrame.reset();
  m_hdrPresentedSession = 0;
  m_hdrFailed = NO;
  m_glView.opaque = YES;
  m_glView.layer.opaque = YES;
  if (!IOSNativeVideoRenderingActive())
  {
    [m_pipController stopPictureInPicture];
    m_pipController.contentSource = nil;
    [m_pipTimer invalidate];
    m_pipTimer = nil;
    m_foldPiP.enabled = NO;
  }
}

- (void)layoutHDRVideo
{
  if (!m_hdrDisplayedFrame || !m_hdrCanvas)
    return;
  CGSize sceneSize = self.view.bounds.size;
  CGSize canvasSize = m_glView.bounds.size;
  if (!CGSizeEqualToSize(sceneSize, m_hdrSceneSize) ||
      !CGSizeEqualToSize(canvasSize, m_hdrCanvasSize))
  {
    // Recheck the actual display after opening/closing the Duo. Let EDR settle
    // before reporting; a normal per-frame layout must not reset this timer.
    m_hdrSceneSize = sceneSize;
    m_hdrCanvasSize = canvasSize;
    m_hdrStartedAt = CACurrentMediaTime();
    m_hdrReported = NO;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (m_hdrCanvas.superview != m_glView.superview)
    [m_glView.superview insertSubview:m_hdrCanvas belowSubview:m_glView];
  m_hdrCanvas.transform = CGAffineTransformIdentity;
  m_hdrCanvas.bounds = m_glView.bounds;
  m_hdrCanvas.center = m_glView.center;
  m_hdrCanvas.transform = m_glView.transform;
  const auto& frame = *m_hdrDisplayedFrame;
  CGRect dest = frame.destination;
  CGSize canvas = m_glView.bounds.size;
  m_hdrCrop.frame = CGRectMake(dest.origin.x * canvas.width, dest.origin.y * canvas.height,
                               dest.size.width * canvas.width, dest.size.height * canvas.height);
  CGRect source = frame.source;
  switch (frame.orientation % 360)
  {
    case 90:
      source = CGRectMake(1 - CGRectGetMaxY(source), source.origin.x,
                          source.size.height, source.size.width);
      break;
    case 180:
      source.origin = CGPointMake(1 - CGRectGetMaxX(source), 1 - CGRectGetMaxY(source));
      break;
    case 270:
      source = CGRectMake(source.origin.y, 1 - CGRectGetMaxX(source),
                          source.size.height, source.size.width);
      break;
  }
  CGSize full = CGSizeMake(m_hdrCrop.bounds.size.width / source.size.width,
                           m_hdrCrop.bounds.size.height / source.size.height);
  BOOL quarterTurn = (frame.orientation % 180) != 0;
  m_hdrLayer.bounds = CGRectMake(0, 0, quarterTurn ? full.height : full.width,
                                quarterTurn ? full.width : full.height);
  m_hdrLayer.position = CGPointMake((0.5 - source.origin.x) * full.width,
                                    (0.5 - source.origin.y) * full.height);
  m_hdrLayer.affineTransform = CGAffineTransformMakeRotation(frame.orientation * M_PI / 180.0);
  [CATransaction commit];
}

- (void)displayHDRFrame:(const std::shared_ptr<IOSHDRFrame>&)frame
{
  if (@available(iOS 17.0, *))
  {
    if (!m_glView.window)
      return;
    {
      std::lock_guard<std::mutex> lock(hdrMutex);
      if (frame->session != hdrActiveSession)
        return;
    }
    if (m_hdrPresentedSession != frame->session)
    {
      [self resetHDRVideo];
      m_hdrPresentedSession = frame->session;
      m_hdrStartedAt = CACurrentMediaTime();
      m_hdrReported = NO;
    }
    if (!m_hdrCanvas)
    {
      m_hdrCanvas = [[UIView alloc] init];
      m_hdrCanvas.userInteractionEnabled = NO;
      m_hdrCanvas.clipsToBounds = YES;
      m_hdrCrop = [[UIView alloc] init];
      m_hdrCrop.userInteractionEnabled = NO;
      m_hdrCrop.clipsToBounds = YES;
      [m_hdrCanvas addSubview:m_hdrCrop];
      [m_glView.superview insertSubview:m_hdrCanvas belowSubview:m_glView];
      m_hdrLayer = [[AVSampleBufferDisplayLayer alloc] init];
      m_hdrLayer.videoGravity = AVLayerVideoGravityResize;
      [self applyHDRPreference];
      [m_hdrCrop.layer addSublayer:m_hdrLayer];
      CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &m_pipTimebase);
      m_hdrLayer.controlTimebase = m_pipTimebase;
      if ([AVPictureInPictureController isPictureInPictureSupported])
      {
        m_pipController = [[AVPictureInPictureController alloc] initWithContentSource:
            [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:m_hdrLayer
                playbackDelegate:self]];
        m_pipController.delegate = self;
        m_pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
      }
    }
    if (m_pipController && !m_pipController.contentSource)
      m_pipController.contentSource = [[AVPictureInPictureControllerContentSource alloc]
          initWithSampleBufferDisplayLayer:m_hdrLayer playbackDelegate:self];
    if (!m_pipTimer)
    {
      __weak XBMCController* weakSelf = self;
      m_pipTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* timer) {
        [weakSelf updatePictureInPictureState];
      }];
      m_pipTimer.tolerance = 0.1;
      [[NSRunLoop mainRunLoop] addTimer:m_pipTimer forMode:NSRunLoopCommonModes];
      [self updatePictureInPictureState];
    }
    bool sameImage = m_hdrEnqueuedFrame && m_hdrEnqueuedFrame->buffer == frame->buffer;
    const bool dynamicRangeChanged = !m_hdrDisplayedFrame ||
        frame->metadata.transfer != m_hdrDisplayedFrame->metadata.transfer ||
        frame->metadata.hasLight != m_hdrDisplayedFrame->metadata.hasLight ||
        frame->metadata.light != m_hdrDisplayedFrame->metadata.light ||
        frame->metadata.hasMastering != m_hdrDisplayedFrame->metadata.hasMastering ||
        frame->metadata.mastering != m_hdrDisplayedFrame->metadata.mastering;
    m_hdrDisplayedFrame = frame;
    if (dynamicRangeChanged)
      [self applyHDRPreference];
    [self layoutHDRVideo];
    auto* renderer = m_hdrLayer.sampleBufferRenderer;
    if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed ||
        renderer.requiresFlushToResumeDecoding)
    {
      if (!m_hdrFailed)
        CLog::Log(LOGWARNING, "iOS HDR: resetting video renderer after error {}",
                  static_cast<long>(renderer.error.code));
      m_hdrFailed = YES;
      [renderer flush];
      sameImage = false;
    }
    if (!sameImage && renderer.readyForMoreMediaData)
    {
      CVPixelBufferRef pixel = frame->buffer;
      CMVideoFormatDescriptionRef format = nullptr;
      CMSampleBufferRef sample = nullptr;
      OSStatus result = CMVideoFormatDescriptionCreateForImageBuffer(nullptr, pixel, &format);
      if (result == noErr)
      {
        CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimebaseGetTime(m_pipTimebase), kCMTimeInvalid};
        result = CMSampleBufferCreateReadyWithImageBuffer(nullptr, pixel, format, &timing, &sample);
        CFRelease(format);
      }
      if (result == noErr)
      {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
                             kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        [renderer enqueueSampleBuffer:sample];
        CFRelease(sample);
        m_hdrEnqueuedFrame = frame;
        m_hdrCanvas.hidden = NO;
        m_glView.opaque = NO;
        m_glView.layer.opaque = NO;
      }
      else if (!m_hdrFailed)
      {
        CLog::Log(LOGERROR, "iOS HDR: could not wrap decoded pixel buffer ({})", result);
        m_hdrFailed = YES;
      }
    }
    if (!m_hdrReported && CACurrentMediaTime() - m_hdrStartedAt >= 3)
    {
      UIScreen* screen = m_hdrCanvas.window.windowScene.screen;
      CLog::Log(LOGINFO,
          "iOS HDR: native renderer status={}, pixelFormat={:#x}, transfer={}, primaries={}, "
          "mastering={}, light={}, EDR current={:.2f} potential={:.2f}, "
          "scene={:.0f}x{:.0f}, canvas={:.0f}x{:.0f}, tabletop={}, "
          "HDR requested={}, content headroom={:.2f}, pixel transfer={}, brightness={:.2f}, thermal={}",
          static_cast<int>(renderer.status), CVPixelBufferGetPixelFormatType(frame->buffer),
          frame->metadata.transfer, frame->metadata.primaries,
          !!CVBufferHasAttachment(frame->buffer, kCVImageBufferMasteringDisplayColorVolumeKey),
          !!CVBufferHasAttachment(frame->buffer, kCVImageBufferContentLightLevelInfoKey),
          screen.currentEDRHeadroom, screen.potentialEDRHeadroom,
          self.view.bounds.size.width, self.view.bounds.size.height,
          m_glView.bounds.size.width, m_glView.bounds.size.height, !m_foldControls.hidden,
          [self foldSourceIsHDR] && [self foldHDREnabled],
          [self foldSourceIsHDR] ? IOSHDRContentHeadroom(frame->metadata) : 1.0,
          CVTransferFunctionGetIntegerCodePointForString(static_cast<CFStringRef>(
              CVBufferGetAttachment(frame->buffer, kCVImageBufferTransferFunctionKey, nullptr))),
          screen.brightness, static_cast<long>(NSProcessInfo.processInfo.thermalState));
      m_hdrReported = YES;
    }
  }
}
//--------------------------------------------------------------
- (void) sendKeypressEvent: (XBMC_Event) event
{
  std::shared_ptr<CAppInboundProtocol> appPort = CServiceBroker::GetAppPort();

  if (appPort)
  {
    event.type = XBMC_KEYDOWN;
    appPort->OnEvent(event);

    event.type = XBMC_KEYUP;
    appPort->OnEvent(event);
  }
}

// START OF UIKeyInput protocol
- (BOOL)hasText
{
  return NO;
}

- (void)insertText:(NSString *)text
{
  // in case the native touch keyboard is active
  // don't do anything here
  // we are only supposed to be called when
  // using an external bt keyboard...
  if (nativeKeyboardActive)
  {
    return;
  }

  XBMC_Event newEvent = {};
  unichar currentKey = [text characterAtIndex:0];

  // handle upper case letters
  if (currentKey >= 'A' && currentKey <= 'Z')
  {
    newEvent.key.keysym.mod = XBMCKMOD_LSHIFT;
    currentKey += 0x20;// convert to lower case
  }

  // handle return
  if (currentKey == '\n' || currentKey == '\r')
    currentKey = XBMCK_RETURN;

  newEvent.key.keysym.sym = (XBMCKey)currentKey;
  newEvent.key.keysym.unicode = currentKey;

  [self sendKeypressEvent:newEvent];
}

- (void)deleteBackward
{
  [self sendKey:XBMCK_BACKSPACE];
}
// END OF UIKeyInput protocol

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
  // Let UIKit handle physical rotation and the system rotation lock. The GL
  // canvas stays landscape even when a resizable scene has portrait bounds.
  return UIInterfaceOrientationMaskAll;
}
- (BOOL)prefersInterfaceOrientationLocked
{
  return NO;
}

- (BOOL)prefersStatusBarHidden
{
  return YES;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation
{
  return UIInterfaceOrientationLandscapeRight;
}

//--------------------------------------------------------------
- (UIInterfaceOrientation) getOrientation
{
	return orientation;
}

-(void)sendKey:(XBMCKey) key
{
  XBMC_Event newEvent = {};

  //newEvent.key.keysym.unicode = key;
  newEvent.key.keysym.sym = key;
  [self sendKeypressEvent:newEvent];

}
//--------------------------------------------------------------
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
  if ([gestureRecognizer isKindOfClass:[UIRotationGestureRecognizer class]] && [otherGestureRecognizer isKindOfClass:[UIPinchGestureRecognizer class]]) {
    return YES;
  }

  if ([gestureRecognizer isKindOfClass:[UISwipeGestureRecognizer class]] && [otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
    return YES;
  }


  return NO;
}
//--------------------------------------------------------------
- (void)addSwipeGesture:(UISwipeGestureRecognizerDirection)direction numTouches : (NSUInteger)numTouches
{
  UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc]
                                          initWithTarget:self action:@selector(handleSwipe:)];

  swipe.delaysTouchesBegan = NO;
  swipe.numberOfTouchesRequired = numTouches;
  swipe.direction = direction;
  swipe.delegate = self;
  [m_glView addGestureRecognizer:swipe];
}
//--------------------------------------------------------------
- (void)addTapGesture:(NSUInteger)numTouches
{
  UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc]
                                                   initWithTarget:self action:@selector(handleTap:)];

  tapGesture.delaysTouchesBegan = NO;
  tapGesture.numberOfTapsRequired = 1;
  tapGesture.numberOfTouchesRequired = numTouches;

  [m_glView addGestureRecognizer:tapGesture];
}
//--------------------------------------------------------------
- (void)createGestureRecognizers
{
  //1 finger single tap
  [self addTapGesture:1];

  //2 finger single tap - right mouse
  //single finger double tap delays single finger single tap - so we
  //go for 2 fingers here - so single finger single tap is instant
  [self addTapGesture:2];

  //3 finger single tap
  [self addTapGesture:3];

  //1 finger single long tap - right mouse - alternative
  UILongPressGestureRecognizer *singleFingerSingleLongTap = [[UILongPressGestureRecognizer alloc]
    initWithTarget:self action:@selector(handleSingleFingerSingleLongTap:)];

  singleFingerSingleLongTap.delaysTouchesBegan = NO;
  singleFingerSingleLongTap.delaysTouchesEnded = NO;
  [m_glView addGestureRecognizer:singleFingerSingleLongTap];

  //triple finger swipe left
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionLeft numTouches:3];

  //double finger swipe left for backspace ... i like this fast backspace feature ;)
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionLeft numTouches:2];

  //single finger swipe left
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionLeft numTouches:1];

  //triple finger swipe right
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionRight numTouches:3];

  //double finger swipe right
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionRight numTouches:2];

  //single finger swipe right
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionRight numTouches:1];

  //triple finger swipe up
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionUp numTouches:3];

  //double finger swipe up
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionUp numTouches:2];

  //single finger swipe up
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionUp numTouches:1];

  //triple finger swipe down
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionDown numTouches:3];

  //double finger swipe down
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionDown numTouches:2];

  //single finger swipe down
  [self addSwipeGesture:UISwipeGestureRecognizerDirectionDown numTouches:1];

  //for pan gestures with one finger
  UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
    initWithTarget:self action:@selector(handlePan:)];

  pan.delaysTouchesBegan = NO;
  pan.maximumNumberOfTouches = 1;
  [m_glView addGestureRecognizer:pan];

  //for zoom gesture
  UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
    initWithTarget:self action:@selector(handlePinch:)];

  pinch.delaysTouchesBegan = NO;
  pinch.delegate = self;
  [m_glView addGestureRecognizer:pinch];

  //for rotate gesture
  UIRotationGestureRecognizer *rotate = [[UIRotationGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(handleRotate:)];

  rotate.delaysTouchesBegan = NO;
  rotate.delegate = self;
  [m_glView addGestureRecognizer:rotate];
}
//--------------------------------------------------------------
- (void) activateKeyboard:(UIView *)view
{
  [self.view addSubview:view];
  m_glView.userInteractionEnabled = NO;
}
//--------------------------------------------------------------
- (void) deactivateKeyboard:(UIView *)view
{
  [view removeFromSuperview];
  m_glView.userInteractionEnabled = YES;
  [self becomeFirstResponder];
}
//--------------------------------------------------------------
- (void) nativeKeyboardActive: (bool)active
{
  nativeKeyboardActive = active;
}
//--------------------------------------------------------------
-(void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
  if( m_glView && [m_glView isXBMCAlive] )//NO GESTURES BEFORE WE ARE UP AND RUNNING
  {
    UITouch *touch = (UITouch *)[[touches allObjects] objectAtIndex:0];
    CGPoint point = [touch locationInView:m_glView];
    point.x *= screenScale;
    point.y *= screenScale;
    CGenericTouchActionHandler::GetInstance().OnSingleTouchStart(point.x, point.y);
  }
}
//--------------------------------------------------------------
-(void)handlePinch:(UIPinchGestureRecognizer*)sender
{
  if( m_glView && [m_glView isXBMCAlive] && sender.numberOfTouches )//NO GESTURES BEFORE WE ARE UP AND RUNNING
  {
    CGPoint point = [sender locationOfTouch:0 inView:m_glView];
    point.x *= screenScale;
    point.y *= screenScale;

    switch(sender.state)
    {
      case UIGestureRecognizerStateBegan:
        CGenericTouchActionHandler::GetInstance().OnTouchGestureStart(point.x, point.y);
        break;
      case UIGestureRecognizerStateChanged:
        CGenericTouchActionHandler::GetInstance().OnZoomPinch(point.x, point.y, [sender scale]);
        break;
      case UIGestureRecognizerStateEnded:
      case UIGestureRecognizerStateCancelled:
        CGenericTouchActionHandler::GetInstance().OnTouchGestureEnd(point.x, point.y, 0, 0, 0, 0);
        break;
      default:
        break;
    }
  }
}
//--------------------------------------------------------------
-(void)handleRotate:(UIRotationGestureRecognizer*)sender
{
  if( m_glView && [m_glView isXBMCAlive] && sender.numberOfTouches )//NO GESTURES BEFORE WE ARE UP AND RUNNING
  {
    CGPoint point = [sender locationOfTouch:0 inView:m_glView];
    point.x *= screenScale;
    point.y *= screenScale;

    switch(sender.state)
    {
      case UIGestureRecognizerStateBegan:
        CGenericTouchActionHandler::GetInstance().OnTouchGestureStart(point.x, point.y);
        break;
      case UIGestureRecognizerStateChanged:
        CGenericTouchActionHandler::GetInstance().OnRotate(point.x, point.y, RADIANS_TO_DEGREES([sender rotation]));
        break;
      case UIGestureRecognizerStateEnded:
        CGenericTouchActionHandler::GetInstance().OnTouchGestureEnd(point.x, point.y, 0, 0, 0, 0);
        break;
      default:
        break;
    }
  }
}
//--------------------------------------------------------------
- (IBAction)handlePan:(UIPanGestureRecognizer *)sender
{
  if( m_glView && [m_glView isXBMCAlive] )//NO GESTURES BEFORE WE ARE UP AND RUNNING
  {
    CGPoint velocity = [sender velocityInView:m_glView];

    if( [sender state] == UIGestureRecognizerStateBegan && sender.numberOfTouches )
    {
      CGPoint point = [sender locationOfTouch:0 inView:m_glView];
      point.x *= screenScale;
      point.y *= screenScale;
      touchBeginSignaled = false;
      lastGesturePoint = point;
    }

    if( [sender state] == UIGestureRecognizerStateChanged && sender.numberOfTouches )
    {
      CGPoint point = [sender locationOfTouch:0 inView:m_glView];
      point.x *= screenScale;
      point.y *= screenScale;
      bool bNotify = false;
      CGFloat yMovement=point.y - lastGesturePoint.y;
      CGFloat xMovement=point.x - lastGesturePoint.x;

      if( xMovement )
      {
        bNotify = true;
      }

      if( yMovement )
      {
        bNotify = true;
      }

      if( bNotify )
      {
        if( !touchBeginSignaled )
        {
          CGenericTouchActionHandler::GetInstance().OnTouchGestureStart((float)point.x, (float)point.y);
          touchBeginSignaled = true;
        }

        CGenericTouchActionHandler::GetInstance().OnTouchGesturePan((float)point.x, (float)point.y,
                                                            (float)xMovement, (float)yMovement,
                                                            (float)velocity.x, (float)velocity.y);
        lastGesturePoint = point;
      }
    }

    if( touchBeginSignaled && ([sender state] == UIGestureRecognizerStateEnded || [sender state] == UIGestureRecognizerStateCancelled))
    {
      //signal end of pan - this will start inertial scrolling with deacceleration in CApplication
      CGenericTouchActionHandler::GetInstance().OnTouchGestureEnd((float)lastGesturePoint.x, (float)lastGesturePoint.y,
                                                             (float)0.0, (float)0.0,
                                                             (float)velocity.x, (float)velocity.y);

      touchBeginSignaled = false;
    }
  }
}
//--------------------------------------------------------------
- (IBAction)handleSwipe:(UISwipeGestureRecognizer *)sender
{
  if( m_glView && [m_glView isXBMCAlive] && sender.numberOfTouches )//NO GESTURES BEFORE WE ARE UP AND RUNNING
  {


    if (sender.state == UIGestureRecognizerStateRecognized)
    {
      CGPoint point = [sender locationOfTouch:0 inView:m_glView];
      point.x *= screenScale;
      point.y *= screenScale;

      TouchMoveDirection direction = TouchMoveDirectionNone;
      switch ([sender direction])
      {
        case UISwipeGestureRecognizerDirectionRight:
          direction = TouchMoveDirectionRight;
          break;
        case UISwipeGestureRecognizerDirectionLeft:
          direction = TouchMoveDirectionLeft;
          break;
        case UISwipeGestureRecognizerDirectionUp:
          direction = TouchMoveDirectionUp;
          break;
        case UISwipeGestureRecognizerDirectionDown:
          direction = TouchMoveDirectionDown;
          break;
      }
      CGenericTouchActionHandler::GetInstance().OnSwipe(direction,
                                                0.0, 0.0,
                                                point.x, point.y, 0, 0,
                                                [sender numberOfTouches]);
    }
  }
}
//--------------------------------------------------------------
- (IBAction)handleTap:(UIGestureRecognizer *)sender
{
  //Allow the tap gesture during init
  //(for allowing the user to tap away any messageboxes during init)
  if( ([m_glView isReadyToRun] && [sender numberOfTouches] == 1) || [m_glView isXBMCAlive])
  {
    CGPoint point = [sender locationOfTouch:0 inView:m_glView];
    point.x *= screenScale;
    point.y *= screenScale;
    //NSLog(@"%s singleTap", __PRETTY_FUNCTION__);
    CGenericTouchActionHandler::GetInstance().OnTap((float)point.x, (float)point.y, [sender numberOfTouches]);
  }
}
//--------------------------------------------------------------
- (IBAction)handleSingleFingerSingleLongTap:(UIGestureRecognizer *)sender
{
  if( m_glView && [m_glView isXBMCAlive] && sender.numberOfTouches)//NO GESTURES BEFORE WE ARE UP AND RUNNING
  {
    CGPoint point = [sender locationOfTouch:0 inView:m_glView];
    point.x *= screenScale;
    point.y *= screenScale;

    if (sender.state == UIGestureRecognizerStateBegan)
    {
      lastGesturePoint = point;
      // mark the control
      //CGenericTouchActionHandler::GetInstance().OnSingleTouchStart((float)point.x, (float)point.y);
    }

    if (sender.state == UIGestureRecognizerStateEnded)
    {
      CGenericTouchActionHandler::GetInstance().OnSingleTouchMove((float)point.x, (float)point.y, point.x - lastGesturePoint.x, point.y - lastGesturePoint.y, 0, 0);
    }

    if (sender.state == UIGestureRecognizerStateEnded)
    {
      CGenericTouchActionHandler::GetInstance().OnLongPress((float)point.x, (float)point.y);
    }
  }
}
//--------------------------------------------------------------
- (id)initWithWindow:(UIWindow*)window
{
  PRINT_SIGNATURE();
  m_screenIdx = 0;
  self = [super init];
  if ( !self )
    return ( nil );

  m_glView = NULL;

  m_bgTask = UIBackgroundTaskInvalid;


  NSNotificationCenter *center;
  center = [NSNotificationCenter defaultCenter];
  [center addObserver: self
             selector: @selector(observeDefaultCenterStuff:)
                 name: nil
               object: nil];

  if (@available(iOS 27.0, *))
  {
    [center addObserver:self selector:@selector(audioSessionNotification:)
        name:AVAudioSessionDidBecomeInactiveNotification object:nil];
    [center addObserver:self selector:@selector(audioSessionNotification:)
        name:AVAudioSessionResumptionRecommendationNotification object:nil];
  }
  else
    [center addObserver:self selector:@selector(audioSessionNotification:)
        name:AVAudioSessionInterruptionNotification object:nil];
  for (NSNotificationName name in @[AVAudioSessionRouteChangeNotification,
      AVAudioSessionMediaServicesWereLostNotification, AVAudioSessionMediaServicesWereResetNotification])
    [center addObserver:self selector:@selector(audioSessionNotification:) name:name object:nil];

  orientation = UIInterfaceOrientationLandscapeLeft;

  g_xbmcController = self;
  MPNPInfoManager = [DarwinEmbedNowPlayingInfoManager new];
  [self attachToWindow:window];

  return self;
}
//--------------------------------------------------------------
- (void)attachToWindow:(UIWindow*)window
{
  // A reconnected scene reuses the engine and playback state.
  if (m_window != window)
    m_window.rootViewController = nil;
  m_window = window;
  m_window.autoresizesSubviews = YES;
  m_window.rootViewController = self;
  [m_window makeKeyAndVisible];
}
//--------------------------------------------------------------
- (void)loadView
{
  [super loadView];
  self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.view.autoresizesSubviews = YES;

  m_glView = [[IOSEAGLView alloc] initWithFrame:self.view.bounds withScreen:m_window.windowScene.screen];
  [[IOSScreenManager sharedInstance] setView:m_glView];
  [m_glView setMultipleTouchEnabled:YES];

  /* Check if screen is Retina */
  screenScale = self.traitCollection.displayScale;

  [self.view addSubview: m_glView];

  [self createGestureRecognizers];
  self.view.backgroundColor = UIColor.blackColor;
  if (@available(iOS 27.1, *))
  {
    __weak XBMCController* weakController = self;
    [self.view addInteraction:[[UIHingeInteraction alloc]
        initWithUpdateHandler:^(UIHingeInteraction* interaction, UIHingeInteractionUpdate* update) {
          XBMCController* controller = weakController;
          if (!controller)
            return;
          // The initial callback is authoritative, even before the first
          // physical fold. A reserved division rect alone is not posture.
          BOOL partiallyOpen = update.hinge && update.hinge.status == UIHingeStatusPartiallyOpen;
          if (controller->m_foldPostureConfirmed != partiallyOpen)
          {
            controller->m_foldPostureConfirmed = partiallyOpen;
            [controller.view setNeedsLayout];
          }
        }]];
  }
  m_foldControls = [[UIStackView alloc] init];
  m_foldControls.axis = UILayoutConstraintAxisVertical;
  m_foldControls.alignment = UIStackViewAlignmentFill;
  m_foldControls.spacing = 16;

  m_foldElapsed = [[UILabel alloc] init];
  m_foldElapsed.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
  m_foldElapsed.textColor = UIColor.lightGrayColor;
  m_foldElapsed.text = @"--:--";
  m_foldDuration = [UIButton buttonWithType:UIButtonTypeSystem];
  m_foldDuration.titleLabel.font = m_foldElapsed.font;
  [m_foldDuration setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
  [m_foldDuration setTitleColor:UIColor.lightGrayColor forState:UIControlStateDisabled];
  [m_foldDuration setTitle:@"--:--" forState:UIControlStateNormal];
  m_foldDuration.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
  [m_foldDuration.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
  m_foldShowRemaining = [NSUserDefaults.standardUserDefaults boolForKey:@"DuoFoldShowRemainingTime"];
  [m_foldDuration addTarget:self action:@selector(foldToggleDuration:)
          forControlEvents:UIControlEventTouchUpInside];
  UIStackView* times = [[UIStackView alloc] initWithArrangedSubviews:@[m_foldElapsed, m_foldDuration]];
  times.distribution = UIStackViewDistributionFillEqually;
  [m_foldControls addArrangedSubview:times];
  [m_foldControls setCustomSpacing:0 afterView:times];

  m_foldScrubber = [[UISlider alloc] init];
  m_foldScrubber.minimumValue = 0;
  m_foldScrubber.maximumValue = 1;
  m_foldScrubber.tintColor = [UIColor colorWithRed:0.05 green:0.65 blue:0.8 alpha:1];
  m_foldScrubber.accessibilityLabel = @"Posizione di riproduzione";
  [m_foldScrubber addTarget:self action:@selector(foldScrubBegan:)
          forControlEvents:UIControlEventTouchDown];
  [m_foldScrubber addTarget:self action:@selector(foldScrubChanged:)
          forControlEvents:UIControlEventValueChanged];
  [m_foldScrubber addTarget:self action:@selector(foldScrubEnded:)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
  [m_foldScrubber addTarget:self action:@selector(foldScrubCancelled:)
          forControlEvents:UIControlEventTouchCancel];
  [m_foldScrubber.heightAnchor constraintEqualToConstant:36].active = YES;
  [m_foldControls addArrangedSubview:m_foldScrubber];

  UIStackView* transport = [[UIStackView alloc] init];
  transport.distribution = UIStackViewDistributionFillEqually;
  transport.spacing = 16;
  NSArray<NSString*>* symbols = @[@"gobackward.10", @"play.fill", @"goforward.10", @"stop.fill"];
  NSArray<NSString*>* labels = @[@"−10 s", @"Riproduci", @"+10 s", @"Stop"];
  const int actions[] = {-10, ACTION_PLAYER_PLAYPAUSE, 10, ACTION_STOP};
  NSMutableArray<UIButton*>* playbackButtons = [[NSMutableArray alloc] init];
  for (NSUInteger i = 0; i < symbols.count; ++i)
  {
    UIButton* button = [self foldButtonWithSymbol:symbols[i] title:labels[i]];
    button.tag = actions[i];
    [button addTarget:self action:@selector(foldControlPressed:) forControlEvents:UIControlEventTouchUpInside];
    [transport addArrangedSubview:button];
    [playbackButtons addObject:button];
    if (i == 0) m_foldBackward = button;
    if (i == 1) m_foldPlayPause = button;
    if (i == 2) m_foldForward = button;
  }
  [m_foldControls addArrangedSubview:transport];

  UIStackView* utilities = [[UIStackView alloc] init];
  utilities.distribution = UIStackViewDistributionFillEqually;
  utilities.spacing = 16;
  UIButton* settings = [self foldButtonWithSymbol:@"gearshape" title:@"Impostazioni"];
  __weak XBMCController* weakSelf = self;
  settings.menu = [UIMenu menuWithChildren:@[
    [UIAction actionWithTitle:@"Impostazioni video" image:[UIImage systemImageNamed:@"film"]
        identifier:nil handler:^(__kindof UIAction* action) {
          [weakSelf openFoldWindow:WINDOW_DIALOG_VIDEO_OSD_SETTINGS];
        }],
    [UIAction actionWithTitle:@"Impostazioni Kodi" image:[UIImage systemImageNamed:@"gearshape"]
        identifier:nil handler:^(__kindof UIAction* action) {
          [weakSelf openFoldWindow:WINDOW_SETTINGS_MENU];
        }]
  ]];
  settings.showsMenuAsPrimaryAction = NO;
  settings.tag = WINDOW_DIALOG_VIDEO_OSD_SETTINGS;
  settings.accessibilityHint = @"Qualità, HDR e velocità; tieni premuto per le impostazioni Kodi";
  [settings addTarget:self action:@selector(foldSettingsPressed:)
      forControlEvents:UIControlEventTouchUpInside];
  [utilities addArrangedSubview:settings];
  NSArray<NSString*>* utilitySymbols = @[@"captions.bubble", @"info.circle", @"globe"];
  NSArray<NSString*>* utilityLabels = @[@"Sottotitoli", @"Info", @"Lingua"];
  const int windows[] = {WINDOW_DIALOG_SUBTITLE_OSD_SETTINGS, 0, WINDOW_DIALOG_AUDIO_OSD_SETTINGS};
  for (NSUInteger i = 0; i < utilitySymbols.count; ++i)
  {
    UIButton* button = [self foldButtonWithSymbol:utilitySymbols[i] title:utilityLabels[i]];
    button.tag = windows[i];
    [button addTarget:self action:@selector(foldUtilityPressed:) forControlEvents:UIControlEventTouchUpInside];
    [utilities addArrangedSubview:button];
    [playbackButtons addObject:button];
  }
  [m_foldControls addArrangedSubview:utilities];
  UIStackView* navigation = [[UIStackView alloc] init];
  navigation.distribution = UIStackViewDistributionFillEqually;
  navigation.spacing = 16;
  UIButton* back = [self foldButtonWithSymbol:@"chevron.backward" title:@"Indietro"];
  back.tag = ACTION_NAV_BACK;
  [back addTarget:self action:@selector(foldControlPressed:) forControlEvents:UIControlEventTouchUpInside];
  [navigation addArrangedSubview:back];
  m_foldPiP = [self foldButtonWithSymbol:@"pip.enter" title:@"PiP"];
  m_foldPiP.accessibilityHint = @"Mostra il video in una finestra mobile";
  m_foldPiP.enabled = NO;
  [m_foldPiP addTarget:self action:@selector(togglePictureInPicture:) forControlEvents:UIControlEventTouchUpInside];
  [navigation addArrangedSubview:m_foldPiP];
  [m_foldControls addArrangedSubview:navigation];
  m_foldMainRows = @[transport, utilities, navigation];
  m_foldSettingsPanel = [[UIStackView alloc] init];
  m_foldSettingsPanel.axis = UILayoutConstraintAxisVertical;
  m_foldSettingsPanel.spacing = 8;
  m_foldSettingsPanel.hidden = YES;
  // Match the three control rows so opening a submenu does not move the video.
  NSLayoutConstraint* panelHeight = [m_foldSettingsPanel.heightAnchor constraintEqualToConstant:236];
  panelHeight.priority = 999; // UIStackView collapses hidden arranged views to zero.
  panelHeight.active = YES;
  [m_foldControls addArrangedSubview:m_foldSettingsPanel];
  m_foldPlaybackButtons = playbackButtons;
  m_foldControls.hidden = YES;
  [self.view addSubview:m_foldControls];
}
//--------------------------------------------------------------
- (UIButton*)foldButtonWithSymbol:(NSString*)symbol title:(NSString*)title
{
  UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
  UIButtonConfiguration* configuration = [UIButtonConfiguration tintedButtonConfiguration];
  configuration.image = [UIImage systemImageNamed:symbol];
  configuration.preferredSymbolConfigurationForImage =
      [UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightMedium];
  configuration.title = title;
  configuration.imagePlacement = NSDirectionalRectEdgeTop;
  configuration.imagePadding = 6;
  configuration.baseForegroundColor = UIColor.whiteColor;
  configuration.baseBackgroundColor = [UIColor colorWithRed:0.05 green:0.4 blue:0.65 alpha:1];
  configuration.titleTextAttributesTransformer = ^NSDictionary*(NSDictionary* incoming) {
    NSMutableDictionary* attributes = [incoming mutableCopy];
    attributes[NSFontAttributeName] = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    return attributes;
  };
  button.configuration = configuration;
  button.accessibilityLabel = title;
  NSLayoutConstraint* height = [button.heightAnchor constraintEqualToConstant:68];
  height.priority = 999;
  height.active = YES;
  return button;
}

- (BOOL)foldHDREnabled
{
  NSNumber* saved = [NSUserDefaults.standardUserDefaults objectForKey:@"DuoHDREnabled"];
  return saved ? saved.boolValue : YES;
}

- (BOOL)foldSourceIsHDR
{
  return m_hdrDisplayedFrame && IOSIsTenBitVideo(m_hdrDisplayedFrame->buffer) &&
      (m_hdrDisplayedFrame->metadata.transfer == 16 || m_hdrDisplayedFrame->metadata.transfer == 18);
}

- (void)applyHDRPreference
{
  const BOOL sourceHDR = [self foldSourceIsHDR];
  const BOOL enabled = sourceHDR && [self foldHDREnabled];
  if (@available(iOS 26.0, *))
  {
    // AVSampleBufferDisplayLayer is not always tagged as HDR automatically.
    // The range preference alone does not activate EDR for untagged contents.
    // Keep the source headroom when HDR is off so CoreAnimation can tone-map.
    m_hdrLayer.contentsHeadroom = sourceHDR ? IOSHDRContentHeadroom(m_hdrDisplayedFrame->metadata) : 1.0;
    m_hdrLayer.preferredDynamicRange = enabled ? CADynamicRangeHigh : CADynamicRangeStandard;
  }
  else if (@available(iOS 17.0, *))
    m_hdrLayer.wantsExtendedDynamicRangeContent = enabled;
  m_hdrReported = NO;
  m_hdrStartedAt = CACurrentMediaTime();
}

- (void)foldHDRChanged:(UISwitch*)sender
{
  if (![self foldSourceIsHDR])
    return;
  [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"DuoHDREnabled"];
  [self applyHDRPreference];
  [self renderFoldSettings];
}

- (void)setFoldSettingsPage:(NSInteger)page
{
  const BOOL wasOpen = m_foldSettingsPage != 0;
  m_foldSettingsPage = page;
  m_foldSettingsSignature = nil;
  for (UIView* row in m_foldMainRows)
    row.hidden = page != 0;
  m_foldSettingsPanel.hidden = page == 0;
  if (wasOpen != (page != 0))
    PostFoldTask([show = page != 0] {
      const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
      auto* gui = CServiceBroker::GetGUI();
      if (!gui) return;
      auto& manager = gui->GetWindowManager();
      auto* dialog = manager.GetWindow<CGUIDialog>(WINDOW_DIALOG_VIDEO_OSD_SETTINGS);
      if (show && player && player->IsPlayingVideo())
      {
        if (!manager.IsWindowActive(WINDOW_DIALOG_VIDEO_OSD_SETTINGS))
          manager.ActivateWindow(WINDOW_DIALOG_VIDEO_OSD_SETTINGS);
      }
      else if (dialog && manager.IsWindowActive(WINDOW_DIALOG_VIDEO_OSD_SETTINGS))
        dialog->Close();
    });
  [self renderFoldSettings];
  if (page)
    [self refreshFoldSettings];
  [self.view setNeedsLayout];
}

- (void)foldSettingsPressed:(UIButton*)sender
{
  if (m_glView.isXBMCAlive)
    [self setFoldSettingsPage:m_foldSettingsPage ? 0 : 1];
}

- (void)refreshFoldSettings
{
  if (m_foldSettingsPending || !m_foldSettingsPage || !m_glView.isXBMCAlive)
    return;
  m_foldSettingsPending = YES;
  __weak XBMCController* weakSelf = self;
  PostFoldTask([weakSelf] {
    auto state = std::make_shared<FoldPlaybackSettings>();
    const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
    state->playing = player && player->IsPlayingVideo();
    if (state->playing)
    {
      state->path = g_application.CurrentFileItem().GetPath();
      state->canTempo = player->SupportsTempo() && !player->IsPassthrough();
      state->tempo = player->GetPlayTempo();
      state->selected = player->GetVideoStream();
      for (int i = 0, count = player->GetVideoStreamCount(); i < count; ++i)
      {
        VideoStreamInfo info;
        player->GetVideoStreamInfo(i, info);
        state->streams.push_back(std::move(info));
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      XBMCController* controller = weakSelf;
      if (!controller) return;
      controller->m_foldSettingsPending = NO;
      controller->m_foldSettingsState = state;
      [controller renderFoldSettings];
    });
  });
}

- (NSString*)foldQualityTitle:(const VideoStreamInfo&)stream details:(BOOL)details
{
  NSString* resolution = stream.height > 0 ? [NSString stringWithFormat:@"%dp", stream.height] : @"Video";
  if (stream.name == "Auto")
    return [NSString stringWithFormat:@"Auto (%@)", resolution];
  NSMutableString* text = [resolution mutableCopy];
  if (details && !stream.codecName.empty())
    [text appendFormat:@" · %@", @(stream.codecName.c_str())];
  if (stream.hdrType != StreamHdrType::HDR_TYPE_NONE)
    [text appendString:@" · HDR"];
  if (details && stream.bitrate > 0)
    [text appendFormat:@" · %.1f Mb/s", stream.bitrate / 1000000.0];
  return text;
}

- (UIButton*)foldSettingRow:(NSString*)title symbol:(NSString*)symbol action:(void (^)(void))action
{
  UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
  UIButtonConfiguration* config = [UIButtonConfiguration tintedButtonConfiguration];
  config.title = title;
  config.image = [UIImage systemImageNamed:symbol];
  config.imagePadding = 12;
  config.baseForegroundColor = UIColor.whiteColor;
  config.baseBackgroundColor = [UIColor colorWithRed:0.05 green:0.4 blue:0.65 alpha:1];
  config.contentInsets = NSDirectionalEdgeInsetsMake(8, 16, 8, 16);
  button.configuration = config;
  button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
  [button.heightAnchor constraintEqualToConstant:53].active = YES;
  if (action)
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction* ignored) { action(); }]
        forControlEvents:UIControlEventTouchUpInside];
  return button;
}

- (void)renderFoldSettings
{
  if (!m_foldSettingsPage)
  {
    // A hidden vertical stack must not retain required row-height constraints.
    for (UIView* view in m_foldSettingsPanel.arrangedSubviews)
    {
      [m_foldSettingsPanel removeArrangedSubview:view];
      [view removeFromSuperview];
    }
    return;
  }
  const auto state = m_foldSettingsState;
  const BOOL playing = state && state->playing;
  const BOOL hdr = playing && [self foldSourceIsHDR];
  // Avoid rebuilding controls under a finger on every timer tick.
  NSMutableString* signature = [NSMutableString stringWithFormat:@"%ld:%d:%d:%d:%d:%g:%d",
      (long)m_foldSettingsPage, playing, hdr, [self foldHDREnabled], state && state->canTempo,
      state ? state->tempo : 1, state ? state->selected : -1];
  if (state)
  {
    [signature appendString:@(state->path.c_str())];
    for (const auto& stream : state->streams)
      [signature appendFormat:@"|%@:%d:%d:%d:%@", @(stream.name.c_str()), stream.width,
          stream.height, stream.bitrate, @(stream.codecName.c_str())];
  }
  if ([signature isEqualToString:m_foldSettingsSignature]) return;
  m_foldSettingsSignature = signature;
  for (UIView* view in m_foldSettingsPanel.arrangedSubviews)
  {
    [m_foldSettingsPanel removeArrangedSubview:view];
    [view removeFromSuperview];
  }
  __weak XBMCController* weakSelf = self;
  if (m_foldSettingsPage == 1)
  {
    NSString* quality = playing ? @"Qualità originale" : @"Nessun video";
    if (playing && state->selected >= 0 && state->selected < state->streams.size())
      quality = [self foldQualityTitle:state->streams[state->selected] details:NO];
    UIButton* qualityButton = [self foldSettingRow:[@"Qualità · " stringByAppendingString:quality]
        symbol:@"tv" action:^{ [weakSelf setFoldSettingsPage:2]; }];
    qualityButton.enabled = playing && state->streams.size() > 1;
    qualityButton.accessibilityHint = qualityButton.enabled ? @"Scegli Auto o una risoluzione" : @"La sorgente espone una sola qualità";
    [m_foldSettingsPanel addArrangedSubview:qualityButton];

    UIStackView* hdrRow = [[UIStackView alloc] init];
    hdrRow.layoutMargins = UIEdgeInsetsMake(0, 16, 0, 16);
    hdrRow.layoutMarginsRelativeArrangement = YES;
    hdrRow.alignment = UIStackViewAlignmentCenter;
    hdrRow.spacing = 12;
    UILabel* label = [[UILabel alloc] init];
    label.text = hdr ? @"HDR" : @"HDR · non disponibile";
    label.textColor = hdr ? UIColor.whiteColor : UIColor.grayColor;
    UISwitch* toggle = [[UISwitch alloc] init];
    toggle.on = hdr && [self foldHDREnabled];
    toggle.enabled = hdr;
    toggle.accessibilityLabel = @"HDR";
    toggle.accessibilityHint = @"Disattiva per visualizzare il video in SDR";
    [toggle addTarget:self action:@selector(foldHDRChanged:) forControlEvents:UIControlEventValueChanged];
    [hdrRow addArrangedSubview:label];
    [hdrRow addArrangedSubview:toggle];
    [hdrRow.heightAnchor constraintEqualToConstant:53].active = YES;
    [m_foldSettingsPanel addArrangedSubview:hdrRow];

    NSString* speed = playing ? [NSString stringWithFormat:@"Velocità · %g×%@", state->tempo,
        state->canTempo ? @"" : @" · non disponibile"] : @"Velocità · nessun video";
    UIButton* speedButton = [self foldSettingRow:speed symbol:@"speedometer"
        action:^{ [weakSelf setFoldSettingsPage:3]; }];
    speedButton.enabled = playing && state->canTempo;
    [m_foldSettingsPanel addArrangedSubview:speedButton];
  }
  else
  {
    UIScrollView* scroll = [[UIScrollView alloc] init];
    UIStackView* options = [[UIStackView alloc] init];
    options.axis = UILayoutConstraintAxisVertical;
    options.spacing = 8;
    options.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:options];
    [NSLayoutConstraint activateConstraints:@[
      [options.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
      [options.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
      [options.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
      [options.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
      [options.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];
    if (playing && m_foldSettingsPage == 2)
    {
      for (int index = 0; index < state->streams.size(); ++index)
      {
        UIButton* option = [self foldSettingRow:[self foldQualityTitle:state->streams[index] details:YES]
            symbol:index == state->selected ? @"checkmark.circle.fill" : @"circle"
            action:^{
              PostFoldTask([state, index] {
                const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
                if (player && player->IsPlayingVideo() &&
                    g_application.CurrentFileItem().GetPath() == state->path &&
                    player->GetVideoStreamCount() == state->streams.size())
                {
                  VideoStreamInfo current;
                  player->GetVideoStreamInfo(index, current);
                  const auto& expected = state->streams[index];
                  if (current.name == expected.name && current.codecName == expected.codecName &&
                      (current.name == "Auto" || (current.width == expected.width && current.height == expected.height)))
                    player->SetVideoStream(index);
                }
              });
              [weakSelf setFoldSettingsPage:1];
            }];
        [options addArrangedSubview:option];
      }
    }
    else if (playing && m_foldSettingsPage == 3)
    {
      for (const float tempo : {0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f})
      {
        NSString* title = [NSString stringWithFormat:@"%g×%@", tempo, tempo == 1 ? @" · Normale" : @""];
        UIButton* option = [self foldSettingRow:title
            symbol:fabs(state->tempo - tempo) < 0.01 ? @"checkmark.circle.fill" : @"circle"
            action:^{
              PostFoldTask([state, tempo] {
                const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
                if (player && player->IsPlayingVideo() && player->SupportsTempo() &&
                    !player->IsPassthrough() && g_application.CurrentFileItem().GetPath() == state->path)
                  player->SetTempo(tempo);
              });
              [weakSelf setFoldSettingsPage:1];
            }];
        option.enabled = state->canTempo;
        [options addArrangedSubview:option];
      }
    }
    [m_foldSettingsPanel addArrangedSubview:scroll];
  }
  NSInteger destination = m_foldSettingsPage == 1 ? 0 : 1;
  [m_foldSettingsPanel addArrangedSubview:[self foldSettingRow:
      destination ? @"Impostazioni" : @"Torna ai controlli" symbol:@"chevron.backward"
      action:^{ [weakSelf setFoldSettingsPage:destination]; }]];
  [self.view setNeedsLayout];
}

- (void)openFoldWindow:(int)window
{
  if (m_glView.isXBMCAlive)
    ToggleFoldWindow(window);
}

- (void)updatePictureInPictureState
{
  if (!m_glView.isXBMCAlive) return;
  const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
  const BOOL playing = player && player->IsPlayingVideo();
  const BOOL paused = !playing || player->IsPausedPlayback() || player->IsCaching() || m_audioPolicy.IsInterrupted();
  time_t start;
  int64_t current, minimum, maximum;
  CServiceBroker::GetDataCacheCore().GetPlayTimes(start, current, minimum, maximum);
  if (m_pipTimebase)
  {
    const double rate = paused ? 0.0 : player->GetPlaySpeed() * player->GetPlayTempo();
    const CMTime time = CMTimeMake(current, 1000);
    if (fabs(CMTimeGetSeconds(CMTimeSubtract(CMTimebaseGetTime(m_pipTimebase), time))) > 0.25)
      CMTimebaseSetTime(m_pipTimebase, time);
    CMTimebaseSetRate(m_pipTimebase, rate);
  }
  if (m_pipStatePaused != paused || m_pipStateMaximum != maximum ||
      m_pipStateSession != m_hdrPresentedSession)
  {
    m_pipStatePaused = paused;
    m_pipStateMaximum = maximum;
    m_pipStateSession = m_hdrPresentedSession;
    [m_pipController invalidatePlaybackState];
  }
  m_pipController.requiresLinearPlayback = !playing || !player->CanSeek() || maximum <= minimum;
  m_foldPiP.enabled = playing && (m_pipController.pictureInPicturePossible || pipActive.load());
  if (m_foldSettingsPage)
    [self refreshFoldSettings];
}

- (void)togglePictureInPicture:(UIButton*)sender
{
  [self updatePictureInPictureState];
  if (m_pipController.pictureInPictureActive)
    [m_pipController stopPictureInPicture];
  else if (m_pipController.pictureInPicturePossible)
    [m_pipController startPictureInPicture];
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController*)controller
{
  pipActive = true;
  m_restoringPiP = NO;
  [self updatePictureInPictureState];
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController*)controller
{
  CLog::Log(LOGINFO, "iOS PiP: started native video presentation");
  [self updatePictureInPictureState];
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
    failedToStartPictureInPictureWithError:(NSError*)error
{
  pipActive = false;
  CLog::Log(LOGWARNING, "iOS PiP: start failed ({})", static_cast<long>(error.code));
  [self updatePictureInPictureState];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController*)controller
{
  pipActive = false;
  // Closing the floating player in another app is an explicit stop request.
  // Restoring its interface is a different transition and must keep playing.
  if (!m_restoringPiP && self.view.window.windowScene.activationState == UISceneActivationStateBackground &&
      IOSNativeVideoRenderingActive())
  {
    m_audioPolicy.UserCommand();
    CServiceBroker::GetAppMessenger()->PostMsg(TMSG_MEDIA_PAUSE_IF_PLAYING);
  }
  m_restoringPiP = NO;
  [self.view setNeedsLayout];
  [self updatePictureInPictureState];
  CLog::Log(LOGINFO, "iOS PiP: stopped native video presentation");
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler
{
  m_restoringPiP = YES;
  [self.view setNeedsLayout];
  [self.view layoutIfNeeded];
  CServiceBroker::GetAppMessenger()->PostMsg(TMSG_EXECUTE_BUILT_IN, -1, -1, nullptr,
      "ActivateWindow(fullscreenvideo)");
  completionHandler(YES);
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller setPlaying:(BOOL)playing
{
  m_audioPolicy.UserCommand();
  if (playing && m_audioPolicy.IsInterrupted()) return;
  NSError* error = nil;
  if (playing && ![[AVAudioSession sharedInstance] setActive:YES error:&error]) return;
  CServiceBroker::GetAppMessenger()->PostMsg(playing ? TMSG_MEDIA_UNPAUSE : TMSG_MEDIA_PAUSE_IF_PLAYING);
  if (m_pipTimebase) CMTimebaseSetRate(m_pipTimebase, playing ? 1 : 0);
  [controller invalidatePlaybackState];
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController*)controller
{
  if (!m_glView.isXBMCAlive) return YES;
  const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
  return !player || !player->IsPlayingVideo() || player->IsPausedPlayback() ||
         player->IsCaching() || m_audioPolicy.IsInterrupted();
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController*)controller
{
  if (!m_glView.isXBMCAlive) return kCMTimeRangeInvalid;
  const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
  if (!player || !player->IsPlayingVideo()) return kCMTimeRangeInvalid;
  time_t start;
  int64_t current, minimum, maximum;
  CServiceBroker::GetDataCacheCore().GetPlayTimes(start, current, minimum, maximum);
  if (!player->CanSeek() || maximum <= minimum)
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
  // The API requires the current timebase time to remain inside the range,
  // including the small interval between a DVR-window update and this query.
  const int64_t timebase = m_pipTimebase ? CMTimeConvertScale(CMTimebaseGetTime(m_pipTimebase), 1000,
      kCMTimeRoundingMethod_Default).value : current;
  minimum = std::min(minimum, timebase);
  maximum = std::max(maximum, timebase + 1);
  return CMTimeRangeFromTimeToTime(CMTimeMake(minimum, 1000), CMTimeMake(maximum, 1000));
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
    skipByInterval:(CMTime)interval completionHandler:(void (^)(void))completionHandler
{
  const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
  time_t start;
  int64_t current, minimum, maximum;
  CServiceBroker::GetDataCacheCore().GetPlayTimes(start, current, minimum, maximum);
  if (!player || !player->CanSeek() || maximum <= minimum)
  {
    completionHandler();
    return;
  }
  const int64_t target = std::clamp<int64_t>(current + llround(CMTimeGetSeconds(interval) * 1000), minimum, maximum);
  CServiceBroker::GetAppMessenger()->PostMsg(TMSG_MEDIA_SEEK_TIME, target);
  // The seek is asynchronous in Kodi. Wait for its clock to reach the target,
  // with a bounded failure path that always completes AVKit's request.
  __weak XBMCController* weakSelf = self;
  const CFTimeInterval deadline = CACurrentMediaTime() + 3;
  NSTimer* timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer* timer) {
    XBMCController* owner = weakSelf;
    time_t start;
    int64_t now, low, high;
    CServiceBroker::GetDataCacheCore().GetPlayTimes(start, now, low, high);
    if (!owner || llabs(now - target) < 1000 || CACurrentMediaTime() >= deadline)
    {
      [timer invalidate];
      if (owner && owner->m_pipTimebase) CMTimebaseSetTime(owner->m_pipTimebase, CMTimeMake(now, 1000));
      [owner updatePictureInPictureState];
      completionHandler();
    }
  }];
  [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
    didTransitionToRenderSize:(CMVideoDimensions)newRenderSize
{
  // Kodi keeps the selected source quality. Subtitle composition is bounded
  // to 960x540; no second decoder or full-screen GUI is kept alive for PiP.
}

- (BOOL)pictureInPictureControllerShouldProhibitBackgroundAudioPlayback:(AVPictureInPictureController*)controller
{
  return NO;
}

- (void)audioInterruptionBegan
{
  if (!m_glView.isXBMCAlive || m_audioPolicy.IsInterrupted()) return;
  const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
  uint64_t session;
  {
    std::lock_guard<std::mutex> lock(hdrMutex);
    session = hdrActiveSession;
  }
  m_audioPolicy.BeginInterruption(player && player->IsPlaying() && !player->IsPausedPlayback(), session);
  CServiceBroker::GetAppMessenger()->PostMsg(TMSG_MEDIA_PAUSE_IF_PLAYING);
  [self updatePictureInPictureState];
}

- (void)audioInterruptionEnded:(BOOL)shouldResume
{
  uint64_t session;
  {
    std::lock_guard<std::mutex> lock(hdrMutex);
    session = hdrActiveSession;
  }
  const BOOL resume = m_audioPolicy.EndInterruption(shouldResume, session);
  NSError* error = nil;
  if (resume && [[AVAudioSession sharedInstance] setActive:YES error:&error])
  {
    // RemoteIO may have been stopped by the OS while its cached running flag
    // remained true. Reopen the sink through AudioEngine before resuming.
    if (auto* audio = CServiceBroker::GetActiveAE()) audio->DeviceChange();
    CServiceBroker::GetAppMessenger()->PostMsg(TMSG_MEDIA_UNPAUSE);
  }
  [self updatePictureInPictureState];
}

- (void)audioSessionNotification:(NSNotification*)notification
{
  if (![NSThread isMainThread])
  {
    __weak XBMCController* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf audioSessionNotification:notification]; });
    return;
  }
  if (!m_glView.isXBMCAlive) return;
  if (@available(iOS 27.0, *))
  {
    if ([notification.name isEqualToString:AVAudioSessionDidBecomeInactiveNotification])
    {
      AVAudioSessionDeactivationContext* context = notification.userInfo[AVAudioSessionDeactivationContextKey];
      if (context.source == AVAudioSessionDeactivationSourceSystem) [self audioInterruptionBegan];
    }
    else if ([notification.name isEqualToString:AVAudioSessionResumptionRecommendationNotification])
    {
      AVAudioSessionResumptionContext* context = notification.userInfo[AVAudioSessionResumptionContextKey];
      [self audioInterruptionEnded:context.recommendation == AVAudioSessionResumptionRecommendationShouldResume];
    }
  }
  if ([notification.name isEqualToString:AVAudioSessionInterruptionNotification])
  {
    if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan)
      [self audioInterruptionBegan];
    else
      [self audioInterruptionEnded:([notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue] &
          AVAudioSessionInterruptionOptionShouldResume) != 0];
  }
  else if ([notification.name isEqualToString:AVAudioSessionRouteChangeNotification])
  {
    if ([notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue] == AVAudioSessionRouteChangeReasonOldDeviceUnavailable)
    {
      m_audioPolicy.UserCommand();
      CServiceBroker::GetAppMessenger()->PostMsg(TMSG_MEDIA_PAUSE_IF_PLAYING);
    }
  }
  else if ([notification.name isEqualToString:AVAudioSessionMediaServicesWereLostNotification])
    [self audioInterruptionBegan];
  else if ([notification.name isEqualToString:AVAudioSessionMediaServicesWereResetNotification])
  {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    if (auto* audio = CServiceBroker::GetActiveAE()) audio->DeviceChange();
    [self audioInterruptionEnded:YES];
  }
}

- (void)foldUtilityPressed:(UIButton*)sender
{
  if (!m_glView.isXBMCAlive)
    return;
  if (sender.tag)
    [self openFoldWindow:static_cast<int>(sender.tag)];
  else
    CServiceBroker::GetAppMessenger()->PostMsg(TMSG_GUI_ACTION, WINDOW_INVALID, -1,
        static_cast<void*>(new CAction(ACTION_SHOW_INFO)));
}

- (void)foldControlPressed:(UIButton*)sender
{
  if (!m_glView.isXBMCAlive)
    return;
  m_audioPolicy.UserCommand();
  if (sender == m_foldBackward || sender == m_foldForward)
  {
    CServiceBroker::GetAppMessenger()->PostMsg(TMSG_EXECUTE_BUILT_IN, -1, -1, nullptr,
        sender == m_foldBackward ? "Seek(-10)" : "Seek(10)");
    return;
  }
  CServiceBroker::GetAppMessenger()->PostMsg(TMSG_GUI_ACTION, WINDOW_INVALID, -1,
      static_cast<void*>(new CAction(static_cast<int>(sender.tag))));
}

- (NSString*)foldTimeText:(int64_t)milliseconds
{
  const int64_t seconds = std::max<int64_t>(0, milliseconds / 1000);
  if (seconds >= 3600)
    return [NSString stringWithFormat:@"%lld:%02lld:%02lld", seconds / 3600,
        (seconds / 60) % 60, seconds % 60];
  return [NSString stringWithFormat:@"%02lld:%02lld", seconds / 60, seconds % 60];
}

- (void)foldToggleDuration:(UIButton*)sender
{
  if (!sender.enabled)
    return;
  m_foldShowRemaining = !m_foldShowRemaining;
  [NSUserDefaults.standardUserDefaults setBool:m_foldShowRemaining forKey:@"DuoFoldShowRemainingTime"];
  [self updateFoldPlaybackState];
  if (m_foldScrubbing)
    [self foldScrubChanged:m_foldScrubber];
}

- (void)updateFoldDurationFrom:(int64_t)minimum to:(int64_t)maximum current:(int64_t)current
{
  NSString* title = m_foldShowRemaining
      ? [@"−" stringByAppendingString:[self foldTimeText:std::max<int64_t>(0, maximum - current)]]
      : [self foldTimeText:maximum - minimum];
  [m_foldDuration setTitle:title forState:UIControlStateNormal];
  m_foldDuration.accessibilityLabel = m_foldShowRemaining ? @"Tempo rimanente" : @"Durata totale";
  m_foldDuration.accessibilityValue = title;
  m_foldDuration.accessibilityHint = m_foldShowRemaining
      ? @"Tocca per mostrare la durata totale" : @"Tocca per mostrare il tempo rimanente";
}

- (void)updateFoldPlaybackState
{
  if (!m_glView.isXBMCAlive || m_foldControls.hidden || !m_foldSceneActive)
    return;
  const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
  const bool playing = player && player->IsPlaying();
  m_foldPiP.enabled = playing && (m_pipController.pictureInPicturePossible || pipActive.load());
  time_t start;
  int64_t current, minimum, maximum;
  CServiceBroker::GetDataCacheCore().GetPlayTimes(start, current, minimum, maximum);
  const bool canSeek = playing && player->CanSeek() && maximum > minimum;
  for (UIButton* button in m_foldPlaybackButtons)
    button.enabled = playing;
  m_foldBackward.enabled = canSeek;
  m_foldForward.enabled = canSeek;
  m_foldScrubber.enabled = canSeek;
  m_foldDuration.enabled = canSeek;
  if (!canSeek)
    m_foldScrubbing = NO;

  const BOOL paused = !playing || player->IsPausedPlayback();
  NSString* playLabel = paused ? @"Riproduci" : @"Pausa";
  if (![m_foldPlayPause.configuration.title isEqualToString:playLabel])
  {
    UIButtonConfiguration* configuration = m_foldPlayPause.configuration;
    configuration.image = [UIImage systemImageNamed:paused ? @"play.fill" : @"pause.fill"];
    configuration.title = playLabel;
    m_foldPlayPause.configuration = configuration;
    m_foldPlayPause.accessibilityLabel = playLabel;
  }
  // Do not move the thumb underneath the user's finger. Snapshot the DVR
  // bounds at drag start; clamp the resulting target to fresh bounds on release.
  if (!m_foldScrubbing)
  {
    m_foldSeekMinimum = minimum;
    m_foldSeekMaximum = maximum;
    m_foldScrubber.value = canSeek ? std::clamp<double>(
        double(current - minimum) / double(maximum - minimum), 0, 1) : 0;
    m_foldElapsed.text = playing ? [self foldTimeText:current - minimum] : @"--:--";
    if (canSeek)
      [self updateFoldDurationFrom:minimum to:maximum current:current];
    else
    {
      NSString* title = playing ? @"Diretta · non ricercabile" : @"Nessun video";
      [m_foldDuration setTitle:title forState:UIControlStateNormal];
      m_foldDuration.accessibilityLabel = title;
      m_foldDuration.accessibilityValue = nil;
      m_foldDuration.accessibilityHint = nil;
    }
    m_foldScrubber.accessibilityValue = m_foldElapsed.text;
  }
}

- (void)updateFoldTimer
{
  const BOOL shouldRun = m_foldSceneActive && !m_foldControls.hidden;
  if (!shouldRun)
  {
    [m_foldTimer invalidate];
    m_foldTimer = nil;
    m_foldScrubbing = NO;
  }
  else if (!m_foldTimer)
  {
    __weak XBMCController* weakSelf = self;
    m_foldTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* timer) {
      [weakSelf updateFoldPlaybackState];
    }];
    m_foldTimer.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:m_foldTimer forMode:NSRunLoopCommonModes];
    [self updateFoldPlaybackState];
  }
}

- (void)foldScrubBegan:(UISlider*)sender
{
  [self updateFoldPlaybackState];
  m_foldScrubbing = sender.enabled;
}

- (void)foldScrubChanged:(UISlider*)sender
{
  const int64_t target = m_foldSeekMinimum +
      std::llround(sender.value * double(m_foldSeekMaximum - m_foldSeekMinimum));
  m_foldElapsed.text = [self foldTimeText:target - m_foldSeekMinimum];
  [self updateFoldDurationFrom:m_foldSeekMinimum to:m_foldSeekMaximum current:target];
  sender.accessibilityValue = m_foldElapsed.text;
  // VoiceOver adjusts the slider without a touch-down/up sequence.
  if (!sender.tracking && !m_foldScrubbing)
    [self foldScrubEnded:sender];
}

- (void)foldScrubEnded:(UISlider*)sender
{
  if (m_glView.isXBMCAlive && sender.enabled)
  {
    const auto player = CServiceBroker::GetAppComponents().GetComponent<CApplicationPlayer>();
    time_t start;
    int64_t current, minimum, maximum;
    CServiceBroker::GetDataCacheCore().GetPlayTimes(start, current, minimum, maximum);
    if (player && player->IsPlaying() && player->CanSeek() && maximum > minimum)
    {
      const int64_t target = std::clamp<int64_t>(m_foldSeekMinimum +
          std::llround(sender.value * double(m_foldSeekMaximum - m_foldSeekMinimum)), minimum, maximum);
      CServiceBroker::GetAppMessenger()->PostMsg(TMSG_MEDIA_SEEK_TIME, target);
    }
  }
  m_foldScrubbing = NO;
}

- (void)foldScrubCancelled:(UISlider*)sender
{
  m_foldScrubbing = NO;
  [self updateFoldPlaybackState];
}

- (void)viewDidLayoutSubviews
{
  [super viewDidLayoutSubviews];
  if ([[IOSScreenManager sharedInstance] isExternalScreen])
    return;
  CGRect drawable = self.view.bounds;
  CGRect controls = CGRectZero;
  BOOL hasActiveFold = NO;
  if (@available(iOS 27.1, *))
  {
    // Query the actual fold geometry; no device model or hinge-angle guesses.
    for (UIViewReservedRegion* region in
         [self.view reservedRegionsOfKind:[UIViewReservedRegionKind divisionRegionKind]])
    {
      hasActiveFold |= m_foldPostureConfirmed && region.isActive;
      CGRect fold = CGRectIntersection(region.frame, self.view.bounds);
      if (m_foldPostureConfirmed && region.isActive && !CGRectIsNull(fold) &&
          fold.size.width > fold.size.height && CGRectGetMinY(fold) > 0 &&
          CGRectGetMaxY(fold) < CGRectGetHeight(self.view.bounds))
      {
        drawable.size.height = CGRectGetMinY(fold);
        controls = CGRectMake(0, CGRectGetMaxY(fold), CGRectGetWidth(self.view.bounds),
                              CGRectGetHeight(self.view.bounds) - CGRectGetMaxY(fold));
        break;
      }
    }
  }
  m_hasActiveFold = hasActiveFold;
  m_foldControls.hidden = CGRectIsEmpty(controls);
  if (!m_foldControls.hidden)
  {
    CGRect usable = CGRectIntersection(controls, self.view.safeAreaLayoutGuide.layoutFrame);
    if (CGRectIsNull(usable) || CGRectIsEmpty(usable))
      m_foldControls.hidden = YES;
    else
    {
      CGFloat width = MIN(MAX(CGRectGetWidth(usable) - 40, 0), 640);
      CGSize fitting = [m_foldControls systemLayoutSizeFittingSize:CGSizeMake(width, 0)
          withHorizontalFittingPriority:UILayoutPriorityRequired
          verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
      m_foldControls.frame = CGRectMake(CGRectGetMidX(usable) - width / 2,
          MAX(CGRectGetMinY(usable), CGRectGetMidY(usable) - fitting.height / 2),
          width, fitting.height);
    }
  }
  [self updateFoldTimer];
  screenScale = self.traitCollection.displayScale;
  CGSize canvasSize = drawable.size;
  CGAffineTransform canvasTransform = CGAffineTransformIdentity;
  if (canvasSize.height > canvasSize.width)
  {
    // A portrait scene must not stretch Estuary's landscape canvas. Transform
    // the view itself, so UIKit also converts touch coordinates correctly.
    canvasSize = CGSizeMake(drawable.size.height, drawable.size.width);
    CGFloat angle = m_lastLandscapeOrientation == UIInterfaceOrientationLandscapeLeft
        ? -M_PI_2 : M_PI_2;
    if (@available(iOS 26.0, *))
    {
      if (self.view.window.windowScene.effectiveGeometry.interfaceOrientation ==
          UIInterfaceOrientationPortraitUpsideDown)
        angle = -angle;
    }
    canvasTransform = CGAffineTransformMakeRotation(angle);
  }
  CGRect canvasBounds = CGRectMake(0, 0, canvasSize.width, canvasSize.height);
  if (!CGRectEqualToRect(m_glView.bounds, canvasBounds) ||
      !CGAffineTransformEqualToTransform(m_glView.transform, canvasTransform))
  {
    m_glView.transform = CGAffineTransformIdentity;
    m_glView.bounds = canvasBounds;
    m_glView.transform = canvasTransform;
    // UIKit can lay out the first scene before Kodi has initialized CLog.
    // Keep startup geometry diagnostics independent of the engine lifecycle.
    NSLog(@"Duo canvas %.1fx%.1f, scene %.1fx%.1f, tabletop=%d", canvasSize.width,
          canvasSize.height, self.view.bounds.size.width, self.view.bounds.size.height,
          !m_foldControls.hidden);
  }
  m_glView.center = CGPointMake(CGRectGetMidX(drawable), CGRectGetMidY(drawable));
  [self layoutHDRVideo];
  [m_glView resizeFrameBuffer];
}

- (void)viewSafeAreaInsetsDidChange
{
  [super viewSafeAreaInsetsDidChange];
  [m_glView invalidateGUIInsets];
  [self.view setNeedsLayout];
}

- (void)viewWillTransitionToSize:(CGSize)size
     withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
  } completion:nil];
}
//--------------------------------------------------------------
-(void)viewDidLoad
{
  [super viewDidLoad];
}
//--------------------------------------------------------------
- (void)dealloc
{
  [m_foldTimer invalidate];
  [m_pipTimer invalidate];
  m_pipController.delegate = nil;
  [m_pipController stopPictureInPicture];
  if (m_pipTimebase) CFRelease(m_pipTimebase);
  // stop background task
  [m_networkAutoSuspendTimer invalidate];
  [self enableNetworkAutoSuspend:nil];

  [m_glView stopAnimation];

  NSNotificationCenter *center;
  // take us off the default center for our app
  center = [NSNotificationCenter defaultCenter];
  [center removeObserver: self];
}
//--------------------------------------------------------------
- (void)viewWillAppear:(BOOL)animated
{
  PRINT_SIGNATURE();

  // move this later into CocoaPowerSyscall
  [[UIApplication sharedApplication] setIdleTimerDisabled:YES];

  [self resumeAnimation];

  [super viewWillAppear:animated];
}
//--------------------------------------------------------------
- (void)updateOrientationForSceneGeometry
{
  if (@available(iOS 26.0, *))
  {
    // Used only to preserve the last physical landscape direction during a
    // portrait scene transition; layout dimensions come from view bounds.
    UIInterfaceOrientation current = self.view.window.windowScene.effectiveGeometry.interfaceOrientation;
    if (UIInterfaceOrientationIsLandscape(current))
      m_lastLandscapeOrientation = current;
  }
  [self.view setNeedsLayout];
}

-(void) viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];

  [self updateOrientationForSceneGeometry];
  [self setNeedsStatusBarAppearanceUpdate];
  if (@available(iOS 26.0, *))
    [self setNeedsUpdateOfPrefersInterfaceOrientationLocked];


  [self becomeFirstResponder];
  [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
  // Notifies UIKit that our view controller updated its preference
  // regarding the visual indicator
  // this should make ios call prefersHomeIndicatorAutoHidden and
  // hide the home indicator on iPhoneX and other devices without
  // home button
  if ([self respondsToSelector:@selector(setNeedsUpdateOfHomeIndicatorAutoHidden)]) {
    [self performSelector:@selector(setNeedsUpdateOfHomeIndicatorAutoHidden)];
  }
}
//--------------------------------------------------------------
- (BOOL)prefersHomeIndicatorAutoHidden
{
  return YES;
}
//--------------------------------------------------------------
- (void)viewWillDisappear:(BOOL)animated
{
  PRINT_SIGNATURE();

  [self pauseAnimation];

  // move this later into CocoaPowerSyscall
  [[UIApplication sharedApplication] setIdleTimerDisabled:NO];

  [super viewWillDisappear:animated];
}
//--------------------------------------------------------------
-(UIView *)inputView
{
  // override our input view to an empty view
  // this prevents the on screen keyboard
  // which would be shown whenever this UIResponder
  // becomes the first responder (which is always the case!)
  // caused by implementing the UIKeyInput protocol
  return [[UIView alloc] initWithFrame:CGRectZero];
}
//--------------------------------------------------------------
- (BOOL) canBecomeFirstResponder
{
  return YES;
}
//--------------------------------------------------------------
- (void)viewDidUnload
{
  [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
  [self resignFirstResponder];

	[super viewDidUnload];
}
//--------------------------------------------------------------
- (CGRect)fullscreenSubviewFrame
{
  return UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
}
//--------------------------------------------------------------
- (void)onXbmcAlive
{
  m_debugLogSharingPresenter = std::make_unique<DebugLogSharingPresenter>();
  [self setGUIInsetsFromMainThread:NO];
}
//--------------------------------------------------------------
- (void)setGUIInsetsFromMainThread:(BOOL)isMainThread
{
  auto& guiInsets = CDisplaySettings::GetInstance().GetCurrentResolutionInfo().guiInsets;

  // disable insets for external screen
  if ([[IOSScreenManager sharedInstance] isExternalScreen])
  {
    guiInsets = EdgeInsets{};
    return;
  }

  // Kodi renders an immersive canvas, including its background. Applying scene
  // safe-area insets here shrinks that entire canvas and leaves a black strip
  // on the Duo outer display. UIKit fold controls retain their own safe area.
  if (@available(iOS 27.1, *))
  {
    guiInsets = EdgeInsets{};
    return;
  }

  // apply safe area to Kodi GUI on older systems
  UIEdgeInsets __block insets;
  CGFloat __block scale;
  auto getInsets = ^{
    insets = m_glView.safeAreaInsets;
    scale = m_glView.traitCollection.displayScale;
  };
  if (isMainThread)
    getInsets();
  else
    dispatch_sync(dispatch_get_main_queue(), getInsets);

  CLog::Log(LOGINFO, "Duo GUI insets left={} top={} right={} bottom={} scale={}", insets.left, insets.top, insets.right, insets.bottom, scale);
  guiInsets = EdgeInsets(insets.left * scale, insets.top * scale, insets.right * scale,
                         insets.bottom * scale);
}
//--------------------------------------------------------------
- (BOOL) setFramebuffer
{
  return [m_glView setFramebuffer];
}
//--------------------------------------------------------------
- (bool) presentFramebuffer
{
  return [m_glView presentFramebuffer];
}
//--------------------------------------------------------------
- (CGSize) getScreenSize
{
  __block CGSize tmp;
  if ([NSThread isMainThread])
  {
    tmp.width  = m_glView.bounds.size.width * m_glView.traitCollection.displayScale;
    tmp.height = m_glView.bounds.size.height * m_glView.traitCollection.displayScale;
  }
  else
  {
    dispatch_sync(dispatch_get_main_queue(), ^{
      tmp.width  = m_glView.bounds.size.width * m_glView.traitCollection.displayScale;
      tmp.height = m_glView.bounds.size.height * m_glView.traitCollection.displayScale;
    });
  }
  screensize = tmp;
  return screensize;
}
//--------------------------------------------------------------
- (BOOL) recreateOnReselect
{
  PRINT_SIGNATURE();
  return YES;
}
//--------------------------------------------------------------
- (void)didReceiveMemoryWarning
{
  // Releases the view if it doesn't have a superview.
  [super didReceiveMemoryWarning];

  // Release any cached data, images, etc. that aren't in use.
}
//--------------------------------------------------------------
- (void)disableNetworkAutoSuspend
{
  PRINT_SIGNATURE();
  if (m_bgTask != UIBackgroundTaskInvalid)
  {
    [[UIApplication sharedApplication] endBackgroundTask: m_bgTask];
    m_bgTask = UIBackgroundTaskInvalid;
  }
  // we have to alloc the background task for keep network working after screen lock and dark.
  UIBackgroundTaskIdentifier newTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
  m_bgTask = newTask;

  if (m_networkAutoSuspendTimer)
  {
    [m_networkAutoSuspendTimer invalidate];
    self.m_networkAutoSuspendTimer = nil;
  }
}
//--------------------------------------------------------------
- (void)enableNetworkAutoSuspend:(id)obj
{
  PRINT_SIGNATURE();
  if (m_bgTask != UIBackgroundTaskInvalid)
  {
    [[UIApplication sharedApplication] endBackgroundTask: m_bgTask];
    m_bgTask = UIBackgroundTaskInvalid;
  }
}
//--------------------------------------------------------------
- (void) disableSystemSleep
{
}
//--------------------------------------------------------------
- (void) enableSystemSleep
{
}
//--------------------------------------------------------------
- (void) disableScreenSaver
{
}
//--------------------------------------------------------------
- (void) enableScreenSaver
{
}
//--------------------------------------------------------------
- (bool) changeScreen: (unsigned int)screenIdx withMode:(UIScreenMode *)mode
{
  bool ret = false;

  ret = [[IOSScreenManager sharedInstance] changeScreen:screenIdx withMode:mode];

  return ret;
}
//--------------------------------------------------------------
- (void) activateScreen: (UIScreen *)screen  withOrientation:(UIInterfaceOrientation)newOrientation
{
  // Since ios7 we have to handle the orientation manually
  // it differs by 90 degree between internal and external screen
  float   angle = 0;
  UIView *view = [m_window.subviews objectAtIndex:0];
  switch(newOrientation)
  {
    case UIInterfaceOrientationUnknown:
    case UIInterfaceOrientationPortrait:
      angle = 0;
      break;
    case UIInterfaceOrientationPortraitUpsideDown:
      angle = M_PI;
      break;
    case UIInterfaceOrientationLandscapeLeft:
      angle = -M_PI_2;
      break;
    case UIInterfaceOrientationLandscapeRight:
      angle = M_PI_2;
      break;
  }
  // reset the rotation of the view
  view.layer.transform = CATransform3DMakeRotation(static_cast<double>(angle), 0, 0.0, 1.0);
  view.layer.bounds = view.bounds;
  m_window.screen = screen;
  [view setFrame:m_window.frame];
}
//--------------------------------------------------------------
- (void) remoteControlReceivedWithEvent: (UIEvent *) receivedEvent {
  LOG(@"%s: type %zd, subtype: %zd", __PRETTY_FUNCTION__, receivedEvent.type, receivedEvent.subtype);
  if (receivedEvent.type == UIEventTypeRemoteControl)
  {
    [self disableNetworkAutoSuspend];
    switch (receivedEvent.subtype)
    {
      case UIEventSubtypeRemoteControlTogglePlayPause:
        m_audioPolicy.UserCommand();
        CServiceBroker::GetAppMessenger()->SendMsg(
            TMSG_GUI_ACTION, WINDOW_INVALID, -1,
            static_cast<void*>(new CAction(ACTION_PLAYER_PLAYPAUSE)));
        break;
      case UIEventSubtypeRemoteControlPlay:
        CServiceBroker::GetAppMessenger()->SendMsg(
            TMSG_GUI_ACTION, WINDOW_INVALID, -1,
            static_cast<void*>(new CAction(ACTION_PLAYER_PLAY)));
        break;
      case UIEventSubtypeRemoteControlPause:
        m_audioPolicy.UserCommand();
        // ACTION_PAUSE sometimes cause unpause, use MediaPauseIfPlaying to make sure pause only
        CServiceBroker::GetAppMessenger()->SendMsg(TMSG_MEDIA_PAUSE_IF_PLAYING);
        break;
      case UIEventSubtypeRemoteControlNextTrack:
        CServiceBroker::GetAppMessenger()->SendMsg(
            TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_NEXT_ITEM)));
        break;
      case UIEventSubtypeRemoteControlPreviousTrack:
        CServiceBroker::GetAppMessenger()->SendMsg(
            TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_PREV_ITEM)));
        break;
      case UIEventSubtypeRemoteControlBeginSeekingForward:
        // use 4X speed forward.
        CServiceBroker::GetAppMessenger()->SendMsg(
            TMSG_GUI_ACTION, WINDOW_INVALID, -1,
            static_cast<void*>(new CAction(ACTION_PLAYER_FORWARD)));
        CServiceBroker::GetAppMessenger()->SendMsg(
            TMSG_GUI_ACTION, WINDOW_INVALID, -1,
            static_cast<void*>(new CAction(ACTION_PLAYER_FORWARD)));
        break;
      case UIEventSubtypeRemoteControlBeginSeekingBackward:
        // use 4X speed rewind.
        CServiceBroker::GetAppMessenger()->SendMsg(
            TMSG_GUI_ACTION, WINDOW_INVALID, -1,
            static_cast<void*>(new CAction(ACTION_PLAYER_REWIND)));
        CServiceBroker::GetAppMessenger()->SendMsg(
            TMSG_GUI_ACTION, WINDOW_INVALID, -1,
            static_cast<void*>(new CAction(ACTION_PLAYER_REWIND)));
        break;
      case UIEventSubtypeRemoteControlEndSeekingForward:
      case UIEventSubtypeRemoteControlEndSeekingBackward:
      {
        // restore to normal playback speed.
        const auto& components = CServiceBroker::GetAppComponents();
        const auto appPlayer = components.GetComponent<CApplicationPlayer>();
        if (appPlayer->IsPlaying() && !appPlayer->IsPaused())
          CServiceBroker::GetAppMessenger()->SendMsg(
              TMSG_GUI_ACTION, WINDOW_INVALID, -1,
              static_cast<void*>(new CAction(ACTION_PLAYER_PLAY)));
        break;
      }
      default:
        LOG(@"unhandled subtype: %zd", receivedEvent.subtype);
        break;
    }
    [self rescheduleNetworkAutoSuspend];
  }
}
//--------------------------------------------------------------
- (void)enterBackground
{
  // Audio/PiP keep their existing player and network session. Losing the
  // interactive scene is not an audio interruption.
  [self pauseAnimation];
  auto* winSystem = dynamic_cast<CWinSystemIOS*>(CServiceBroker::GetWinSystem());
  if (winSystem) winSystem->OnAppFocusChange(false);
  [self updatePictureInPictureState];
  [self rescheduleNetworkAutoSuspend];
}

- (void)enterForeground
{
  auto* winSystem = dynamic_cast<CWinSystemIOS*>(CServiceBroker::GetWinSystem());
  if (winSystem) winSystem->OnAppFocusChange(true);
  [self updatePictureInPictureState];
  // Never undo a pause made by the user merely because the scene is active.
}

- (void)becomeInactive
{
  m_foldSceneActive = NO;
  [self updateFoldTimer];
  [self updatePictureInPictureState];
  [self rescheduleNetworkAutoSuspend];
}
//--------------------------------------------------------------
- (void)pauseAnimation
{
  PRINT_SIGNATURE();

  m_foldSceneActive = NO;
  [self updateFoldTimer];
  [m_glView pauseAnimation];
}
//--------------------------------------------------------------
- (void)resumeAnimation
{
  PRINT_SIGNATURE();

  m_foldSceneActive = YES;
  [self updateFoldTimer];
  [m_glView resumeAnimation];
}
//--------------------------------------------------------------
- (void)startAnimation
{
  PRINT_SIGNATURE();

  [m_glView startAnimation];
}
//--------------------------------------------------------------
- (void)stopAnimation
{
  PRINT_SIGNATURE();

  m_foldSceneActive = NO;
  [self resetHDRVideo];
  [self updateFoldTimer];
  [m_glView stopAnimation];
}

- (void)rescheduleNetworkAutoSuspend
{
  LOG(@"%s: playback state: %d", __PRETTY_FUNCTION__, MPNPInfoManager.playbackState);
  if (MPNPInfoManager.playbackState == DARWINEMBED_PLAYBACK_PLAYING)
  {
    [self disableNetworkAutoSuspend];
    return;
  }
  if (m_networkAutoSuspendTimer)
    [m_networkAutoSuspendTimer invalidate];

  // wait longer if paused than stopped
  int delay = MPNPInfoManager.playbackState == DARWINEMBED_PLAYBACK_PAUSED ? 60 : 30;
  self.m_networkAutoSuspendTimer =
      [NSTimer scheduledTimerWithTimeInterval:delay
                                       target:self
                                     selector:@selector(enableNetworkAutoSuspend:)
                                     userInfo:nil
                                      repeats:NO];
}

#pragma mark -
#pragma mark private helper methods
//
- (void)observeDefaultCenterStuff: (NSNotification *) notification
{
//  LOG(@"default: %@", [notification name]);
//  LOG(@"userInfo: %@", [notification userInfo]);
}

- (CVEAGLContext)getEAGLContextObj
{
  return [m_glView getCurrentEAGLContext];
}

@end
