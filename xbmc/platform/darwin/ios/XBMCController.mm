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
#include "application/ApplicationPlayer.h"
#include "filesystem/SpecialProtocol.h"
#include "guilib/GUIControl.h"
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
#import "platform/darwin/ios/IOSScreenManager.h"
#import "platform/darwin/ios/XBMCApplication.h"

#define id _id
#include "TextureCache.h"
#undef id

#include <math.h>
#include <signal.h>

#import <AVFoundation/AVAudioSession.h>
#include <sys/resource.h>

#ifndef M_PI
#define M_PI 3.1415926535897932384626433832795028842
#endif
#define RADIANS_TO_DEGREES(radians) ((radians) * (180.0 / M_PI))

XBMCController *g_xbmcController;

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

@interface XBMCController ()
{
  std::unique_ptr<DebugLogSharingPresenter> m_debugLogSharingPresenter;
  UIStackView* m_foldControls;
  BOOL m_hasActiveFold;
  UIInterfaceOrientation m_lastLandscapeOrientation;
  BOOL m_landscapeRequestPending;
}
- (void)rescheduleNetworkAutoSuspend;
@end

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
  // Keep system chrome landscape when held vertically, but allow UIKit to
  // choose either landscape direction and to manage its own rotation lock.
  return !m_hasActiveFold &&
         !UIDeviceOrientationIsLandscape(UIDevice.currentDevice.orientation);
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

  m_isPlayingBeforeInactive = NO;
  m_bgTask = UIBackgroundTaskInvalid;


  NSNotificationCenter *center;
  center = [NSNotificationCenter defaultCenter];
  [center addObserver: self
             selector: @selector(observeDefaultCenterStuff:)
                 name: nil
               object: nil];

  [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
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
  m_foldControls = [[UIStackView alloc] init];
  m_foldControls.axis = UILayoutConstraintAxisHorizontal;
  m_foldControls.alignment = UIStackViewAlignmentCenter;
  m_foldControls.distribution = UIStackViewDistributionFillEqually;
  m_foldControls.spacing = 20;
  NSArray<NSString*>* symbols = @[@"gobackward", @"playpause.fill", @"goforward", @"stop.fill"];
  NSArray<NSString*>* labels = @[@"Indietro", @"Riproduci o pausa", @"Avanti", @"Interrompi"];
  const int actions[] = {ACTION_STEP_BACK, ACTION_PLAYER_PLAYPAUSE, ACTION_STEP_FORWARD, ACTION_STOP};
  for (NSUInteger i = 0; i < symbols.count; ++i)
  {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration* configuration = [UIButtonConfiguration tintedButtonConfiguration];
    configuration.image = [UIImage systemImageNamed:symbols[i]];
    configuration.baseForegroundColor = UIColor.whiteColor;
    button.configuration = configuration;
    button.accessibilityLabel = labels[i];
    button.tag = actions[i];
    [button addTarget:self action:@selector(foldControlPressed:) forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
    [m_foldControls addArrangedSubview:button];
  }
  m_foldControls.hidden = YES;
  [self.view addSubview:m_foldControls];
}
//--------------------------------------------------------------
- (void)foldControlPressed:(UIButton*)sender
{
  if (m_glView.isXBMCAlive)
    CServiceBroker::GetAppMessenger()->PostMsg(TMSG_GUI_ACTION, WINDOW_INVALID, -1,
        static_cast<void*>(new CAction(static_cast<int>(sender.tag))));
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
      hasActiveFold |= region.isActive;
      CGRect fold = CGRectIntersection(region.frame, self.view.bounds);
      if (region.isActive && !CGRectIsNull(fold) &&
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
  if (m_hasActiveFold != hasActiveFold)
  {
    m_hasActiveFold = hasActiveFold;
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateOrientationForSceneGeometry]; });
  }
  m_foldControls.hidden = CGRectIsEmpty(controls);
  if (!m_foldControls.hidden)
  {
    CGRect usable = CGRectIntersection(controls, self.view.safeAreaLayoutGuide.layoutFrame);
    CGFloat width = MIN(CGRectGetWidth(usable) - 32, 440);
    m_foldControls.frame = CGRectMake(CGRectGetMidX(usable) - width / 2,
                                     CGRectGetMidY(usable) - 36, MAX(width, 0), 72);
  }
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
    CLog::Log(LOGINFO, "Duo canvas {}x{}, scene {}x{}, tabletop={}",
              canvasSize.width, canvasSize.height, self.view.bounds.size.width,
              self.view.bounds.size.height, !m_foldControls.hidden);
  }
  m_glView.center = CGPointMake(CGRectGetMidX(drawable), CGRectGetMidY(drawable));
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
  [UIDevice.currentDevice endGeneratingDeviceOrientationNotifications];
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
    [self setNeedsUpdateOfPrefersInterfaceOrientationLocked];
    UIWindowScene* scene = self.view.window.windowScene;
    UIInterfaceOrientation current = scene.effectiveGeometry.interfaceOrientation;
    if (UIInterfaceOrientationIsLandscape(current))
    {
      m_lastLandscapeOrientation = current;
      m_landscapeRequestPending = NO;
    }
    else if (!m_hasActiveFold && scene && !m_landscapeRequestPending)
    {
      m_landscapeRequestPending = YES;
      UIInterfaceOrientationMask mask = m_lastLandscapeOrientation
          ? (UIInterfaceOrientationMask)(1 << m_lastLandscapeOrientation)
          : UIInterfaceOrientationMaskLandscape;
      UIWindowSceneGeometryPreferencesIOS* preference =
          [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
      [scene requestGeometryUpdateWithPreferences:preference errorHandler:^(NSError* error) {
        m_landscapeRequestPending = NO;
        CLog::Log(LOGWARNING, "Duo landscape request: {}", error.localizedDescription.UTF8String);
      }];
    }
    else if (m_hasActiveFold)
      m_landscapeRequestPending = NO;
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
  PRINT_SIGNATURE();
  const auto& components = CServiceBroker::GetAppComponents();
  const auto appPlayer = components.GetComponent<CApplicationPlayer>();
  if (appPlayer->IsPlaying() && !appPlayer->IsPaused())
  {
    m_isPlayingBeforeInactive = YES;
    CServiceBroker::GetAppMessenger()->SendMsg(TMSG_MEDIA_PAUSE_IF_PLAYING);
  }
  CWinSystemIOS* winSystem = dynamic_cast<CWinSystemIOS*>(CServiceBroker::GetWinSystem());
  winSystem->OnAppFocusChange(false);
}

