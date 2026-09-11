#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import "VCamLiveFrame.h"
#import <CoreFoundation/CoreFoundation.h>
#import "VCamPaths.h"
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>

#if __has_include(<roothide.h>)
#include <roothide.h>
#define VCAM_OVERLAY_HAS_ROOTHIDE 1
#endif

extern char **environ;

static NSString *const VCamOverlayNotification = @"com.yourcompany.vcam.adjustments.changed";
static NSString *const VCamPreferencesNotification = @"com.yourcompany.vcam.prefs.changed";

@interface VCamControlPanel : UIView
@end

@implementation VCamControlPanel
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

@interface VCamPassThroughWindow : UIWindow
@property(nonatomic, assign) BOOL vcamAllowBecomeKey;
- (void)vcamResignKeyIfNeeded;
@end

@interface VCamPassThroughWindow ()
- (BOOL)vcamShouldHandlePoint:(CGPoint)point withEvent:(UIEvent *)event;
@end

@implementation VCamPassThroughWindow
- (BOOL)canBecomeKeyWindow {
    // Tapping the floating button must not steal SpringBoard's key window.
    // If this overlay stays key, later hits that miss the button are dropped
    // and the rest of the phone appears frozen until the next app switch.
    return self.vcamAllowBecomeKey || self.rootViewController.presentedViewController != nil;
}

- (BOOL)vcamShouldHandlePoint:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.rootViewController.presentedViewController != nil) return YES;
    UIViewController *controller = self.rootViewController;
    if (!controller || controller.view.hidden || controller.view.alpha < 0.01) return NO;

    UIButton *floatingButton = [controller valueForKey:@"floatingButton"];
    UIView *panel = [controller valueForKey:@"panel"];
    if ([floatingButton isKindOfClass:[UIButton class]] && !floatingButton.hidden && floatingButton.alpha > 0.01) {
        CGPoint inButton = [self convertPoint:point toView:floatingButton];
        if ([floatingButton pointInside:inButton withEvent:event]) return YES;
        if (floatingButton.isTracking) return YES;
        for (UIGestureRecognizer *gesture in floatingButton.gestureRecognizers) {
            UIGestureRecognizerState state = gesture.state;
            if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) {
                return YES;
            }
        }
    }
    if ([panel isKindOfClass:[UIView class]] && !panel.hidden && panel.alpha > 0.01) {
        CGPoint inPanel = [self convertPoint:point toView:panel];
        if ([panel pointInside:inPanel withEvent:event]) return YES;
    }
    return NO;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // BackBoard uses pointInside, not hitTest, to choose the frontmost window.
    // The default full-screen YES swallows every touch on the device even when
    // hitTest later returns nil.
    return [self vcamShouldHandlePoint:point withEvent:event];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (![self vcamShouldHandlePoint:point withEvent:event]) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if (self.rootViewController.presentedViewController != nil) return hit;
    UIView *panel = [self.rootViewController valueForKey:@"panel"];
    if (!hit || hit == self || hit == self.rootViewController.view) {
        if ([panel isKindOfClass:[UIView class]] && !panel.hidden) {
            CGPoint inPanel = [self convertPoint:point toView:panel];
            if ([panel pointInside:inPanel withEvent:event]) return panel;
        }
        return nil;
    }
    UIView *cursor = hit;
    while (cursor && cursor != self.rootViewController.view) {
        if ([cursor isKindOfClass:[UIControl class]] ||
            [cursor isKindOfClass:[VCamControlPanel class]]) return hit;
        cursor = cursor.superview;
    }
    if ([panel isKindOfClass:[UIView class]] && !panel.hidden && [hit isDescendantOfView:panel]) {
        return hit;
    }
    return nil;
}

- (void)vcamResignKeyIfNeeded {
    if (!self.isKeyWindow) return;
    if (self.vcamAllowBecomeKey || self.rootViewController.presentedViewController != nil) return;
    UIWindow *best = nil;
    NSArray<UIWindow *> *windows = self.windowScene.windows ?: [UIApplication sharedApplication].windows;
    for (UIWindow *window in windows) {
        if (window == self || window.hidden || window.alpha < 0.01) continue;
        if (window.windowLevel > UIWindowLevelStatusBar) continue;
        if (!best || window.windowLevel >= best.windowLevel) best = window;
        if (window.windowLevel == UIWindowLevelNormal && [window canBecomeKeyWindow]) {
            best = window;
            break;
        }
    }
    [best makeKeyWindow];
}
@end

@interface VCamOverlayController : UIViewController <AVPlayerItemOutputPullDelegate>
@property(nonatomic, strong) UIButton *floatingButton;
@property(nonatomic, assign) BOOL floatingButtonDidDrag;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UILabel *sourceStatusLabel;
@property(nonatomic, strong) UISwitch *enabledSwitch;
@property(nonatomic, strong) NSTimer *remoteTimer;
@property(nonatomic, copy) NSString *remoteTimerMode;
@property(nonatomic, strong) NSData *lastRemoteFrame;
@property(nonatomic, assign) BOOL remoteRequestRunning;
@property(nonatomic, assign) pid_t remoteFFmpegPID;
@property(nonatomic, assign) NSInteger remoteFFmpegMode;
@property(nonatomic, strong) NSDate *remoteFFmpegStartedAt;
@property(nonatomic, strong) NSDate *lastRemoteVideoModification;
@property(nonatomic, copy) NSString *remoteFFmpegInputURL;
@property(nonatomic, assign) NSInteger remoteFallbackStage;
@property(nonatomic, strong) AVPlayer *nativePlayer;
@property(nonatomic, strong) AVPlayerItemVideoOutput *nativeOutput;
@property(nonatomic, strong) CADisplayLink *nativeDisplayLink;
@property(nonatomic, strong) CIContext *nativeCIContext;
@property(nonatomic, strong) NSDate *nativeStartedAt;
@property(nonatomic, assign) BOOL nativeEncodePending;
@property(nonatomic, assign) BOOL nativeDecoderActive;
@property(nonatomic, assign) NSUInteger nativeFrameCounter;
@property(nonatomic, assign) CMTime nativeLastItemTime;
@property(nonatomic, strong) WKWebView *webLiveView;
@property(nonatomic, strong) CADisplayLink *webCaptureDisplayLink;
@property(nonatomic, strong) NSDate *webStartedAt;
@property(nonatomic, assign) BOOL webDecoderActive;
@property(nonatomic, assign) BOOL webCapturePending;
@property(nonatomic, assign) NSUInteger webCaptureGeneration;
- (void)refreshFromPreferences;
- (NSString *)rtspFaceLabURLFromURL:(NSString *)urlString;
- (NSString *)hlsFaceLabURLFromURL:(NSString *)urlString;
- (BOOL)startNativeDecoderAtURL:(NSString *)urlString;
- (void)stopNativeDecoder;
- (void)nativeDisplayTick:(CADisplayLink *)link;
- (BOOL)startWebDecoderAtURL:(NSString *)urlString;
- (void)stopWebDecoder;
- (void)webCaptureTick:(CADisplayLink *)link;
- (void)vcamApplicationWillResignActive:(NSNotification *)notification;
- (void)vcamApplicationDidBecomeActive:(NSNotification *)notification;
- (UIButton *)smallButton:(NSString *)title action:(SEL)action;
- (UIButton *)wideButton:(NSString *)title action:(SEL)action;
- (UILabel *)panelLabel:(NSString *)text;
- (void)fetchRemoteFrame;
- (void)stopRemoteFFmpeg;
@end

