#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <sys/utsname.h>
#import <math.h>

@interface SBOrientationLockManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUserLocked;
- (BOOL)isLocked;
- (void)lock;
- (void)unlock;
- (void)lock:(long long)orientation;
@end

@interface SBDeviceOrientationUpdateManager : NSObject
- (void)_enqueueOrientationUpdateToDeviceOrientation:(long long)orientation;
@end

@interface UIApplication (SpringBoardOrientation)
- (void)_overrideDefaultInterfaceOrientationWithOrientation:(long long)orientation;
@end

@interface CRTouchWindow : UIWindow
@end

@implementation CRTouchWindow
- (BOOL)_canBecomeKeyWindow {
    return NO;
}
- (BOOL)_shouldCreateScreenPresentationContext {
    return NO;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}
@end

static UIWindowScene *getMainSpringBoardScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.screen == [UIScreen mainScreen]) {
                return ws;
            }
        }
    }
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

@interface CRRotateManager : NSObject
+ (instancetype)sharedInstance;
- (void)startMonitoring;
- (void)deviceOrientationChangedTo:(long long)deviceOri;
- (void)showCapsulePromptWithTargetOrientation:(UIInterfaceOrientation)targetOri;
- (void)dismissCapsuleAnimated:(BOOL)animated;
@end

@implementation CRRotateManager {
    CMMotionManager *_motionManager;
    CRTouchWindow *_touchWindow;
    UIView *_capsuleContainer;
    UIImageView *_iconView;
    UILabel *_labelView;
    NSTimer *_dismissTimer;
    UIInterfaceOrientation _pendingOrientation;
    long long _lastProcessedOrientation;
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
        _lastProcessedOrientation = 0;
    }
    return self;
}

- (CRTouchWindow *)getOrCreateTouchWindow {
    if (!_touchWindow) {
        UIWindowScene *scene = getMainSpringBoardScene();
        if (scene) {
            _touchWindow = [[CRTouchWindow alloc] initWithWindowScene:scene];
        } else {
            _touchWindow = [[CRTouchWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        _touchWindow.windowLevel = UIWindowLevelStatusBar + 10000.0;
        _touchWindow.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        _touchWindow.rootViewController = vc;
        _touchWindow.hidden = NO;
    }
    return _touchWindow;
}

- (UIView *)getOrCreateCapsuleView {
    if (!_capsuleContainer) {
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 116, 48)];
        container.layer.cornerRadius = 24.0;
        container.layer.masksToBounds = NO;
        container.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.92];
        container.layer.borderWidth = 1.0;
        container.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;

        // Drop Shadow
        container.layer.shadowColor = [UIColor blackColor].CGColor;
        container.layer.shadowOpacity = 0.65;
        container.layer.shadowRadius = 10.0;
        container.layer.shadowOffset = CGSizeMake(0, 4);

        // Icon
        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(11, 10, 28, 28)];
        icon.contentMode = UIViewContentModeScaleAspectFit;

        NSString *imgPath = @"/Library/Application Support/ConfirmRotate/ConfirmRotateBundle.bundle/rotate.png";
        UIImage *img = [UIImage imageWithContentsOfFile:imgPath];
        if (!img) {
            static NSString *const b64Str = @"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";
            NSData *data = [[NSData alloc] initWithBase64EncodedString:b64Str options:0];
            if (data) {
                img = [UIImage imageWithData:data];
            }
        }
        if (!img) {
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
            img = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath" withConfiguration:config];
            icon.tintColor = [UIColor whiteColor];
        }
        icon.image = img;
        [container addSubview:icon];
        self->_iconView = icon;

        // Label: "Rotate?"
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(45, 12, 62, 24)];
        label.text = @"Rotate?";
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont fontWithName:@"Helvetica-Bold" size:15.0];
        if (!label.font) {
            label.font = [UIFont boldSystemFontOfSize:15.0];
        }
        [container addSubview:label];
        self->_labelView = label;

        // Tap Gesture
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleCapsuleTapped)];
        tap.cancelsTouchesInView = YES;
        [container addGestureRecognizer:tap];
        container.userInteractionEnabled = YES;

        self->_capsuleContainer = container;
    }
    return _capsuleContainer;
}

- (void)startMonitoring {
    if (_motionManager) return;

    _motionManager = [[CMMotionManager alloc] init];
    if (_motionManager.isAccelerometerAvailable) {
        _motionManager.accelerometerUpdateInterval = 0.25;
        [_motionManager startAccelerometerUpdatesToQueue:[NSOperationQueue mainQueue]
                                             withHandler:^(CMAccelerometerData * _Nullable data, NSError * _Nullable error) {
            if (data) {
                double x = data.acceleration.x;
                double y = data.acceleration.y;
                double z = data.acceleration.z;
                if (fabs(z) >= 0.90) return;

                double angle = atan2(x, -y) * 180.0 / M_PI;
                long long ori = 0;
                if (angle >= -45.0 && angle <= 45.0) {
                    ori = 1; // Portrait
                } else if (angle > 45.0 && angle <= 135.0) {
                    ori = 3; // Landscape Right
                } else if (angle >= -135.0 && angle < -45.0) {
                    ori = 4; // Landscape Left
                }

                if (ori != 0) {
                    [self deviceOrientationChangedTo:ori];
                }
            }
        }];
    }
}

