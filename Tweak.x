#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMotion/CoreMotion.h>
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
    return nil;
}

@interface CRRotateManager : NSObject
+ (instancetype)sharedInstance;
- (void)startMonitoring;
- (void)handleMotionData:(CMAccelerometerData *)data;
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
        // Original ConfirmRotate Capsule Button: 110x46pt
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 110, 46)];
        container.layer.cornerRadius = 23.0;
        container.layer.masksToBounds = NO;
        container.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.90];
        container.layer.borderWidth = 1.0;
        container.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;

        // Subtle drop shadow
        container.layer.shadowColor = [UIColor blackColor].CGColor;
        container.layer.shadowOpacity = 0.5;
        container.layer.shadowRadius = 8.0;
        container.layer.shadowOffset = CGSizeMake(0, 3);

        // Icon (rotate.png from authentic ConfirmRotate bundle)
        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(10, 8, 30, 30)];
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

        // Label: "Rotate?" (authentic Helvetica-Bold font)
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(44, 11, 56, 24)];
        label.text = @"Rotate?";
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont fontWithName:@"Helvetica-Bold" size:14.5];
        if (!label.font) {
            label.font = [UIFont boldSystemFontOfSize:14.5];
        }
        [container addSubview:label];
        self->_labelView = label;

        // Tap gesture recognizer
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleCapsuleTapped)];
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
        _motionManager.accelerometerUpdateInterval = 0.25; // 4 times per second
        [_motionManager startAccelerometerUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMAccelerometerData * _Nullable data, NSError * _Nullable error) {
            if (data) {
                [self handleMotionData:data];
            }
        }];
    }
}

- (void)handleMotionData:(CMAccelerometerData *)data {
    double x = data.acceleration.x;
    double y = data.acceleration.y;
    double z = data.acceleration.z;

    // Ignore when lying flat on table or bed
    if (fabs(z) >= 0.85) {
        return;
    }

    UIInterfaceOrientation physicalOri = UIInterfaceOrientationUnknown;
    if (y <= -0.65 && fabs(x) < 0.45) {
        physicalOri = UIInterfaceOrientationPortrait;
    } else if (x >= 0.65 && fabs(y) < 0.45) {
        physicalOri = UIInterfaceOrientationLandscapeLeft;
    } else if (x <= -0.65 && fabs(y) < 0.45) {
        physicalOri = UIInterfaceOrientationLandscapeRight;
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
    CGFloat width = 110.0;
    CGFloat height = 46.0;
    CGFloat marginX = 16.0;
    CGFloat posY = bounds.size.height * 0.58; // Middle-right, matching authentic screenshot

    capsule.frame = CGRectMake(bounds.size.width - width - marginX,
                               posY,
                               width,
                               height);

    capsule.alpha = 0.0;
    capsule.transform = CGAffineTransformMakeScale(0.4, 0.4);
    self->_isShowing = YES;

    // Subtle vibration
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

    // Zero hooks on SpringBoard! Listen after boot
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[CRRotateManager sharedInstance] startMonitoring];
        });
    }];
}