static BOOL VCamLooksLikeFaceLabHTTPURL(NSURLComponents *components) {
    NSInteger port = components.port.integerValue;
    // FaceLab may move its HTTP listener when a previous debug instance is
    // still holding 8080 (the current build uses 8084). Keep the mapping
    // limited to FaceLab's 8080-range ports so ordinary MP4 URLs elsewhere
    // are still passed to FFmpeg unchanged.
    return port >= 8080 && port <= 8099;
}

static __weak VCamOverlayController *vcamOverlayController = nil;

static void VCamPreferencesDidChange(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [vcamOverlayController refreshFromPreferences];
    });
}

@implementation VCamOverlayController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    self.floatingButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.floatingButton.frame = CGRectMake(CGRectGetWidth(self.view.bounds) - 58.0,
        CGRectGetHeight(self.view.bounds) * 0.42, 46.0, 46.0);
    self.floatingButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.floatingButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.92];
    self.floatingButton.layer.cornerRadius = 23.0;
    self.floatingButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatingButton.layer.shadowOpacity = 0.35;
    self.floatingButton.layer.shadowRadius = 5.0;
    self.floatingButton.layer.shadowOffset = CGSizeMake(0, 2);
    [self.floatingButton setTitle:@"VC" forState:UIControlStateNormal];
    [self.floatingButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.floatingButton.titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    [self.floatingButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    self.floatingButton.exclusiveTouch = YES;
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(dragButton:)];
    drag.cancelsTouchesInView = NO;
    [self.floatingButton addGestureRecognizer:drag];
    [self.view addSubview:self.floatingButton];

    [self buildPanel];
    vcamOverlayController = self;
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(vcamApplicationWillResignActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(vcamApplicationDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self refreshFromPreferences];
}

- (void)buildPanel {
    CGFloat width = MIN(276.0, CGRectGetWidth(self.view.bounds) - 24.0);
    self.panel = [[VCamControlPanel alloc] initWithFrame:CGRectMake(0, 0, width, 410.0)];
    self.panel.center = self.view.center;
    self.panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
    self.panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.58];
    self.panel.layer.cornerRadius = 15.0;
    self.panel.layer.borderWidth = 1.0;
    self.panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    self.panel.hidden = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 6, width - 60, 30)];
    title.text = @"Điều khiển VCam";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17.0];
    [self.panel addSubview:title];

    UIButton *close = [self smallButton:@"×" action:@selector(togglePanel)];
    close.frame = CGRectMake(width - 42, 4, 36, 34);
    [self.panel addSubview:close];
    self.enabledSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(width - 86, 42, 60, 30)];
    [self.enabledSwitch addTarget:self action:@selector(enabledSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.enabledSwitch];

    CGFloat centerX = width / 2.0;
    UIButton *up = [self smallButton:@"↑" action:@selector(moveUp)];
    up.frame = CGRectMake(centerX - 22, 38, 44, 36);
    UIButton *left = [self smallButton:@"←" action:@selector(moveLeft)];
    left.frame = CGRectMake(centerX - 72, 78, 44, 36);
    UIButton *reset = [self smallButton:@"●" action:@selector(resetAdjustments)];
    reset.frame = CGRectMake(centerX - 22, 78, 44, 36);
    UIButton *right = [self smallButton:@"→" action:@selector(moveRight)];
    right.frame = CGRectMake(centerX + 28, 78, 44, 36);
    UIButton *down = [self smallButton:@"↓" action:@selector(moveDown)];
    down.frame = CGRectMake(centerX - 22, 118, 44, 36);
    for (UIButton *button in @[up, left, reset, right, down]) [self.panel addSubview:button];

    UILabel *zoomLabel = [self panelLabel:@"Zoom"];
    zoomLabel.frame = CGRectMake(12, 160, 56, 32);
    [self.panel addSubview:zoomLabel];
    UIButton *zoomOut = [self wideButton:@"−" action:@selector(zoomOut)];
    zoomOut.frame = CGRectMake(70, 160, 88, 32);
    UIButton *zoomIn = [self wideButton:@"＋" action:@selector(zoomIn)];
    zoomIn.frame = CGRectMake(164, 160, width - 176, 32);
    [self.panel addSubview:zoomOut];
    [self.panel addSubview:zoomIn];

    UILabel *brightnessLabel = [self panelLabel:@"Độ sáng"];
    brightnessLabel.frame = CGRectMake(12, 200, 56, 32);
    [self.panel addSubview:brightnessLabel];
    UIButton *darken = [self wideButton:@"−" action:@selector(darken)];
    darken.frame = CGRectMake(70, 200, 88, 32);
    UIButton *brighten = [self wideButton:@"＋" action:@selector(brighten)];
    brighten.frame = CGRectMake(164, 200, width - 176, 32);
    [self.panel addSubview:darken];
    [self.panel addSubview:brighten];

    UILabel *rotationLabel = [self panelLabel:@"Xoay 360°"];
    rotationLabel.frame = CGRectMake(12, 240, 56, 32);
    [self.panel addSubview:rotationLabel];
    UIButton *rotateLeft = [self wideButton:@"↺ 15°" action:@selector(rotateLeft)];
    rotateLeft.titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    rotateLeft.frame = CGRectMake(70, 240, 88, 32);
    UIButton *rotateRight = [self wideButton:@"↻ 15°" action:@selector(rotateRight)];
    rotateRight.titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    rotateRight.frame = CGRectMake(164, 240, width - 176, 32);
    [self.panel addSubview:rotateLeft];
    [self.panel addSubview:rotateRight];

    UILabel *flipLabel = [self panelLabel:@"Lật"];
    flipLabel.frame = CGRectMake(12, 280, 56, 32);
    [self.panel addSubview:flipLabel];
    UIButton *flipHorizontal = [self wideButton:@"↔ Ngang" action:@selector(flipHorizontal)];
    flipHorizontal.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    flipHorizontal.frame = CGRectMake(70, 280, 88, 32);
    UIButton *flipVertical = [self wideButton:@"↕ Dọc" action:@selector(flipVertical)];
    flipVertical.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    flipVertical.frame = CGRectMake(164, 280, width - 176, 32);
    [self.panel addSubview:flipHorizontal];
    [self.panel addSubview:flipVertical];

    UIButton *pickImage = [self wideButton:@"Ảnh" action:@selector(openImagePicker)];
    pickImage.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    pickImage.frame = CGRectMake(12, 320, 76, 34);
    UIButton *pickVideo = [self wideButton:@"Video" action:@selector(openVideoPicker)];
    pickVideo.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    pickVideo.frame = CGRectMake(94, 320, 76, 34);
    UIButton *remoteSource = [self wideButton:@"Link live" action:@selector(enterRemoteSource)];
    remoteSource.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    remoteSource.frame = CGRectMake(176, 320, width - 188, 34);
    [self.panel addSubview:pickImage];
    [self.panel addSubview:pickVideo];
    [self.panel addSubview:remoteSource];

    self.sourceStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 360, width - 24, 18)];
    self.sourceStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.sourceStatusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    self.sourceStatusLabel.font = [UIFont systemFontOfSize:10.5];
    self.sourceStatusLabel.adjustsFontSizeToFitWidth = YES;
    [self.panel addSubview:self.sourceStatusLabel];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(12, 385, width - 24, 18)];
    hint.text = @"● đặt lại  •  kéo nút VC để di chuyển";
    hint.textAlignment = NSTextAlignmentCenter;
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    hint.font = [UIFont systemFontOfSize:10.5];
    [self.panel addSubview:hint];
    [self.view addSubview:self.panel];
}

