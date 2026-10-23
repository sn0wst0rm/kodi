/*
 *  Copyright (C) 2010-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "XBMCApplication.h"

#import "IOSScreenManager.h"
#import "XBMCController.h"

#import "platform/darwin/NSLogDebugHelpers.h"

#import <AVFoundation/AVAudioSession.h>

// Keep the single Kodi engine alive when UIKit reconnects its scene.
@interface XBMCSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation XBMCSceneDelegate

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions
{
  if (![scene isKindOfClass:UIWindowScene.class])
    return;

  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
  if (g_xbmcController)
    [g_xbmcController attachToWindow:self.window];
  else
  {
    XBMCController* controller = [[XBMCController alloc] initWithWindow:self.window];
    [self.window layoutIfNeeded];
    [controller.view layoutIfNeeded];
    [controller startAnimation];
  }
}

- (void)windowScene:(UIWindowScene*)windowScene
    didUpdateEffectiveGeometry:(UIWindowSceneGeometry*)previousGeometry
{
  [g_xbmcController.view setNeedsLayout];
  [g_xbmcController.view layoutIfNeeded];
  [g_xbmcController updateOrientationForSceneGeometry];
}

- (void)sceneWillResignActive:(UIScene*)scene
{
  [g_xbmcController pauseAnimation];
  [g_xbmcController becomeInactive];
}

- (void)sceneDidBecomeActive:(UIScene*)scene
{
  [g_xbmcController resumeAnimation];
  [g_xbmcController enterForeground];
}

- (void)sceneDidEnterBackground:(UIScene*)scene
{
  if (scene.activationState == UISceneActivationStateBackground)
    [g_xbmcController enterBackground];
}

- (void)sceneWillEnterForeground:(UIScene*)scene
{
  PRINT_SIGNATURE();
}

@end

@implementation XBMCApplicationDelegate

- (NSUInteger)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
  return window.rootViewController ? [window.rootViewController supportedInterfaceOrientations]
                                   : UIInterfaceOrientationMaskAll;
}

- (void)applicationWillTerminate:(UIApplication *)application
{
  PRINT_SIGNATURE();

  [g_xbmcController stopAnimation];
}

- (void)screenDidConnect:(NSNotification *)aNotification
{
  [IOSScreenManager updateResolutions];
}

- (void)screenDidDisconnect:(NSNotification *)aNotification
{
  [[IOSScreenManager sharedInstance] screenDisconnect];
}

- (void)registerScreenNotifications:(BOOL)bRegister
{
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

  if( bRegister )
  {
    //register to screen notifications
    [nc addObserver:self selector:@selector(screenDidConnect:) name:UIScreenDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(screenDidDisconnect:) name:UIScreenDidDisconnectNotification object:nil];
  }
  else
  {
    //deregister from screen notifications
    [nc removeObserver:self name:UIScreenDidConnectNotification object:nil];
    [nc removeObserver:self name:UIScreenDidDisconnectNotification object:nil];
  }
}

- (void)applicationDidFinishLaunching:(UIApplication *)application
{
  PRINT_SIGNATURE();

  [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
  [self registerScreenNotifications:YES];

  NSError *err = nil;
  if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&err])
  {
    ELOG(@"AVAudioSession setCategory failed: %@", err);
  }
  err = nil;
  if (![[AVAudioSession sharedInstance] setActive: YES error: &err])
  {
    ELOG(@"AVAudioSession setActive failed: %@", err);
  }
}

- (NSArray<UIKeyCommand*>*)keyCommands
{
  @autoreleasepool
  {
    return @[
      [UIKeyCommand keyCommandWithInput:UIKeyInputUpArrow
                          modifierFlags:kNilOptions
                                 action:@selector(upPressed)],
      [UIKeyCommand keyCommandWithInput:UIKeyInputDownArrow
                          modifierFlags:kNilOptions
                                 action:@selector(downPressed)],
      [UIKeyCommand keyCommandWithInput:UIKeyInputLeftArrow
                          modifierFlags:kNilOptions
                                 action:@selector(leftPressed)],
      [UIKeyCommand keyCommandWithInput:UIKeyInputRightArrow
                          modifierFlags:kNilOptions
                                 action:@selector(rightPressed)]
    ];
  }
}

- (void)upPressed
{
  [g_xbmcController sendKey:XBMCK_UP];
}

- (void)downPressed
{
  [g_xbmcController sendKey:XBMCK_DOWN];
}

- (void)leftPressed
{
  [g_xbmcController sendKey:XBMCK_LEFT];
}

- (void)rightPressed
{
  [g_xbmcController sendKey:XBMCK_RIGHT];
}

@end


static void SigPipeHandler(int s)
{
  NSLog(@"We Got a Pipe Single :%d____________", s);
}

int main(int argc, char *argv[]) {
  @autoreleasepool
  {
    int retVal = 0;

    signal(SIGPIPE, SigPipeHandler);

    @try
    {
      retVal = UIApplicationMain(argc, argv, nil, NSStringFromClass(XBMCApplicationDelegate.class));
    }
    @catch (id theException)
    {
      ELOG(@"%@", theException);
    }
    @finally
    {
      ILOG(@"This always happens.");
    }

    return retVal;
  }
}
