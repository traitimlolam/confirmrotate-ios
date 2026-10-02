#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <sys/utsname.h>

@interface SBOrientationLockManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUserLocked;
- (BOOL)isLocked;
- (void)lock;
- (void)unlock;
- (void)lock:(long long)orientation;
@end

static UIInterfaceOrientation targetOrientationForDeviceOrientation(UIDeviceOrientation devOri) {
    switch (devOri) {
        case UIDeviceOrientationPortrait:
            return UIInterfaceOrientationPortrait;
        case UIDeviceOrientationPortraitUpsideDown:
            return UIInterfaceOrientationPortraitUpsideDown;
        case UIDeviceOrientationLandscapeLeft:
            return UIInterfaceOrientationLandscapeRight;
        case UIDeviceOrientationLandscapeRight:
            return UIInterfaceOrientationLandscapeLeft;
        default:
            return UIInterfaceOrientationUnknown;
    }
}

static UIWindow *getTopSpringBoardWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows.reverseObjectEnumerator) {
                if (!w.hidden && w.alpha > 0.05 && w.userInteractionEnabled) {
                    return w;
                }
            }
        }
    }
    return app.keyWindow;
}

@interface CRRotateManager : NSObject
+ (instancetype)sharedInstance;
- (void)onOrientationChanged;
@end

@implementation CRRotateManager {
    UIButton *_floatingButton;
    NSTimer *_dismissTimer;
    UIInterfaceOrientation _pendingOrientation;
    BOOL _isShowing;
}

+ (instancetype)sharedInstance {
    static CRRotateManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CRRotateManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isShowing = NO;
        _pendingOrientation = UIInterfaceOrientationUnknown;
    }
    return self;
}

- (UIButton *)getOrCreateButton {
    if (!_floatingButton) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, 0, 52, 52);
        btn.layer.cornerRadius = 26.0;
        btn.layer.masksToBounds = NO;
        btn.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.88];
        btn.layer.borderWidth = 1.0;
        btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;

        // Shadow
        btn.layer.shadowColor = [UIColor blackColor].CGColor;
        btn.layer.shadowOpacity = 0.45;
        btn.layer.shadowRadius = 8.0;
        btn.layer.shadowOffset = CGSizeMake(0, 3);

        // Icon
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
        UIImage *icon = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath" withConfiguration:config];
        [btn setImage:icon forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];

        [btn addTarget:self action:@selector(handleButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        _floatingButton = btn;
    }
    return _floatingButton;
}

- (void)onOrientationChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIDeviceOrientation devOri = [[UIDevice currentDevice] orientation];
        if (devOri == UIDeviceOrientationFaceUp || devOri == UIDeviceOrientationFaceDown || devOri == UIDeviceOrientationUnknown) {
            return;
        }

        UIInterfaceOrientation targetOri = targetOrientationForDeviceOrientation(devOri);
        if (targetOri == UIInterfaceOrientationUnknown) {
            return;
        }

        // Determine current interface orientation safely
        UIInterfaceOrientation currentOri = UIInterfaceOrientationPortrait;
        UIWindow *topWindow = getTopSpringBoardWindow();
        if (topWindow && topWindow.windowScene) {
            currentOri = topWindow.windowScene.interfaceOrientation;
        } else {
            currentOri = [UIApplication sharedApplication].statusBarOrientation;
        }

        if (targetOri == currentOri) {
            [self dismissButtonAnimated:YES];
            return;
        }

        // Only prompt when rotation lock is enabled
        Class lockClass = NSClassFromString(@"SBOrientationLockManager");
        if (lockClass) {
            id lockMan = [lockClass performSelector:@selector(sharedInstance)];
            if (lockMan && [lockMan respondsToSelector:@selector(isUserLocked)]) {
                if (![lockMan isUserLocked]) {
                    return; // Rotation lock is off, system handles auto-rotation
                }
            }
        }

        self->_pendingOrientation = targetOri;
        [self showButtonAtCorner];
    });
}