- (NSDictionary *)mainPreferences {
    return [NSDictionary dictionaryWithContentsOfFile:VCamPreferencesFile()] ?: @{};
}

- (void)writeMainPreferences:(NSDictionary *)preferences {
    [preferences writeToFile:VCamPreferencesFile() atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{
        NSFilePosixPermissions: @0666, NSFileProtectionKey: NSFileProtectionNone
    } ofItemAtPath:VCamPreferencesFile() error:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)VCamPreferencesNotification, NULL, NULL, YES);
}

- (void)refreshFromPreferences {
    NSDictionary *preferences = [self mainPreferences];
    id enabledValue = preferences[@"enabled"];
    BOOL enabled = enabledValue == nil ? YES : [enabledValue boolValue];
    self.enabledSwitch.on = enabled;
    self.view.hidden = !enabled;
    self.view.userInteractionEnabled = enabled;
    if ([self.view.window isKindOfClass:[VCamPassThroughWindow class]]) {
        self.view.window.userInteractionEnabled = enabled;
    }
    if (!enabled) {
        self.panel.hidden = YES;
        [self.remoteTimer invalidate];
        self.remoteTimer = nil;
        self.remoteRequestRunning = NO;
        [self stopNativeDecoder];
        [self stopWebDecoder];
        [self stopRemoteFFmpeg];
        return;
    }

    NSString *remoteURL = preferences[@"remoteURL"];
    if ([remoteURL isKindOfClass:[NSString class]] && remoteURL.length > 0) {
        NSString *savedMode = [preferences[@"remoteMode"] isKindOfClass:[NSString class]]
            ? preferences[@"remoteMode"] : @"image";
        // All live links now use WebRTC/WHEP, matching FaceLab's Safari path.
        // Migrate preferences created by older builds so legacy live modes
        // cannot start FFmpeg or the experimental native decoder.
        NSString *mode = @"web";
        if (![savedMode isEqualToString:@"web"]) {
            NSMutableDictionary *migrated = [preferences mutableCopy];
            migrated[@"remoteMode"] = @"web";
            [self writeMainPreferences:migrated];
        }
        // Restore the native MediaMTX input after the overlay/app is
        // recreated. The in-memory fallback URL is otherwise lost on restart.
        if (([mode isEqualToString:@"video"] || [mode isEqualToString:@"native"] || [mode isEqualToString:@"web"]) && self.remoteFFmpegInputURL.length == 0) {
            NSURL *savedURL = [NSURL URLWithString:remoteURL];
            if ([savedURL.scheme.lowercaseString isEqualToString:@"http"] ||
                [savedURL.scheme.lowercaseString isEqualToString:@"https"]) {
                BOOL directHLS = [savedURL.path.pathExtension.lowercaseString isEqualToString:@"m3u8"];
                self.remoteFFmpegInputURL = directHLS
                    ? [self hlsFaceLabURLFromURL:remoteURL]
                    : [self rtspFaceLabURLFromURL:remoteURL];
                self.remoteFallbackStage = self.remoteFFmpegInputURL.length > 0 ? (directHLS ? 0 : 1) : 0;
            } else {
                if ([savedURL.scheme.lowercaseString isEqualToString:@"rtsp"]) {
                    self.remoteFFmpegInputURL = remoteURL;
                    self.remoteFallbackStage = 1;
                } else {
                    self.remoteFFmpegInputURL = remoteURL;
                    self.remoteFallbackStage = 2;
                }
            }
        }
        // The source may be 30 FPS, but the iPhone 7 Plus has to decode the
        // H.264 stream and mediaserverd then consumes the generated JPEG. A
        BOOL videoMode = [mode isEqualToString:@"video"] || [mode isEqualToString:@"native"] || [mode isEqualToString:@"web"];
        // WebRTC already has a display-link capturer. This timer is only a
        // stalled-stream watchdog; running it at 24 Hz on SpringBoard main
        // thread made the floating button hitch and freeze other touches.
        NSTimeInterval interval = [mode isEqualToString:@"web"] ? 2.0 : (videoMode ? (1.0 / 24.0) : 1.0);
        self.sourceStatusLabel.text = [mode isEqualToString:@"native"]
            ? @"Video native (thử nghiệm)" : (videoMode
                ? @"Video live độ trễ thấp" : @"Nguồn ảnh live cập nhật mỗi giây");
        if ([mode isEqualToString:@"web"]) self.sourceStatusLabel.text = @"WebRTC live";
        if ([mode isEqualToString:@"web"] && !self.webDecoderActive) {
            if (![self startWebDecoderAtURL:remoteURL]) {
                self.sourceStatusLabel.text = @"Khong khoi dong duoc WebRTC";
                return;
            }
        } else if ([mode isEqualToString:@"native"] && !self.nativeDecoderActive) {
            // Native decoding is explicitly opt-in. Never let a failed HLS
            // output replace the normal video mode silently.
            if (![self startNativeDecoderAtURL:remoteURL]) {
                NSMutableDictionary *updated = [preferences mutableCopy];
                updated[@"remoteMode"] = @"video";
                [self writeMainPreferences:updated];
                mode = @"video";
            }
        } else if (![mode isEqualToString:@"native"] && self.nativeDecoderActive) {
            [self stopNativeDecoder];
            NSString *liveJPEG = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"];
            if ([preferences[@"mediaPath"] hasSuffix:@"media-live.nv12"]) {
                NSMutableDictionary *updated = [preferences mutableCopy];
                updated[@"enabled"] = @YES;
                updated[@"mediaPath"] = liveJPEG;
                [self writeMainPreferences:updated];
            }
        }
        if (![mode isEqualToString:@"web"] && self.webDecoderActive) [self stopWebDecoder];
        if (!self.remoteTimer || ![self.remoteTimerMode isEqualToString:mode]) {
            [self.remoteTimer invalidate];
            self.remoteTimerMode = mode;
            self.remoteTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self
                selector:@selector(fetchRemoteFrame) userInfo:nil repeats:YES];
            [self fetchRemoteFrame];
        }
    } else {
        [self.remoteTimer invalidate];
        self.remoteTimer = nil;
        self.remoteTimerMode = nil;
        self.sourceStatusLabel.text = @"Chọn ảnh, video hoặc nhập link live";
        [self stopNativeDecoder];
        [self stopWebDecoder];
        [self stopRemoteFFmpeg];
    }
}

- (void)enabledSwitchChanged:(UISwitch *)sender {
    NSMutableDictionary *updated = [[self mainPreferences] mutableCopy];
    updated[@"enabled"] = @(sender.isOn);
    [self writeMainPreferences:updated];
    if (!sender.isOn) self.panel.hidden = YES;
}

- (void)openVCamPath:(NSString *)path {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"vcam://pick/%@", path]];
    if (!url) return;
    self.panel.hidden = YES;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)openImagePicker { [self openVCamPath:@"image"]; }
- (void)openVideoPicker { [self openVCamPath:@"video"]; }

