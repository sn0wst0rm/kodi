/*
 *  Copyright (C) 2010-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "IOSEAGLView.h"

#include "FileItem.h"
#import "IOSScreenManager.h"
#include "ServiceBroker.h"
#include "Util.h"
#import "XBMCController.h"
#include "application/AppEnvironment.h"
#include "application/AppInboundProtocol.h"
#include "application/AppParams.h"
#include "application/Application.h"
#include "messaging/ApplicationMessenger.h"
#include "settings/AdvancedSettings.h"
#include "settings/SettingsComponent.h"
#include "utils/TimeUtils.h"
#include "utils/log.h"
#include "windowing/ios/WinSystemIOS.h"

#include <cmath>
#include <mutex>
#include <vector>
#include "platform/darwin/ios/IOSHDRVideo.h"

#import "platform/darwin/DarwinUtils.h"
#import "platform/darwin/NSLogDebugHelpers.h"
#import "platform/darwin/ios-common/AnnounceReceiver.h"

#include <signal.h>
#include <stdio.h>

#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/resource.h>

namespace
{
std::mutex deferredTextureMutex;
std::vector<GLuint> deferredVideoTextures;
}
void IOSDeleteVideoTexture(unsigned int texture)
{
  if (!texture) return;
  if (g_application.GetRenderGUI())
    glDeleteTextures(1, &texture);
  else
  {
    std::lock_guard<std::mutex> lock(deferredTextureMutex);
    deferredVideoTextures.push_back(texture);
  }
}
void IOSDrainVideoTextures()
{
  std::lock_guard<std::mutex> lock(deferredTextureMutex);
  if (!deferredVideoTextures.empty())
  {
    glDeleteTextures(deferredVideoTextures.size(), deferredVideoTextures.data());
    deferredVideoTextures.clear();
  }
}

//--------------------------------------------------------------
@interface IOSEAGLView (PrivateMethods)
- (void) setContext:(EAGLContext *)newContext;
- (BOOL) createFramebuffer;
- (void) deleteFramebuffer;
- (void) runDisplayLink;
@end

@implementation IOSEAGLView
@synthesize animating;
@synthesize xbmcAlive;
@synthesize readyToRun;
@synthesize pause;
@synthesize currentScreen;
@synthesize framebufferResizeRequested;
@synthesize context;

// You must implement this method
+ (Class) layerClass
{
  return [CAEAGLLayer class];
}
//--------------------------------------------------------------
- (void) resizeFrameBuffer
{
  // UIKit owns geometry. Only publish the new drawable size here: the EAGL
  // context belongs to Kodi's render thread once animation has started.
  CGFloat scale = self.traitCollection.displayScale;
  if (scale <= 0)
    return;
  self.contentScaleFactor = scale;
  self.layer.contentsScale = scale;
  const CGSize size = CGSizeMake(std::round(self.bounds.size.width * scale),
                                 std::round(self.bounds.size.height * scale));
  if (size.width <= 0 || size.height <= 0)
    return;
  @synchronized(self)
  {
    if (!CGSizeEqualToSize(size, requestedDrawableSize))
    {
      requestedDrawableSize = size;
      framebufferResizeRequested = YES;
    }
  }
}

- (void)invalidateGUIInsets
{
  @synchronized(self)
  {
    geometryInsetsDirty = YES;
  }
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  [self resizeFrameBuffer];
}

- (CGFloat)getScreenScale:(UIScreen *)screen
{
  return self.traitCollection.displayScale;
}

- (void) setScreen:(UIScreen *)screen withFrameBufferResize:(BOOL)resize
{
  CGFloat scaleFactor = 1.0;
  CAEAGLLayer *eaglLayer = (CAEAGLLayer *)[self layer];

  currentScreen = screen;
  scaleFactor = [self getScreenScale: currentScreen];

  //this will activate retina on supported devices
  [eaglLayer setContentsScale:scaleFactor];
  [self setContentScaleFactor:scaleFactor];
  if(resize)
  {
    [self resizeFrameBuffer];
  }
}

//--------------------------------------------------------------
- (id)initWithFrame:(CGRect)frame withScreen:(UIScreen *)screen
{
  //PRINT_SIGNATURE();
  framebufferResizeRequested = FALSE;
  geometryInsetsDirty = YES;
  if ((self = [super initWithFrame:frame]))
  {
    if (@available(iOS 17.0, *))
    {
      [self registerForTraitChanges:@[[UITraitDisplayScale class]]
                         withAction:@selector(resizeFrameBuffer)];
    }
    // Get the layer
    CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
    //set screen, handlescreenscale
    //and set frame size
    [self setScreen:screen withFrameBufferResize:FALSE];

    eaglLayer.opaque = TRUE;
    eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking,
      kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat,
      nil];

    EAGLContext *aContext = [[EAGLContext alloc]
      initWithAPI:kEAGLRenderingAPIOpenGLES2];

    if (!aContext)
      ELOG(@"Failed to create ES context");
    else if (![EAGLContext setCurrentContext:aContext])
      ELOG(@"Failed to set ES context current");

    self.context = aContext;

    animating = FALSE;
    xbmcAlive = FALSE;
    pause = FALSE;
    [self setContext:context];
    [self createFramebuffer];
    [self setFramebuffer];
  }

  return self;
}

//--------------------------------------------------------------
- (void) dealloc
{
  //PRINT_SIGNATURE();
  [self deleteFramebuffer];
}

//--------------------------------------------------------------
- (EAGLContext *)context
{
  return context;
}
//--------------------------------------------------------------
- (void)setContext:(EAGLContext *)newContext
{
  PRINT_SIGNATURE();
  if (context != newContext)
  {
    [self deleteFramebuffer];

    context = newContext;

    [EAGLContext setCurrentContext:nil];
  }
}

//--------------------------------------------------------------
- (BOOL)createFramebuffer
{
  if (context && !defaultFramebuffer)
  {
    //PRINT_SIGNATURE();
    [EAGLContext setCurrentContext:context];

    // Create default framebuffer object.
    glGenFramebuffers(1, &defaultFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);

    // Create color render buffer and allocate backing store.
    glGenRenderbuffers(1, &colorRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    const BOOL storageAllocated =
        [context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &framebufferWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &framebufferHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorRenderbuffer);

    glGenRenderbuffers(1, &depthRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, depthRenderbuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, framebufferWidth, framebufferHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRenderbuffer);

    const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (!storageAllocated || framebufferWidth <= 0 || framebufferHeight <= 0 ||
        status != GL_FRAMEBUFFER_COMPLETE)
    {
      if (!framebufferFailureLogged)
        ELOG(@"Drawable unavailable; retrying framebuffer allocation (%x)", status);
      framebufferFailureLogged = YES;
      [self deleteFramebuffer];
      framebufferRetryTime = CACurrentMediaTime() + 0.1;
      return NO;
    }
    framebufferFailureLogged = NO;
    framebufferRetryTime = 0;
  }
  return defaultFramebuffer != 0;
}
//--------------------------------------------------------------
- (void) deleteFramebuffer
{
  if (context && !pause)
  {
    [EAGLContext setCurrentContext:context];

    if (defaultFramebuffer)
    {
      glDeleteFramebuffers(1, &defaultFramebuffer);
      defaultFramebuffer = 0;
    }

    if (colorRenderbuffer)
    {
      glDeleteRenderbuffers(1, &colorRenderbuffer);
      colorRenderbuffer = 0;
    }

    if (depthRenderbuffer)
    {
      glDeleteRenderbuffers(1, &depthRenderbuffer);
      depthRenderbuffer = 0;
    }
    framebufferWidth = 0;
    framebufferHeight = 0;
  }
}
//--------------------------------------------------------------
- (BOOL) setFramebuffer
{
  if (context && !pause)
  {
    if ([EAGLContext currentContext] != context)
      [EAGLContext setCurrentContext:context];

    IOSDrainVideoTextures();
    if (CACurrentMediaTime() < framebufferRetryTime)
      return NO;

    BOOL resize = NO;
    BOOL updateInsets = NO;
    @synchronized(self)
    {
      resize = framebufferResizeRequested || !defaultFramebuffer;
      framebufferResizeRequested = NO;
      // Keep the first update queued until Kodi's display settings exist.
      if (xbmcAlive)
      {
        updateInsets = geometryInsetsDirty;
        geometryInsetsDirty = NO;
      }
    }
    if (resize)
    {
      [self deleteFramebuffer];
      if (![self createFramebuffer])
      {
        @synchronized(self)
        {
          framebufferResizeRequested = YES;
          geometryInsetsDirty = YES;
        }
        return NO;
      }
      if (framebufferWidth > 0 && framebufferHeight > 0 && xbmcAlive)
      {
        static_cast<CWinSystemIOS*>(CServiceBroker::GetWinSystem())
            ->OnDrawableResized(framebufferWidth, framebufferHeight);
      }
    }
    // Insets can change without drawable dimensions changing (for example,
    // system UI or a scene safe-area update). Never tie this to the resize guard.
    if (updateInsets)
      [g_xbmcController setGUIInsetsFromMainThread:NO];
    glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
    glViewport(0, 0, framebufferWidth, framebufferHeight);
    glScissor(0, 0, framebufferWidth, framebufferHeight);
    return YES;
  }
  return NO;
}
//--------------------------------------------------------------
- (bool) presentFramebuffer
{
  bool success = FALSE;

  if (context && !pause && defaultFramebuffer && colorRenderbuffer)
  {
    if ([EAGLContext currentContext] != context)
      [EAGLContext setCurrentContext:context];

    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    success = [context presentRenderbuffer:GL_RENDERBUFFER];
  }

  return success;
}
//--------------------------------------------------------------
- (void) pauseAnimation
{
  if (pause) return;
  if (xbmcAlive)
  {
    // Finish outstanding GL work on its owning thread before returning to
    // UIKit's background transition. Do not transfer EAGLContext to UIKit.
    KODI::MESSAGING::ThreadMessageCallback callback;
    callback.userptr = nullptr;
    callback.callback = [](void*) {
      if (auto port = CServiceBroker::GetAppPort()) port->SetRenderGUI(false);
      glFinish();
    };
    CServiceBroker::GetAppMessenger()->SendMsg(TMSG_CALLBACK, -1, -1, &callback);
  }
  pause = TRUE;
}
//--------------------------------------------------------------
- (void) resumeAnimation
{
  PRINT_SIGNATURE();
  pause = FALSE;
  std::shared_ptr<CAppInboundProtocol> appPort = CServiceBroker::GetAppPort();
  if (appPort)
    appPort->SetRenderGUI(true);
}
//--------------------------------------------------------------
- (void) startAnimation
{
  PRINT_SIGNATURE();
	if (!animating && context)
	{
		animating = TRUE;

    // kick off an animation thread
    animationThreadLock = [[NSConditionLock alloc] initWithCondition: FALSE];
    animationThread = [[NSThread alloc] initWithTarget:self
      selector:@selector(runAnimation:)
      object:animationThreadLock];
    [EAGLContext setCurrentContext:nil];
    [animationThread start];
	}
}
//--------------------------------------------------------------
- (void) stopAnimation
{
  PRINT_SIGNATURE();
	if (animating && context)
	{
		animating = FALSE;
    xbmcAlive = FALSE;
    if (!g_application.m_bStop)
    {
      CServiceBroker::GetAppMessenger()->PostMsg(TMSG_QUIT);
    }

    CAnnounceReceiver::GetInstance()->DeInitialize();

    // wait for animation thread to die
    if ([animationThread isFinished] == NO)
      [animationThreadLock lockWhenCondition:TRUE];
	}
}
//--------------------------------------------------------------
- (void) runAnimation:(id) arg
{
  @autoreleasepool
  {
    [[NSThread currentThread] setName:@"XBMC_Run"];

    // set up some xbmc specific relationships
    readyToRun = true;

    // signal we are alive
    NSConditionLock* myLock = arg;
    [myLock lock];

    // Prevent child processes from becoming zombies on exit if not waited upon. See also Util::Command
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_NOCLDWAIT;
    sa.sa_handler = SIG_IGN;
    sigaction(SIGCHLD, &sa, NULL);

    setlocale(LC_NUMERIC, "C");

    const auto params = std::make_shared<CAppParams>();
#ifdef _DEBUG
    params->SetLogLevel(LOG_LEVEL_DEBUG);
#else
    params->SetLogLevel(LOG_LEVEL_NORMAL);
#endif
    CAppEnvironment::SetUp(params);

    if (!g_application.Create())
    {
      readyToRun = false;
      ELOG(@"%sUnable to create application", __PRETTY_FUNCTION__);
    }

    CAnnounceReceiver::GetInstance()->Initialize();

    if (!g_application.CreateGUI())
    {
      readyToRun = false;
      ELOG(@"%sUnable to create GUI", __PRETTY_FUNCTION__);
      if (g_application.Stop(EXITCODE_QUIT))
        g_application.Cleanup();
    }

    if (!g_application.Initialize())
    {
      readyToRun = false;
      ELOG(@"%sUnable to initialize application", __PRETTY_FUNCTION__);
      if (g_application.Stop(EXITCODE_QUIT))
        g_application.Cleanup();
    }

    if (readyToRun)
    {
      CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_startFullScreen = true;
      CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_canWindowed = false;
      xbmcAlive = TRUE;
      [g_xbmcController onXbmcAlive];
      try
      {
        @autoreleasepool
        {
          g_application.Run();
        }
      }
      catch (...)
      {
        ELOG(@"%sException caught on main loop. Exiting", __PRETTY_FUNCTION__);
      }
    }

    CAppEnvironment::TearDown();

    // signal we are dead
    [myLock unlockWithCondition:TRUE];

    // grrr, xbmc does not shutdown properly and leaves
    // several classes in an indeterminate state, we must exit and
    // reload Lowtide/AppleTV, boo.
    [g_xbmcController enableScreenSaver];
    [g_xbmcController enableSystemSleep];
    exit(0);
  }
}
//--------------------------------------------------------------
@end