- (void)enterForeground
{
  PRINT_SIGNATURE();
  CWinSystemIOS* winSystem = dynamic_cast<CWinSystemIOS*>(CServiceBroker::GetWinSystem());
  if (winSystem)
    winSystem->OnAppFocusChange(true);
  // when we come back, restore playing if we were.
  if (m_isPlayingBeforeInactive)
  {
    CServiceBroker::GetAppMessenger()->SendMsg(TMSG_MEDIA_UNPAUSE);
    m_isPlayingBeforeInactive = NO;
  }
}

- (void)becomeInactive
{
  // if we were interrupted, already paused here
  // else if user background us or lock screen, only pause video here, audio keep playing.
  const auto& components = CServiceBroker::GetAppComponents();
  const auto appPlayer = components.GetComponent<CApplicationPlayer>();
  if (appPlayer->IsPlayingVideo() && !appPlayer->IsPaused())
  {
    m_isPlayingBeforeInactive = YES;
    CServiceBroker::GetAppMessenger()->SendMsg(TMSG_MEDIA_PAUSE_IF_PLAYING);
  }
  // check whether we need disable network auto suspend.
  [self rescheduleNetworkAutoSuspend];
}
//--------------------------------------------------------------
- (void)pauseAnimation
{
  PRINT_SIGNATURE();

  [m_glView pauseAnimation];
}
//--------------------------------------------------------------
- (void)resumeAnimation
{
  PRINT_SIGNATURE();

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
  if ([notification.name isEqualToString:UIDeviceOrientationDidChangeNotification])
    [self updateOrientationForSceneGeometry];
//  LOG(@"default: %@", [notification name]);
//  LOG(@"userInfo: %@", [notification userInfo]);
}

- (CVEAGLContext)getEAGLContextObj
{
  return [m_glView getCurrentEAGLContext];
}

@end