- (void)enterRemoteSource {
    // Single live-link mode: WebRTC/WHEP. Keep the legacy implementation
    // below unreachable for compatibility with older saved preferences.
    NSDictionary *webPreferences = [self mainPreferences];
    UIAlertController *webAlert = [UIAlertController alertControllerWithTitle:@"Link live WebRTC"
        message:@"Nhap URL FaceLab. VCam se nhan luong WebRTC/WHEP nhu Safari."
        preferredStyle:UIAlertControllerStyleAlert];
    [webAlert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"http://192.168.x.x:8080/1_ios.mp4";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        NSString *saved = webPreferences[@"remoteURL"];
        if ([saved isKindOfClass:[NSString class]]) field.text = saved;
    }];
    [webAlert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [webAlert addAction:[UIAlertAction actionWithTitle:@"Luu WebRTC" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            NSString *value = [webAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSURL *url = [NSURL URLWithString:value];
            if (!url || ![@[@"http", @"https", @"rtsp"] containsObject:url.scheme.lowercaseString]) {
                self.sourceStatusLabel.text = @"Link khong hop le";
                return;
            }
            [self stopRemoteFFmpeg];
            [self stopNativeDecoder];
            [self stopWebDecoder];
            NSMutableDictionary *updated = [[self mainPreferences] mutableCopy];
            updated[@"enabled"] = @YES;
            updated[@"remoteURL"] = value;
            updated[@"remoteMode"] = @"web";
            [self writeMainPreferences:updated];
            [self refreshFromPreferences];
        }]];
    [self presentViewController:webAlert animated:YES completion:nil];
    return;

#if 0
    NSDictionary *preferences = [self mainPreferences];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Nguồn ảnh/video live"
        message:@"Nhập URL HTTPS trả về ảnh JPEG/PNG hiện tại. VCam sẽ tải frame mới mỗi giây."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://server/camera.jpg";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        NSString *saved = preferences[@"remoteURL"];
        if ([saved isKindOfClass:[NSString class]]) field.text = saved;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    if ([preferences[@"remoteURL"] length] > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Xóa link" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *action) {
                NSMutableDictionary *updated = [[self mainPreferences] mutableCopy];
                [updated removeObjectForKey:@"remoteURL"];
                [updated removeObjectForKey:@"remoteMode"];
                [self writeMainPreferences:updated];
            }]];
    }
    void (^saveRemote)(NSString *) = ^(NSString *mode) {
        NSString *value = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSURL *url = [NSURL URLWithString:value];
        NSArray *schemes = ([mode isEqualToString:@"video"] || [mode isEqualToString:@"native"] || [mode isEqualToString:@"web"])
            ? @[@"http", @"https", @"rtsp"] : @[@"http", @"https"];
        if (!url || ![schemes containsObject:url.scheme.lowercaseString]) {
            self.sourceStatusLabel.text = @"Link không hợp lệ";
            return;
        }
        [self stopRemoteFFmpeg];
        [self stopNativeDecoder];
        [self stopWebDecoder];
        self.lastRemoteFrame = nil;
        self.lastRemoteVideoModification = nil;
        self.remoteFFmpegInputURL = nil;
        self.remoteFallbackStage = 0;
        if ([mode isEqualToString:@"video"] || [mode isEqualToString:@"native"] || [mode isEqualToString:@"web"]) {
            // FaceLab's public HTTP URL is an HTML WebRTC page. FFmpeg on
            // iOS cannot consume that page; MediaMTX exposes the H.264 stream
            // as RTSP for native clients.
            BOOL directHLS = [url.path.pathExtension.lowercaseString isEqualToString:@"m3u8"];
            NSString *liveURL = directHLS
                ? [self hlsFaceLabURLFromURL:value]
                : [self rtspFaceLabURLFromURL:value];
            if (liveURL.length > 0) {
                self.remoteFFmpegInputURL = liveURL;
                self.remoteFallbackStage = directHLS ? 0 : 1;
            }
        }
        NSMutableDictionary *updated = [[self mainPreferences] mutableCopy];
        updated[@"enabled"] = @YES;
        updated[@"remoteURL"] = value;
        updated[@"remoteMode"] = mode;
        [self writeMainPreferences:updated];
        [self refreshFromPreferences];
    };
    [alert addAction:[UIAlertAction actionWithTitle:@"Ảnh live" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            saveRemote(@"image");
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Video live" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) { saveRemote(@"video"); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Video native (thử nghiệm)" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) { saveRemote(@"native"); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Video WebRTC (Safari)" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) { saveRemote(@"web"); }]];
    [self presentViewController:alert animated:YES completion:nil];
#endif
}

- (void)fetchRemoteFrame {
    if (self.remoteRequestRunning) return;
    NSDictionary *preferences = [self mainPreferences];
    NSString *urlString = preferences[@"remoteURL"];
    NSString *remoteMode = preferences[@"remoteMode"];
    if ([remoteMode isEqualToString:@"web"]) {
        NSString *destination = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:destination error:nil];
        NSDate *modified = attributes[NSFileModificationDate];
        BOOL fresh = modified && self.webStartedAt && [modified compare:self.webStartedAt] != NSOrderedAscending;
        if (self.webStartedAt && !fresh && -self.webStartedAt.timeIntervalSinceNow > 10.0) {
            [self stopWebDecoder];
            NSMutableDictionary *updated = [preferences mutableCopy];
            updated[@"remoteMode"] = @"web";
            [self writeMainPreferences:updated];
        }
        return;
    }
    if ([remoteMode isEqualToString:@"video"] || [remoteMode isEqualToString:@"native"]) {
        if (self.nativeDecoderActive) {
            NSString *destination = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"];
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:destination error:nil];
            NSDate *modified = attributes[NSFileModificationDate];
            BOOL hasFreshPreview = modified && self.nativeStartedAt &&
                [modified compare:self.nativeStartedAt] != NSOrderedAscending;
            if (self.nativeStartedAt && (!hasFreshPreview) && -self.nativeStartedAt.timeIntervalSinceNow > 8.0) {
                [self stopNativeDecoder];
                if ([remoteMode isEqualToString:@"native"]) {
                    NSMutableDictionary *updated = [preferences mutableCopy];
                    updated[@"remoteMode"] = @"video";
                    [self writeMainPreferences:updated];
                }
            } else {
                return;
            }
        }
        [self monitorRemoteVideoAtURL:urlString];
        return;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    self.remoteRequestRunning = YES;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.remoteRequestRunning = NO;
                NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                    ? (NSHTTPURLResponse *)response : nil;
                UIImage *image = data.length <= 20 * 1024 * 1024 ? [UIImage imageWithData:data] : nil;
                if (error || (http && http.statusCode >= 400) || !image) {
                    self.sourceStatusLabel.text = @"Link chưa trả về JPEG/PNG hợp lệ";
                    return;
                }
                if ([data isEqualToData:self.lastRemoteFrame]) return;
                self.lastRemoteFrame = data;

                CGFloat longest = MAX(image.size.width, image.size.height);
                CGFloat scale = longest > 1280.0 ? 1280.0 / longest : 1.0;
                CGSize size = CGSizeMake(MAX(1.0, image.size.width * scale),
                    MAX(1.0, image.size.height * scale));
                UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
                [image drawInRect:(CGRect){CGPointZero, size}];
                UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                NSData *jpeg = UIImageJPEGRepresentation(resized, 0.86);
                NSString *destination = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"];
                if (![jpeg writeToFile:destination options:NSDataWritingAtomic error:nil]) {
                    self.sourceStatusLabel.text = @"Không ghi được frame live";
                    return;
                }
                [[NSFileManager defaultManager] setAttributes:@{
                    NSFilePosixPermissions: @0666, NSFileProtectionKey: NSFileProtectionNone
                } ofItemAtPath:destination error:nil];
                NSMutableDictionary *updated = [[self mainPreferences] mutableCopy];
                updated[@"enabled"] = @YES;
                updated[@"mediaPath"] = destination;
                [self writeMainPreferences:updated];
                self.sourceStatusLabel.text = @"Live: đã nhận frame mới";
            });
        }] resume];
}

