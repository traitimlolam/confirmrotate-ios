#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <sys/utsname.h>

// Forward declarations
@interface SBOrientationLockManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUserLocked;
- (BOOL)isLocked;
- (void)lock;
- (void)unlock;
- (void)lock:(long long)orientation;
@end

@interface SpringBoard : UIApplication
- (UIInterfaceOrientation)activeInterfaceOrientation;
- (UIInterfaceOrientation)_frontMostAppOrientation;
- (void)setWantsOrientationEvents:(BOOL)wants;
- (void)updateOrientationDetectionSettings;
@end

// Pass-through transparent view
@interface CRPassThroughView : UIView
@property (nonatomic, weak) UIView *interactiveButton;
@end

@implementation CRPassThroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.interactiveButton && !self.interactiveButton.hidden && self.interactiveButton.alpha > 0.05) {
        CGPoint p = [self convertPoint:point toView:self.interactiveButton];
        if ([self.interactiveButton pointInside:p withEvent:event]) {
            return [self.interactiveButton hitTest:p withEvent:event];
        }
    }
    return nil;
}
@end

// Floating Rotation Overlay Controller
@interface CRRotateManager : NSObject
+ (instancetype)sharedInstance;
- (void)handleDeviceOrientationChanged;
@end

@implementation CRRotateManager {
    UIWindow *_overlayWindow;
    UIButton *_rotateButton;
    NSTimer *_dismissTimer;
    UIInterfaceOrientation _pendingTargetOrientation;
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
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScreen *screen = [UIScreen mainScreen];
        self->_overlayWindow = [[UIWindow alloc] initWithFrame:screen.bounds];
        self->_overlayWindow.windowLevel = UIWindowLevelAlert + 100.0;
        self->_overlayWindow.backgroundColor = [UIColor clearColor];
        self->_overlayWindow.userInteractionEnabled = YES;

        UIViewController *rootVC = [[UIViewController alloc] init];
        CRPassThroughView *passView = [[CRPassThroughView alloc] initWithFrame:screen.bounds];
        passView.backgroundColor = [UIColor clearColor];
        rootVC.view = passView;
        self->_overlayWindow.rootViewController = rootVC;

        // Circular 48x48 floating button
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, 0, 48, 48);
        btn.layer.cornerRadius = 24.0;
        btn.layer.masksToBounds = NO;
        btn.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.85];
        btn.layer.borderWidth = 1.0;
        btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;

        // Shadow
        btn.layer.shadowColor = [UIColor blackColor].CGColor;
        btn.layer.shadowOpacity = 0.4;
        btn.layer.shadowRadius = 8.0;
        btn.layer.shadowOffset = CGSizeMake(0, 3);

        // Icon
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
        UIImage *icon = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath" withConfiguration:config];
        [btn setImage:icon forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];

        [btn addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
        btn.alpha = 0.0;
        btn.hidden = YES;

        [passView addSubview:btn];
        passView.interactiveButton = btn;
        self->_rotateButton = btn;

        self->_overlayWindow.hidden = NO;
    });
}