- (void)showButtonAtCorner {
    [self->_dismissTimer invalidate];

    UIWindow *topWindow = getTopSpringBoardWindow();
    if (!topWindow) return;

    UIButton *btn = [self getOrCreateButton];
    if (btn.superview != topWindow) {
        [btn removeFromSuperview];
        [topWindow addSubview:btn];
    }
    [topWindow bringSubviewToFront:btn];

    CGRect bounds = topWindow.bounds;
    CGFloat size = 52.0;
    CGFloat marginX = 24.0;
    CGFloat marginY = 60.0;

    btn.frame = CGRectMake(bounds.size.width - size - marginX,
                           bounds.size.height - size - marginY,
                           size, size);

    btn.alpha = 0.0;
    btn.transform = CGAffineTransformMakeScale(0.3, 0.3);
    self->_isShowing = YES;

    // Haptic
    AudioServicesPlaySystemSound(1519);

    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.6 options:UIViewAnimationOptionCurveEaseOut animations:^{
        btn.alpha = 1.0;
        btn.transform = CGAffineTransformIdentity;
    } completion:nil];

    // Auto dismiss after 3.0s
    self->_dismissTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        [self dismissButtonAnimated:YES];
    }];
}

- (void)handleButtonTapped {
    [self->_dismissTimer invalidate];

    // Haptic
    AudioServicesPlaySystemSound(1520);

    UIButton *btn = self->_floatingButton;
    [UIView animateWithDuration:0.2 animations:^{
        btn.transform = CGAffineTransformMakeScale(1.15, 1.15);
        btn.alpha = 0.0;
    } completion:^(BOOL finished) {
        [btn removeFromSuperview];
        btn.transform = CGAffineTransformIdentity;
        self->_isShowing = NO;
    }];

    UIInterfaceOrientation target = self->_pendingOrientation;
    if (target == UIInterfaceOrientationUnknown) return;

    Class lockClass = NSClassFromString(@"SBOrientationLockManager");
    if (lockClass) {
        id lockMan = [lockClass performSelector:@selector(sharedInstance)];
        if (lockMan) {
            if ([lockMan respondsToSelector:@selector(unlock)]) {
                [lockMan unlock];
            }
            if ([lockMan respondsToSelector:@selector(lock:)]) {
                NSMethodSignature *sig = [lockMan methodSignatureForSelector:@selector(lock:)];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:lockMan];
                    [inv setSelector:@selector(lock:)];
                    long long val = (long long)target;
                    [inv setArgument:&val atIndex:2];
                    [inv invoke];
                }
            }
        }
    }
}

- (void)dismissButtonAnimated:(BOOL)animated {
    if (!self->_isShowing || !self->_floatingButton || !self->_floatingButton.superview) return;

    UIButton *btn = self->_floatingButton;
    self->_isShowing = NO;

    if (animated) {
        [UIView animateWithDuration:0.25 animations:^{
            btn.alpha = 0.0;
            btn.transform = CGAffineTransformMakeScale(0.5, 0.5);
        } completion:^(BOOL finished) {
            [btn removeFromSuperview];
            btn.transform = CGAffineTransformIdentity;
        }];
    } else {
        [btn removeFromSuperview];
        btn.alpha = 0.0;
        btn.transform = CGAffineTransformIdentity;
    }
}

@end

%ctor {
    struct utsname systemInfo;
    uname(&systemInfo);
    if (strcmp(systemInfo.machine, "iPhone14,3") != 0 && strcmp(systemInfo.machine, "iPhone14,4") != 0) {
        NSLog(@"[ConfirmRotate] Device %@ not authorized.", [NSString stringWithUTF8String:systemInfo.machine]);
        return;
    }

    // Zero hooks on SpringBoard! Safely listen after app launch
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];

            [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *n) {
                [[CRRotateManager sharedInstance] onOrientationChanged];
            }];
        });
    }];
}