- (NSString *)ffmpegPath {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
#if VCAM_OVERLAY_HAS_ROOTHIDE
    NSString *rootHidePath = jbroot(@"/usr/bin/ffmpeg");
    if (rootHidePath.length) [paths addObject:rootHidePath];
#endif
    [paths addObjectsFromArray:@[@"/var/jb/usr/bin/ffmpeg", @"/usr/bin/ffmpeg", @"/usr/local/bin/ffmpeg"]];
    for (NSString *path in paths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

- (void)stopRemoteFFmpeg {
    if (self.remoteFFmpegPID > 0) {
        kill(self.remoteFFmpegPID, SIGTERM);
        waitpid(self.remoteFFmpegPID, NULL, WNOHANG);
        self.remoteFFmpegPID = 0;
    }
    self.remoteFFmpegMode = 0;
    self.remoteFFmpegStartedAt = nil;
}

- (void)stopNativeDecoder {
    [self.nativeDisplayLink invalidate];
    self.nativeDisplayLink = nil;
    [self.nativePlayer pause];
    self.nativePlayer = nil;
    self.nativeOutput = nil;
    self.nativeStartedAt = nil;
    self.nativeDecoderActive = NO;
    self.nativeEncodePending = NO;
    self.nativeFrameCounter = 0;
    self.nativeLastItemTime = kCMTimeInvalid;
}

- (void)stopWebDecoder {
    self.webCaptureGeneration++;
    [self.webCaptureDisplayLink invalidate];
    self.webCaptureDisplayLink = nil;
    self.webDecoderActive = NO;
    self.webCapturePending = NO;
    self.webStartedAt = nil;
    [self.webLiveView stopLoading];
    [self.webLiveView removeFromSuperview];
    self.webLiveView = nil;
}

- (void)vcamApplicationWillResignActive:(NSNotification *)notification {
    // A WKWebView lives in SpringBoard's process on this tweak. When the
    // camera is dismissed from the app switcher, WebKit can otherwise keep a
    // compositor/snapshot callback alive while mediaserverd is tearing down
    // the camera session. Stop every live producer before that transition.
    [self.remoteTimer invalidate];
    self.remoteTimer = nil;
    [self stopWebDecoder];
    [self stopNativeDecoder];
    [self stopRemoteFFmpeg];
}

- (void)vcamApplicationDidBecomeActive:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshFromPreferences];
    });
}

- (BOOL)startWebDecoderAtURL:(NSString *)urlString {
    NSURLComponents *source = [NSURLComponents componentsWithString:urlString];
    if (!source.host) return NO;
    // FaceLab's HTTP listener may be 8080-8099, but MediaMTX WHEP is always
    // exposed on 8889. Do not derive 8085 from a source URL such as
    // http://host:8084/1_ios.mp4; that endpoint has no WebRTC handler.
    NSString *whep = [NSString stringWithFormat:@"http://%@:8889/facelab/whep", source.host];
    NSURL *whepURL = [NSURL URLWithString:whep];
    if (!whepURL) return NO;
    [self stopWebDecoder];
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.allowsInlineMediaPlayback = YES;
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    // FaceLab's camera output is portrait (404x720). Keep the WebRTC
    // snapshot canvas portrait too; a 16:9 canvas would bake large black
    // side bars into the JPEG before VCam's own aspect-fit preview sees it.
    WKWebView *web = [[WKWebView alloc] initWithFrame:CGRectMake(-2000, -2000, 405, 720)
        configuration:configuration];
    web.backgroundColor = UIColor.blackColor;
    web.opaque = NO;
    // Do not make the WebView transparent. WKWebView snapshots preserve the
    // view's alpha, so the previous 0.01 value produced an almost-black
    // camera frame even though WebRTC was connected. The view remains fully
    // off-screen and cannot cover the user's UI. Overlay pointInside only
    // claims the floating button and panel, so this WebView cannot steal touches.
    web.alpha = 1.0;
    web.userInteractionEnabled = NO;
    [self.view addSubview:web];
    self.webLiveView = web;
    self.webStartedAt = [NSDate date];
    self.webDecoderActive = YES;
    NSString *whepString = [whepURL.absoluteString stringByReplacingOccurrencesOfString:@"'" withString:@"%27"];
    NSString *html = [NSString stringWithFormat:
        @"<html><head><meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no'></head><body style='margin:0;padding:0;width:405px;height:720px;background:#000;overflow:hidden'><video id='v' autoplay muted playsinline style='display:block;width:405px;height:720px;object-fit:contain'></video><script>const v=document.getElementById('v');const u='%@';async function go(){try{let p=new RTCPeerConnection({iceServers:[],bundlePolicy:'max-bundle'});p.addTransceiver('video',{direction:'recvonly'});p.ontrack=e=>{v.srcObject=e.streams[0];v.play().catch(()=>{})};let o=await p.createOffer();await p.setLocalDescription(o);let r=await fetch(u,{method:'POST',headers:{'Content-Type':'application/sdp','Accept':'application/sdp'},body:o.sdp,cache:'no-store'});if(!r.ok)throw 0;await p.setRemoteDescription({type:'answer',sdp:await r.text()})}catch(e){setTimeout(go,500)}}go();</script></body></html>", whepString];
    NSURL *originURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%ld/",
        source.host, (long)(source.port.integerValue > 0 ? source.port.integerValue : 8080)]];
    [web loadHTMLString:html baseURL:originURL];
    self.webCaptureDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(webCaptureTick:)];
    // Ask WebKit for a 30 FPS cadence, but keep the single-flight guard
    // below so a slow snapshot never creates a backlog of old frames.
    self.webCaptureDisplayLink.preferredFramesPerSecond = 30;
    // Default mode only: CommonModes also runs during touch tracking and
    // would stall SpringBoard while the user drags the floating button.
    [self.webCaptureDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    NSMutableDictionary *preferences = [[self mainPreferences] mutableCopy];
    preferences[@"enabled"] = @YES;
    preferences[@"mediaPath"] = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"];
    [self writeMainPreferences:preferences];
    self.sourceStatusLabel.text = @"WebRTC Safari (thử nghiệm)";
    return YES;
}

- (void)webCaptureTick:(CADisplayLink *)link {
    if (!self.webDecoderActive || self.webCapturePending || !self.webLiveView) return;
    self.webCapturePending = YES;
    NSUInteger generation = self.webCaptureGeneration;
    WKSnapshotConfiguration *configuration = [[WKSnapshotConfiguration alloc] init];
    configuration.rect = CGRectMake(0, 0, 405, 720);
    configuration.snapshotWidth = @405;
    __weak typeof(self) weakSelf = self;
    [self.webLiveView takeSnapshotWithConfiguration:configuration completionHandler:^(UIImage *image, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.webCaptureGeneration || !self.webDecoderActive) return;
        // Snapshot completion is delivered on the main queue. JPEG encoding
        // and file I/O must not run there: doing so blocks SpringBoard during
        // the home/app-switcher animation and can leave touch input frozen.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                // 0.92 is visually indistinguishable at 720 px, while it
                // reduces A10 JPEG work and file size enough to keep up with
                // the 30 FPS capture cadence.
                NSData *jpeg = (image && !error) ? UIImageJPEGRepresentation(image, 0.92) : nil;
                if (jpeg.length > 0 && generation == self.webCaptureGeneration && self.webDecoderActive) {
                    [jpeg writeToFile:[VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"] options:NSDataWritingAtomic error:nil];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation == self.webCaptureGeneration) self.webCapturePending = NO;
                });
            }
        });
    }];
}