static UIInterfaceOrientation targetInterfaceOrientationForDeviceOrientation(UIDeviceOrientation devOri) {
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

- (void)handleDeviceOrientationChanged {
    UIDeviceOrientation devOri = [[UIDevice currentDevice] orientation];
    if (devOri == UIDeviceOrientationFaceUp || devOri == UIDeviceOrientationFaceDown || devOri == UIDeviceOrientationUnknown) {
        return;
    }

    UIInterfaceOrientation targetOri = targetInterfaceOrientationForDeviceOrientation(devOri);
    if (targetOri == UIInterfaceOrientationUnknown) {
        return;
    }

    SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
    UIInterfaceOrientation currentOri = UIInterfaceOrientationPortrait;
    if ([sb respondsToSelector:@selector(activeInterfaceOrientation)]) {
        currentOri = [sb activeInterfaceOrientation];
    } else if ([sb respondsToSelector:@selector(_frontMostAppOrientation)]) {
        currentOri = [sb _frontMostAppOrientation];
    }

    if (targetOri == currentOri) {
        [self dismissButtonAnimated:YES];
        return;
    }

    // Only prompt when rotation lock is enabled (or orientation differs)
    Class lockClass = NSClassFromString(@"SBOrientationLockManager");
    if (!lockClass) return;
    
    id lockMan = [lockClass performSelector:@selector(sharedInstance)];
    BOOL isLocked = (lockMan && [lockMan respondsToSelector:@selector(isUserLocked)] && [lockMan isUserLocked]);

    if (!isLocked) {
        return;
    }

    self->_pendingTargetOrientation = targetOri;
    [self showButtonAtCorner];
}

- (void)showButtonAtCorner {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_dismissTimer invalidate];

        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGFloat btnSize = 48.0;
        CGFloat marginX = 22.0;
        CGFloat marginY = 55.0; // Above home indicator / bottom bar

        CGRect targetFrame = CGRectMake(screenBounds.size.width - btnSize - marginX,
                                        screenBounds.size.height - btnSize - marginY,
                                        btnSize,
                                        btnSize);

        self->_rotateButton.frame = targetFrame;
        self->_rotateButton.hidden = NO;
        self->_rotateButton.transform = CGAffineTransformMakeScale(0.3, 0.3);

        // Haptic feedback
        AudioServicesPlaySystemSound(1519); // Subtle peek vibration

        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.6 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self->_rotateButton.alpha = 1.0;
            self->_rotateButton.transform = CGAffineTransformIdentity;
        } completion:nil];

        // Auto dismiss after 3 seconds
        self->_dismissTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
            [self dismissButtonAnimated:YES];
        }];
    });
}

- (void)buttonTapped {
    [self->_dismissTimer invalidate];

    // Crisp click haptic
    AudioServicesPlaySystemSound(1520);

    // Pop animation
    [UIView animateWithDuration:0.2 animations:^{
        self->_rotateButton.transform = CGAffineTransformMakeScale(1.15, 1.15);
        self->_rotateButton.alpha = 0.0;
    } completion:^(BOOL finished) {
        self->_rotateButton.hidden = YES;
        self->_rotateButton.transform = CGAffineTransformIdentity;
    }];

    // Perform rotation
    UIInterfaceOrientation target = self->_pendingTargetOrientation;
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
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:lockMan];
                [inv setSelector:@selector(lock:)];
                long long oriVal = (long long)target;
                [inv setArgument:&oriVal atIndex:2];
                [inv invoke];
            }
            SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
            if ([sb respondsToSelector:@selector(updateOrientationDetectionSettings)]) {
                [sb updateOrientationDetectionSettings];
            }
        }
    }
}

- (void)dismissButtonAnimated:(BOOL)animated {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_rotateButton.hidden || self->_rotateButton.alpha < 0.05) return;

        if (animated) {
            [UIView animateWithDuration:0.25 animations:^{
                self->_rotateButton.alpha = 0.0;
                self->_rotateButton.transform = CGAffineTransformMakeScale(0.5, 0.5);
            } completion:^(BOOL finished) {
                self->_rotateButton.hidden = YES;
                self->_rotateButton.transform = CGAffineTransformIdentity;
            }];
        } else {
            self->_rotateButton.hidden = YES;
            self->_rotateButton.alpha = 0.0;
            self->_rotateButton.transform = CGAffineTransformIdentity;
        }
    });
}

@end

// Hooks
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    // Start orientation monitoring
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [self setWantsOrientationEvents:YES];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        [[CRRotateManager sharedInstance] handleDeviceOrientationChanged];
    }];
}

%end

%ctor {
    // Hardware check: Only Owner's devices (iPhone 13 Pro Max - iPhone14,3 / iPhone 13 mini - iPhone14,4)
    struct utsname systemInfo;
    uname(&systemInfo);
    if (strcmp(systemInfo.machine, "iPhone14,3") != 0 && strcmp(systemInfo.machine, "iPhone14,4") != 0) {
        NSLog(@"[ConfirmRotate] Device %@ not authorized. Exiting.", [NSString stringWithUTF8String:systemInfo.machine]);
        return;
    }

    %init;
}
