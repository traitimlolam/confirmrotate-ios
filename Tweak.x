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

static UIWindow *getTopSpringBoardWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows.reverseObjectEnumerator) {
                if (!w.hidden && w.alpha > 0.1 && w.userInteractionEnabled) {
                    return w;
                }
            }
        }
    }
    if (app.windows.count > 0) {
        for (UIWindow *w in app.windows.reverseObjectEnumerator) {
            if (!w.hidden && w.alpha > 0.1) {
                return w;
            }
        }
    }
    return nil;
}

@interface CRRotateManager : NSObject
+ (instancetype)sharedInstance;
- (void)startMonitoring;
- (void)handleAccelerometerData:(CMAccelerometerData *)data;
@end

@implementation CRRotateManager {
    CMMotionManager *_motionManager;
    UIView *_capsuleContainer;
    UIImageView *_iconView;
    UILabel *_labelView;
    NSTimer *_dismissTimer;
    UIInterfaceOrientation _pendingOrientation;
    UIInterfaceOrientation _lastDetectedOrientation;
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
        _lastDetectedOrientation = UIInterfaceOrientationPortrait;
    }
    return self;
}

- (UIView *)getOrCreateCapsuleView {
    if (!_capsuleContainer) {
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 112, 48)];
        container.layer.cornerRadius = 24.0;
        container.layer.masksToBounds = NO;
        container.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.92];
        container.layer.borderWidth = 1.0;
        container.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;

        // Shadow
        container.layer.shadowColor = [UIColor blackColor].CGColor;
        container.layer.shadowOpacity = 0.55;
        container.layer.shadowRadius = 10.0;
        container.layer.shadowOffset = CGSizeMake(0, 4);

        // Icon (rotate.png from authentic bundle)
        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(10, 9, 30, 30)];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        NSString *imgPath = @"/Library/Application Support/ConfirmRotate/ConfirmRotateBundle.bundle/rotate.png";
        UIImage *img = [UIImage imageWithContentsOfFile:imgPath];
        if (!img) {
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
            img = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath" withConfiguration:config];
            icon.tintColor = [UIColor whiteColor];
        }
        icon.image = img;
        [container addSubview:icon];
        self->_iconView = icon;

        // Label: "Rotate?"
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(44, 12, 58, 24)];
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
        _motionManager.accelerometerUpdateInterval = 0.20; // 5 times/sec
        [_motionManager startAccelerometerUpdatesToQueue:[NSOperationQueue mainQueue]
                                             withHandler:^(CMAccelerometerData * _Nullable data, NSError * _Nullable error) {
            if (data) {
                [self handleAccelerometerData:data];
            }
        }];
    }
}

- (void)handleAccelerometerData:(CMAccelerometerData *)data {
    double x = data.acceleration.x;
    double y = data.acceleration.y;
    double z = data.acceleration.z;

    // Ignore when flat on surface
    if (fabs(z) >= 0.90) {
        return;
    }

    // Standard orientation angle: atan2(x, -y) in degrees (-180 to 180)
    double angle = atan2(x, -y) * 180.0 / M_PI;

    UIInterfaceOrientation physicalOri = UIInterfaceOrientationUnknown;
    if (angle >= -45.0 && angle <= 45.0) {
        physicalOri = UIInterfaceOrientationPortrait;
    } else if (angle > 45.0 && angle <= 135.0) {
        // Tilted left (top to left) -> target landscape right
        physicalOri = UIInterfaceOrientationLandscapeRight;
    } else if (angle >= -135.0 && angle < -45.0) {
        // Tilted right (top to right) -> target landscape left
        physicalOri = UIInterfaceOrientationLandscapeLeft;
    }

    if (physicalOri == UIInterfaceOrientationUnknown) {
        return;
    }

    if (physicalOri == _lastDetectedOrientation) {
        return;
    }

    _lastDetectedOrientation = physicalOri;

    // Get current screen orientation
    UIWindow *topWindow = getTopSpringBoardWindow();
    UIInterfaceOrientation currentOri = UIInterfaceOrientationPortrait;
    if (topWindow && topWindow.windowScene) {
        currentOri = topWindow.windowScene.interfaceOrientation;
    }

    if (physicalOri == currentOri) {
        [self dismissCapsuleAnimated:YES];
        return;
    }

    self->_pendingOrientation = physicalOri;
    [self showCapsulePrompt];
}

- (void)showCapsulePrompt {
    [self->_dismissTimer invalidate];

    UIWindow *topWindow = getTopSpringBoardWindow();
    if (!topWindow) return;

    UIView *capsule = [self getOrCreateCapsuleView];
    if (capsule.superview != topWindow) {
        [capsule removeFromSuperview];
        [topWindow addSubview:capsule];
    }
    [topWindow bringSubviewToFront:capsule];

    CGRect bounds = topWindow.bounds;
    CGFloat width = 112.0;
    CGFloat height = 48.0;
    CGFloat marginX = 18.0;
    CGFloat posY = bounds.size.height * 0.55;

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
    [self->_dismissTimer invalidate];

    // Click haptic
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

- (void)dismissCapsuleAnimated:(BOOL)animated {
    if (!self->_isShowing || !self->_capsuleContainer || !self->_capsuleContainer.superview) return;

    UIView *capsule = self->_capsuleContainer;
    self->_isShowing = NO;

    if (animated) {
        [UIView animateWithDuration:0.25 animations:^{
            capsule.alpha = 0.0;
            capsule.transform = CGAffineTransformMakeScale(0.5, 0.5);
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

%ctor {
    struct utsname systemInfo;
    uname(&systemInfo);
    if (strcmp(systemInfo.machine, "iPhone14,3") != 0 && strcmp(systemInfo.machine, "iPhone14,4") != 0) {
        NSLog(@"[ConfirmRotate] Device %@ not authorized.", [NSString stringWithUTF8String:systemInfo.machine]);
        return;
    }

    // Start monitoring automatically after 1.5s
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[CRRotateManager sharedInstance] startMonitoring];
    });
}