- (BOOL)startNativeDecoderAtURL:(NSString *)urlString {
    NSString *hlsURL = [self hlsFaceLabURLFromURL:urlString];
    if (hlsURL.length == 0) return NO;
    [self stopNativeDecoder];
    NSURL *url = [NSURL URLWithString:hlsURL];
    if (!url) return NO;
    unlink([VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.nv12"].fileSystemRepresentation);
    unlink([VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"].fileSystemRepresentation);

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        // Keep the cross-process NV12 file small enough for an A10 device.
        // The camera hook scales this frame to the target buffer.
        (id)kCVPixelBufferWidthKey : @640,
        (id)kCVPixelBufferHeightKey : @360,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    AVPlayerItemVideoOutput *output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:settings];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    item.preferredForwardBufferDuration = 0.10;
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
    [output setDelegate:self queue:dispatch_get_main_queue()];
    [item addOutput:output];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    self.nativeOutput = output;
    self.nativePlayer = player;
    self.nativeCIContext = self.nativeCIContext ?: [CIContext context];
    self.nativeStartedAt = [NSDate date];
    self.nativeDecoderActive = YES;
    self.nativeLastItemTime = kCMTimeInvalid;
    self.nativeDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(nativeDisplayTick:)];
    self.nativeDisplayLink.preferredFramesPerSecond = 30;
    [self.nativeDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    player.automaticallyWaitsToMinimizeStalling = NO;
    [player play];
    player.rate = 1.0;
    [output requestNotificationOfMediaDataChangeWithAdvanceInterval:0.10];
    NSMutableDictionary *nativePreferences = [[self mainPreferences] mutableCopy];
    nativePreferences[@"enabled"] = @YES;
    nativePreferences[@"mediaPath"] = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.nv12"];
    [self writeMainPreferences:nativePreferences];
    self.sourceStatusLabel.text = @"Native VideoToolbox…";
        return YES;
}

- (void)outputMediaDataWillChange:(AVPlayerItemOutput *)sender {
    if (!self.nativeDecoderActive) return;
    self.nativeDisplayLink.paused = NO;
    [self.nativeOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:0.10];
}

- (void)outputSequenceWasFlushed:(AVPlayerItemOutput *)output {
    self.nativeLastItemTime = kCMTimeInvalid;
}

- (void)nativeDisplayTick:(CADisplayLink *)link {
    if (!self.nativeDecoderActive || self.nativeEncodePending) return;
    // AVPlayerItemVideoOutput's timebase is driven by the host clock for a
    // live HLS item. Using AVPlayer.currentTime can remain pinned to the first
    // segment, which produces one frame until VCam is toggled. Pull the newest
    // host-time sample instead.
    CMTime itemTime = [self.nativeOutput itemTimeForHostTime:CACurrentMediaTime()];
    if (!CMTIME_IS_VALID(itemTime)) return;
    if (![self.nativeOutput hasNewPixelBufferForItemTime:itemTime]) return;
    CVPixelBufferRef pixelBuffer = [self.nativeOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
    if (!pixelBuffer) return;
    self.nativeLastItemTime = itemTime;
    self.nativeEncodePending = YES;
    BOOL makePreviewJPEG = ((++self.nativeFrameCounter % 4) == 0);
    NSString *destination = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.nv12"];
    NSString *previewDestination = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"];
    CIContext *previewContext = self.nativeCIContext;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
                uint32_t width = (uint32_t)CVPixelBufferGetWidth(pixelBuffer);
                uint32_t height = (uint32_t)CVPixelBufferGetHeight(pixelBuffer);
                uint32_t yStride = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
                uint32_t uvStride = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
                VCamLiveNV12Header header = {
                    VCAM_LIVE_NV12_MAGIC, width, height, yStride, uvStride,
                    (uint64_t)CACurrentMediaTime() * 1000000.0
                };
                NSMutableData *raw = [NSMutableData dataWithBytes:&header length:sizeof(header)];
                const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
                const uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
                [raw appendBytes:y length:(NSUInteger)yStride * height];
                [raw appendBytes:uv length:(NSUInteger)uvStride * ((height + 1) / 2)];
                CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                NSString *temporary = [destination stringByAppendingString:@".tmp"];
                if ([raw writeToFile:temporary options:0 error:nil]) {
                    rename(temporary.fileSystemRepresentation, destination.fileSystemRepresentation);
                }
                if (makePreviewJPEG && previewContext) {
                    CIImage *previewImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
                    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                    NSData *jpeg = [previewContext JPEGRepresentationOfImage:previewImage
                        colorSpace:colorSpace options:@{(id)kCGImageDestinationLossyCompressionQuality: @0.78}];
                    CGColorSpaceRelease(colorSpace);
                    [jpeg writeToFile:previewDestination options:NSDataWritingAtomic error:nil];
                }
                [[NSFileManager defaultManager] setAttributes:@{
                    NSFilePosixPermissions: @0666, NSFileProtectionKey: NSFileProtectionNone
                } ofItemAtPath:destination error:nil];
            }
            CVPixelBufferRelease(pixelBuffer);
            dispatch_async(dispatch_get_main_queue(), ^{ self.nativeEncodePending = NO; });
        }
    });
}

- (void)startRemoteFFmpegAtURL:(NSString *)urlString useToneMap:(BOOL)useToneMap {
    NSString *ffmpeg = [self ffmpegPath];
    if (!ffmpeg) {
        self.sourceStatusLabel.text = @"Thiếu FFmpeg, hãy cài lại VCam";
        return;
    }
    NSString *destination = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"];
    unlink(destination.fileSystemRepresentation);
    const char *executable = ffmpeg.fileSystemRepresentation;
    NSString *inputURL = self.remoteFFmpegInputURL.length > 0 ? self.remoteFFmpegInputURL : urlString;
    // Do not use zscale here.  The Procursus FFmpeg shipped on many iOS 15
    // jailbreaks (including iPhone 7/A10) is built without libzimg, so merely
    // mentioning zscale makes FFmpeg abort before producing its first frame.
    // This filter is available in the small FFmpeg package and is also much
    // lighter on the A10 while keeping a steady 20 FPS for the camera hook.
    // JPEG is full-range, therefore expand limited-range movie YUV explicitly.
    const char *filter =
        "fps=24,scale=400:400:force_original_aspect_ratio=decrease:in_range=tv:out_range=pc,format=yuvj420p";
    BOOL isRTSP = [inputURL.lowercaseString hasPrefix:@"rtsp://"];
    NSMutableArray<NSString *> *argumentStrings = [NSMutableArray arrayWithObjects:
        ffmpeg, @"-nostdin", @"-hide_banner", @"-loglevel", @"error",
        // FaceLab's native endpoint is FFmpeg HTTP listen mode and returns a
        // fragmented MP4 stream, not a seekable file.  Seeking with
        // -stream_loop closes that live socket (WinError 10054 on the PC).
        // A10 has two fast cores; one FFmpeg thread was the main decoder
        // bottleneck and made the in-app preview visibly stutter.
        @"-threads", @"2", @"-rw_timeout", @"30000000",
        // FaceLab serves fragmented MP4 (moof/mdat). `nobuffer` can leave
        // the iOS demuxer waiting forever for the first fragment.
        @"-probesize", @"1M", @"-analyzeduration", @"500000", @"-fflags", @"+genpts",
        nil];
    if (isRTSP) [argumentStrings addObjectsFromArray:@[@"-rtsp_transport", @"tcp"]];
    [argumentStrings addObjectsFromArray:@[
        @"-i", inputURL, @"-map", @"0:v:0", @"-an", @"-sn",
        // The camera hook consumes SDR JPEG/YUV buffers.  HDR metadata cannot
        // be carried through that interface; the compatible conversion above
        // is intentional and avoids a decoder crash on devices without zimg.
        @"-vf", [NSString stringWithUTF8String:filter],
        @"-color_range", @"tv", @"-colorspace", @"bt709", @"-color_primaries", @"bt709", @"-color_trc", @"bt709",
        // Replace the JPEG atomically so the preview and mediaserverd never
        // decode a partially-written frame. This is the only live-output
        // change; connection URLs, fallback stages and overlay are unchanged.
        // Slightly smaller JPEGs reduce filesystem I/O and ImageIO decode
        // time on the A10 while preserving the same FPS and frame size.
        @"-q:v", @"3", @"-f", @"image2", @"-update", @"1", @"-atomic_writing", @"1", @"-y", destination]];
    char **argv = calloc(argumentStrings.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argumentStrings.count; i++) argv[i] = (char *)argumentStrings[i].UTF8String;
    argv[argumentStrings.count] = NULL;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    NSString *logPath = [VCamSharedDirectory() stringByAppendingPathComponent:@"vcam-live-ffmpeg.log"];
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, logPath.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_TRUNC, 0666);
    pid_t pid = 0;
    int result = posix_spawn(&pid, executable, &actions, NULL, argv, environ);
    free(argv);
    posix_spawn_file_actions_destroy(&actions);
    if (result == 0) {
        self.remoteFFmpegPID = pid;
        // Mode 2 means the universally-supported path is already active.
        self.remoteFFmpegMode = 2;
        self.remoteFFmpegStartedAt = [NSDate date];
        self.sourceStatusLabel.text = @"Đang kết nối video live…";
    } else {
        self.sourceStatusLabel.text = @"Không chạy được video live";
    }
}