- (void)deviceOrientationChangedTo:(long long)deviceOri {
    if (deviceOri <= 0 || deviceOri > 4) return;
    if (deviceOri == _lastProcessedOrientation) return;
    _lastProcessedOrientation = deviceOri;

    UIInterfaceOrientation targetOri = UIInterfaceOrientationUnknown;
    if (deviceOri == 1) {
        targetOri = UIInterfaceOrientationPortrait;
    } else if (deviceOri == 3) {
        targetOri = UIInterfaceOrientationLandscapeLeft;
    } else if (deviceOri == 4) {
        targetOri = UIInterfaceOrientationLandscapeRight;
    } else if (deviceOri == 2) {
        targetOri = UIInterfaceOrientationPortrait;
    }

    if (targetOri == UIInterfaceOrientationUnknown) return;

    UIInterfaceOrientation currentOri = UIInterfaceOrientationPortrait;
    UIWindowScene *scene = getMainSpringBoardScene();
    if (scene) {
        currentOri = scene.interfaceOrientation;
    }

    if (targetOri == currentOri) {
        [self dismissCapsuleAnimated:YES];
        return;
    }

    [self showCapsulePromptWithTargetOrientation:targetOri];
}

- (void)showCapsulePromptWithTargetOrientation:(UIInterfaceOrientation)targetOri {
    _pendingOrientation = targetOri;
    [_dismissTimer invalidate];

    CRTouchWindow *win = [self getOrCreateTouchWindow];
    UIView *capsule = [self getOrCreateCapsuleView];

    if (capsule.superview != win.rootViewController.view) {
        [capsule removeFromSuperview];
        [win.rootViewController.view addSubview:capsule];
    }
    [win.rootViewController.view bringSubviewToFront:capsule];

    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat width = 116.0;
    CGFloat height = 48.0;
    CGFloat marginX = 16.0;
    CGFloat posY = (bounds.size.height / 2.0) - (height / 2.0);

    capsule.frame = CGRectMake(bounds.size.width - width - marginX,
                               posY,
                               width,
                               height);

    capsule.alpha = 0.0;
    capsule.transform = CGAffineTransformMakeScale(0.4, 0.4);
    self->_isShowing = YES;

    // Peek vibration
    AudioServicesPlaySystemSound(1519);

    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.7 options:UIViewAnimationOptionCurveEaseOut animations:^{
        capsule.alpha = 1.0;
        capsule.transform = CGAffineTransformIdentity;
    } completion:nil];

    // Auto dismiss after 3.5s
    self->_dismissTimer = [NSTimer scheduledTimerWithTimeInterval:3.5 repeats:NO block:^(NSTimer * _Nonnull timer) {
        [self dismissCapsuleAnimated:YES];
    }];
}

- (void)handleCapsuleTapped {
    [_dismissTimer invalidate];

    // Tap haptic
    AudioServicesPlaySystemSound(1520);

    UIView *capsule = self->_capsuleContainer;
    [UIView animateWithDuration:0.2 animations:^{
        capsule.transform = CGAffineTransformMakeScale(1.15, 1.15);
        capsule.alpha = 0.0;
    } completion:^(BOOL finished) {
        [capsule removeFromSuperview];
        capsule.transform = CGAffineTransformIdentity;
        self->_isShowing = NO;
    }];

    UIInterfaceOrientation target = _pendingOrientation;
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

    UIApplication *app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(_overrideDefaultInterfaceOrientationWithOrientation:)]) {
        NSMethodSignature *sig = [app methodSignatureForSelector:@selector(_overrideDefaultInterfaceOrientationWithOrientation:)];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:app];
            [inv setSelector:@selector(_overrideDefaultInterfaceOrientationWithOrientation:)];
            long long val = (long long)target;
            [inv setArgument:&val atIndex:2];
            [inv invoke];
        }
    }
}

- (void)dismissCapsuleAnimated:(BOOL)animated {
    if (!self->_isShowing || !self->_capsuleContainer || !self->_capsuleContainer.superview) return;

    UIView *capsule = self->_capsuleContainer;
    self->_isShowing = NO;

    if (animated) {
        [UIView animateWithDuration:0.25 animations:^{
            capsule.alpha = 0.0;
            capsule.transform = CGAffineTransformMakeScale(0.4, 0.4);
        } completion:^(BOOL finished) {
            [capsule removeFromSuperview];
            capsule.transform = CGAffineTransformIdentity;
        }];
    } else {
        [capsule removeFromSuperview];
        capsule.alpha = 0.0;
        capsule.transform = CGAffineTransformIdentity;
    }
}

@end

%hook SBDeviceOrientationUpdateManager
- (void)_enqueueOrientationUpdateToDeviceOrientation:(long long)orientation {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[CRRotateManager sharedInstance] deviceOrientationChangedTo:orientation];
    });
}
%end

%ctor {
    struct utsname systemInfo;
    uname(&systemInfo);
    if (strcmp(systemInfo.machine, "iPhone14,3") != 0 && strcmp(systemInfo.machine, "iPhone14,4") != 0) {
        NSLog(@"[ConfirmRotate] Device %@ not authorized.", [NSString stringWithUTF8String:systemInfo.machine]);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[CRRotateManager sharedInstance] startMonitoring];
    });
}