- (NSString *)rawFaceLabURLFromURL:(NSString *)urlString {
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    if (!components || !components.host) return nil;
    // A normal HTTP MP4 server must be retried at the exact URL supplied by
    // the user. Only FaceLab's web listener needs the special endpoint.
    if (VCamLooksLikeFaceLabHTTPURL(components))
    {
        components.path = @"/__facelab_live.mp4";
        return components.URL.absoluteString;
    }
    if ([components.path.pathExtension.lowercaseString isEqualToString:@"mp4"])
        return components.URL.absoluteString;
    if (components.path.length == 0 ||
        [components.path isEqualToString:@"/"]) {
        components.path = @"/__facelab_live.mp4";
        return components.URL.absoluteString;
    }
    return nil;
}

- (NSString *)rtspFaceLabURLFromURL:(NSString *)urlString {
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    NSString *scheme = components.scheme.lowercaseString;
    if (!components.host) return nil;
    if ([scheme isEqualToString:@"rtsp"]) return components.URL.absoluteString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    if (!VCamLooksLikeFaceLabHTTPURL(components) &&
        [components.path.pathExtension.lowercaseString isEqualToString:@"mp4"]) return nil;
    return [NSString stringWithFormat:@"rtsp://%@:%ld/facelab", components.host, (long)8554];
}

- (NSString *)hlsFaceLabURLFromURL:(NSString *)urlString {
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    NSString *scheme = components.scheme.lowercaseString;
    if (!components.host) return nil;
    // Accept a MediaMTX HLS URL verbatim. This is important when the user
    // pastes /facelab/index.m3u8 instead of the FaceLab web page URL.
    if (([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
        [components.path.pathExtension.lowercaseString isEqualToString:@"m3u8"]) {
        return components.URL.absoluteString;
    }
    if ([scheme isEqualToString:@"rtsp"]) {
        return [NSString stringWithFormat:@"http://%@:%ld/facelab/index.m3u8", components.host, (long)8888];
    }
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    if (!VCamLooksLikeFaceLabHTTPURL(components) &&
        [components.path.pathExtension.lowercaseString isEqualToString:@"mp4"]) return nil;
    return [NSString stringWithFormat:@"http://%@:%ld/facelab/index.m3u8", components.host, (long)8888];
}

- (void)monitorRemoteVideoAtURL:(NSString *)urlString {
    if (urlString.length == 0) return;
    if (self.remoteFFmpegPID > 0) {
        int status = 0;
        if (waitpid(self.remoteFFmpegPID, &status, WNOHANG) == self.remoteFFmpegPID) {
            self.remoteFFmpegPID = 0;
            self.remoteFFmpegStartedAt = nil;
            // FaceLab recreates its HTTP listener when a viewer disconnects.
            // Return to mode 0 so the next poll reconnects automatically
            // instead of permanently disabling the live source.
            self.remoteFFmpegMode = 0;
            if (self.remoteFallbackStage == 1) {
                NSString *hlsURL = [self hlsFaceLabURLFromURL:urlString];
                if (hlsURL.length > 0) {
                    self.remoteFFmpegInputURL = hlsURL;
                    self.remoteFallbackStage = 0;
                    self.sourceStatusLabel.text = @"Đang kết nối MediaMTX HLS…";
                }
            } else if (self.remoteFallbackStage == 0) {
                NSString *rawURL = [self rawFaceLabURLFromURL:urlString];
                if (rawURL.length > 0) {
                    self.remoteFFmpegInputURL = rawURL;
                    self.remoteFallbackStage = 2;
                }
            }
            self.sourceStatusLabel.text = @"Đang kết nối lại video live…";
            return;
        }
    }
    if (self.remoteFFmpegPID <= 0 && self.remoteFFmpegMode == 0) {
        [self startRemoteFFmpegAtURL:urlString useToneMap:YES];
    }

    NSString *destination = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:destination error:nil];
    NSDate *modified = attributes[NSFileModificationDate];
    if (!modified || [modified isEqualToDate:self.lastRemoteVideoModification]) {
        if (self.remoteFFmpegPID > 0 && self.remoteFFmpegStartedAt &&
            -self.remoteFFmpegStartedAt.timeIntervalSinceNow > 15.0 && !self.lastRemoteVideoModification) {
            // A decoder that produced no frame is stuck or incompatible.
            kill(self.remoteFFmpegPID, SIGTERM);
            waitpid(self.remoteFFmpegPID, NULL, WNOHANG);
            self.remoteFFmpegPID = 0;
            self.remoteFFmpegMode = 0;
            if (self.remoteFallbackStage == 1) {
                NSString *hlsURL = [self hlsFaceLabURLFromURL:urlString];
                if (hlsURL.length > 0) {
                    self.remoteFFmpegInputURL = hlsURL;
                    self.remoteFallbackStage = 0;
                }
            } else if (self.remoteFallbackStage == 0) {
                NSString *rawURL = [self rawFaceLabURLFromURL:urlString];
                if (rawURL.length > 0) {
                    self.remoteFFmpegInputURL = rawURL;
                    self.remoteFallbackStage = 2;
                }
            }
            self.sourceStatusLabel.text = @"Đang thử lại video live…";
        }
        return;
    }
    // Decoding verifies FFmpeg has completed this JPEG before the camera daemon reloads it.
    if (![UIImage imageWithContentsOfFile:destination]) return;
    self.lastRemoteVideoModification = modified;
    [[NSFileManager defaultManager] setAttributes:@{
        NSFilePosixPermissions: @0666, NSFileProtectionKey: NSFileProtectionNone
    } ofItemAtPath:destination error:nil];
    NSDictionary *preferences = [self mainPreferences];
    if (![preferences[@"mediaPath"] isEqualToString:destination]) {
        NSMutableDictionary *updated = [preferences mutableCopy];
        updated[@"enabled"] = @YES;
        updated[@"mediaPath"] = destination;
        [self writeMainPreferences:updated];
    }
    self.sourceStatusLabel.text = @"Video live: đang nhận hình";
}

- (UIButton *)smallButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:25.0];
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    button.layer.cornerRadius = 10.0;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)wideButton:(NSString *)title action:(SEL)action {
    UIButton *button = [self smallButton:title action:action];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:22.0];
    return button;
}

- (UILabel *)panelLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    return label;
}

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if ([self.view.window isKindOfClass:[VCamPassThroughWindow class]]) {
        VCamPassThroughWindow *window = (VCamPassThroughWindow *)self.view.window;
        window.vcamAllowBecomeKey = YES;
        [window makeKeyWindow];
    }
    [super presentViewController:viewControllerToPresent animated:flag completion:completion];
}

- (void)dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    [super dismissViewControllerAnimated:flag completion:^{
        if (completion) completion();
        if ([self.view.window isKindOfClass:[VCamPassThroughWindow class]]) {
            VCamPassThroughWindow *window = (VCamPassThroughWindow *)self.view.window;
            window.vcamAllowBecomeKey = NO;
            [window vcamResignKeyIfNeeded];
        }
    }];
}

- (void)togglePanel {
    if (self.floatingButtonDidDrag) {
        self.floatingButtonDidDrag = NO;
        if ([self.view.window isKindOfClass:[VCamPassThroughWindow class]]) {
            [(VCamPassThroughWindow *)self.view.window vcamResignKeyIfNeeded];
        }
        return;
    }
    self.panel.hidden = !self.panel.hidden;
    [self.view bringSubviewToFront:self.floatingButton];
    if ([self.view.window isKindOfClass:[VCamPassThroughWindow class]]) {
        [(VCamPassThroughWindow *)self.view.window vcamResignKeyIfNeeded];
    }
}

- (void)dragButton:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];
    if (gesture.state == UIGestureRecognizerStateBegan ||
        gesture.state == UIGestureRecognizerStateChanged) {
        self.floatingButtonDidDrag = YES;
    }
    CGPoint center = self.floatingButton.center;
    center.x += translation.x;
    center.y += translation.y;
    CGFloat radius = CGRectGetWidth(self.floatingButton.bounds) / 2.0;
    center.x = MAX(radius + 6.0, MIN(CGRectGetWidth(self.view.bounds) - radius - 6.0, center.x));
    center.y = MAX(radius + 30.0, MIN(CGRectGetHeight(self.view.bounds) - radius - 24.0, center.y));
    self.floatingButton.center = center;
    [gesture setTranslation:CGPointZero inView:self.view];
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        if ([self.view.window isKindOfClass:[VCamPassThroughWindow class]]) {
            [(VCamPassThroughWindow *)self.view.window vcamResignKeyIfNeeded];
        }
    }
}

- (NSMutableDictionary *)preferences {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:VCamAdjustmentsFile()];
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)save:(NSMutableDictionary *)preferences {
    [preferences writeToFile:VCamAdjustmentsFile() atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0666}
        ofItemAtPath:VCamAdjustmentsFile() error:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)VCamOverlayNotification, NULL, NULL, YES);
}

- (void)adjust:(NSString *)key delta:(CGFloat)delta minimum:(CGFloat)minimum maximum:(CGFloat)maximum {
    NSMutableDictionary *preferences = [self preferences];
    CGFloat value = [preferences[key] doubleValue];
    if (![preferences[key] isKindOfClass:[NSNumber class]] && [key isEqualToString:@"zoom"]) value = 1.0;
    preferences[key] = @(MAX(minimum, MIN(maximum, value + delta)));
    [self save:preferences];
}

- (void)moveLeft { [self adjust:@"offsetX" delta:-0.04 minimum:-1.0 maximum:1.0]; }
- (void)moveRight { [self adjust:@"offsetX" delta:0.04 minimum:-1.0 maximum:1.0]; }
- (void)moveUp { [self adjust:@"offsetY" delta:0.04 minimum:-1.0 maximum:1.0]; }
- (void)moveDown { [self adjust:@"offsetY" delta:-0.04 minimum:-1.0 maximum:1.0]; }
- (void)zoomIn { [self adjust:@"zoom" delta:0.1 minimum:0.5 maximum:3.0]; }
- (void)zoomOut { [self adjust:@"zoom" delta:-0.1 minimum:0.5 maximum:3.0]; }
- (void)brighten { [self adjust:@"brightness" delta:0.08 minimum:-1.0 maximum:1.0]; }
- (void)darken { [self adjust:@"brightness" delta:-0.08 minimum:-1.0 maximum:1.0]; }
- (void)rotateBy:(CGFloat)degrees {
    NSMutableDictionary *preferences = [self preferences];
    CGFloat rotation = [preferences[@"rotation"] doubleValue] + degrees;
    while (rotation >= 360.0) rotation -= 360.0;
    while (rotation < 0.0) rotation += 360.0;
    preferences[@"rotation"] = @(rotation);
    [self save:preferences];
}
- (void)rotateLeft { [self rotateBy:-15.0]; }
- (void)rotateRight { [self rotateBy:15.0]; }
- (void)toggleBoolean:(NSString *)key {
    NSMutableDictionary *preferences = [self preferences];
    preferences[key] = @(![preferences[key] boolValue]);
    [self save:preferences];
}
- (void)flipHorizontal { [self toggleBoolean:@"flipHorizontal"]; }
- (void)flipVertical { [self toggleBoolean:@"flipVertical"]; }
- (void)resetAdjustments {
    NSMutableDictionary *preferences = [self preferences];
    preferences[@"offsetX"] = @0.0;
    preferences[@"offsetY"] = @0.0;
    preferences[@"zoom"] = @1.0;
    preferences[@"brightness"] = @0.0;
    preferences[@"rotation"] = @0.0;
    preferences[@"flipHorizontal"] = @NO;
    preferences[@"flipVertical"] = @NO;
    [self save:preferences];
}

@end

static VCamPassThroughWindow *vcamOverlayWindow = nil;

static void VCamShowOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!vcamOverlayWindow) {
            UIWindowScene *windowScene = nil;
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    windowScene = (UIWindowScene *)scene;
                    if (scene.activationState == UISceneActivationStateForegroundActive) break;
                }
            }
            if (windowScene) {
                vcamOverlayWindow = [[VCamPassThroughWindow alloc] initWithWindowScene:windowScene];
                vcamOverlayWindow.frame = windowScene.coordinateSpace.bounds;
            } else {
                vcamOverlayWindow = [[VCamPassThroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            }
            vcamOverlayWindow.rootViewController = [[VCamOverlayController alloc] init];
            vcamOverlayWindow.windowLevel = UIWindowLevelAlert + 100.0;
            vcamOverlayWindow.backgroundColor = [UIColor clearColor];
            vcamOverlayWindow.opaque = NO;
        }
        vcamOverlayWindow.hidden = NO;
    });
}

__attribute__((constructor))
static void VCamOverlayInitialize(void) {
    @autoreleasepool {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            VCamPreferencesDidChange, (__bridge CFStringRef)VCamPreferencesNotification,
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        VCamShowOverlay();
    }
}
