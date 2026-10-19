/*
 * MacShim.m - AppKit stand-ins on top of UIKit, so the unmodified macOS build of Cyberpunk 2077
 * (which is a thin Cocoa shell around Metal) can run as an iPadOS app.
 *
 * Provides: NSApplication, NSWindow, NSWindowController, NSView, NSScreen, NSEvent, NSCursor,
 *           NSImage, NSMenu, NSWorkspace, NSTrackingArea (+ notification names, NSApp global)
 * Plus:     keyboard / pointer / touch -> NSEvent bridge, pointer lock + hide,
 *           dyld-interposed _NSGetExecutablePath (data folder) and sysctlbyname (Mac-like values).
 *
 * Unknown AppKit selectors are logged and answered with 0/nil instead of crashing (MSBase).
 * NOT compiled or run by the author on a device - treat as a first draft to iterate on.
 */
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <dlfcn.h>
#include <pthread.h>
#include <execinfo.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* ---------------------------------------------------------------- constants / globals */
NSString *const NSWindowDidBecomeKeyNotification   = @"NSWindowDidBecomeKeyNotification";
NSString *const NSWindowDidResignKeyNotification   = @"NSWindowDidResignKeyNotification";
NSString *const NSWindowDidResizeNotification      = @"NSWindowDidResizeNotification";
NSString *const NSWindowWillCloseNotification      = @"NSWindowWillCloseNotification";
NSString *const NSWindowWillExitFullScreenNotification = @"NSWindowWillExitFullScreenNotification";
NSString *const NSApplicationDidChangeScreenParametersNotification = @"NSApplicationDidChangeScreenParametersNotification";
NSString *const NSApplicationDidResignActiveNotification = @"NSApplicationDidResignActiveNotification";
NSString *const NSEventTrackingRunLoopMode         = @"UITrackingRunLoopMode";
NSString *const NSImageHintInterpolation           = @"NSImageHintInterpolation";
id NSApp = nil;
static void MSStartReadProgress(void);
static _Atomic long long g_noCopyN, g_noCopyBytes, g_bufTexN, g_bufTexBad;
static double MSCfgD(NSString *k, double def);
static NSString *MSQuarantineStats(void);
static NSDictionary *MSConfig(void);
static NSInteger MSPref(NSString *k, NSInteger def);
static void MSStatusCreate(void);
static void MSTouchPadCreate(UIWindowScene *sc);
static void MSTVRoute(void); static void MSTVObserve(void);
static void MSLowLatencyWait(void); static void MSInputReport(void);
/* TV out: the phone shows the picture too (TVMirror = NO: phone stays black, saves a little power) */
@class CAMetalLayer; static CAMetalLayer *g_mirrorLayer; static _Atomic BOOL g_mirrorOn;
static BOOL MSMirrorFit(UIView *v, CGRect *r);
@class NSWindow; static __weak NSWindow *g_gameWin;

static void MSLogf(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static BOOL g_cursorHidden = NO, g_pointerLocked = NO;
static CGPoint g_mouse;                                  /* Cocoa coords: origin bottom-left, points */
static NSUInteger g_modFlags = 0;

enum { MSLDown = 1, MSLUp, MSRDown, MSRUp, MSMouseMoved, MSLDrag, MSRDrag, MSEnter, MSExit, MSKeyDown, MSKeyUp, MSFlagsChanged,
       MSScroll = 22, MSODown = 25, MSOUp, MSODrag };
enum { MSFlagCaps = 1 << 16, MSFlagShift = 1 << 17, MSFlagCtrl = 1 << 18, MSFlagOpt = 1 << 19, MSFlagCmd = 1 << 20 };
enum { MSStyleFullScreen = 1 << 14 };

static void MSOnMain(dispatch_block_t b) { if ([NSThread isMainThread]) b(); else dispatch_sync(dispatch_get_main_queue(), b); }
/* The game runs inside a main-queue block (boot path) and pumps the run loop itself, so blocks queued on the main
 * dispatch queue never run. Run-loop blocks do: they fire on the game's next nextEventMatchingMask poll. */
/* GameController delivers controller input (and connect events) on the main dispatch queue. The game runs its loop
 * inside one run-loop callout on the main thread; g_mqBeat shows whether the main queue still gets serviced, and
 * nextEventMatchingMask: drains it itself when it falls behind. */
static _Atomic double g_mqBeat, g_mqAsked;
/* In the background the game is frozen: its loop waits in nextEventMatchingMask (UIKit keeps running, so iOS can
   suspend the app as usual) and its AVAudioEngines are paused - before, it kept simulating and playing sound after
   the user went to the Home Screen, slowing the phone down. Opening the app again continues where it was (unless iOS
   needed the memory and closed it). */
static _Atomic BOOL g_inBackground;
static NSHashTable *g_audioEngines;
extern void _dispatch_main_queue_callback_4CF(void *msg);
static void MSMainAsync(dispatch_block_t b) { CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, b); CFRunLoopWakeUp(CFRunLoopGetMain()); }

/* ---------------------------------------------------------------- screen info (C side uses this) */
static double g_sw = 1366, g_sh = 1024, g_ss = 2, g_fps = 120;
static double g_tvAspect;                    /* > 0: a TV was connected at launch, the game gets its shape (TV out) */
static UIScreen *MSExternalScreen(void) { for (UIScreen *s in UIScreen.screens) if (s != UIScreen.mainScreen) return s; return nil; }
static void MSRefreshScreen(void) {
    MSOnMain(^{
        UIScreen *s = UIScreen.mainScreen; g_sw = s.bounds.size.width; g_sh = s.bounds.size.height; g_ss = s.nativeScale; g_fps = (double)s.maximumFramesPerSecond;
        /* decided once, so the size the game was told never changes under it: same height (= same pixel cost) as
           the phone, the TV's width:height. TVOut = NO / TVShape = NO in macshim.plist turn it off. */
        static dispatch_once_t o; dispatch_once(&o, ^{
            UIScreen *x = MSExternalScreen();
            if (x && x.bounds.size.height > 0 && MSCfgD(@"TVOut", 1) != 0 && MSCfgD(@"TVShape", 1) != 0) g_tvAspect = x.bounds.size.width / x.bounds.size.height;
        });
        if (g_tvAspect > 0) g_sw = round(g_sh * g_tvAspect);
    });
}
/* the phone's own window scene; with a second screen UIKit adds a scene for it, which must never get the game's
   windows (iOS only sends touches to windows in the app's scene) */
static UIWindowScene *MSAppScene(void) {
    for (UIScene *x in UIApplication.sharedApplication.connectedScenes)
        if ([x isKindOfClass:UIWindowScene.class] && (((UIWindowScene *)x).screen == UIScreen.mainScreen || [x.session.role isEqualToString:UIWindowSceneSessionRoleApplication])) return (UIWindowScene *)x;
    return nil;
}
void MacShimScreenInfo(double *w, double *h, double *s, double *f) {
    static dispatch_once_t once; dispatch_once(&once, ^{ MSRefreshScreen(); });
    if (w) *w = g_sw; if (h) *h = g_sh; if (s) *s = g_ss; if (f) *f = g_fps;
}

/* ---------------------------------------------------------------- base: unknown selector -> log + 0 */
@interface MSBase : NSObject @end
@implementation MSBase
static void MSLogMissing(id self, SEL sel) {
    static NSMutableSet *seen; static dispatch_once_t o; dispatch_once(&o, ^{ seen = [NSMutableSet set]; });
    NSString *k = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(self)), NSStringFromSelector(sel)];
    @synchronized (seen) { if ([seen containsObject:k]) return; [seen addObject:k]; }
    MSLogf(@"unimplemented AppKit selector: %@", k);
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *m = [super methodSignatureForSelector:sel];
    return m ?: [NSMethodSignature signatureWithObjCTypes:"q@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv { MSLogMissing(self, inv.selector); long long z = 0; if (inv.methodSignature.methodReturnLength >= sizeof z) [inv setReturnValue:&z]; }
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *m = [super methodSignatureForSelector:sel];
    return m ?: [NSMethodSignature signatureWithObjCTypes:"q@:"];
}
+ (void)forwardInvocation:(NSInvocation *)inv { MSLogMissing(self, inv.selector); long long z = 0; if (inv.methodSignature.methodReturnLength >= sizeof z) [inv setReturnValue:&z]; }
@end

@interface NSResponder : MSBase
@property(nonatomic, weak) NSResponder *nextResponder;
@end
@implementation NSResponder
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)resignFirstResponder { return YES; }
@end

/* ---------------------------------------------------------------- AppKit coordinate space
 * The engine sizes its output as min(chosen display mode, screen size in points x 2): it assumes a 2x Retina Mac.
 * With the iPhone's real 956x440 pt @3x it never went above 1912x880. So AppKit sees a 2x display of the same
 * pixel size: points = UIKit points x (nativeScale / 2) (1434x660 on a 16 Pro Max), backingScaleFactor 2. Every
 * AppKit <-> UIKit conversion (view frames, mouse positions) goes through MSAKScale(). Retina2x = NO turns it off. */
int MacShimCurrentMode(void); double MacShimModeScale(int i);
static double MSAKScale(void) {
    /* AppKit screen size (points) = the resolution chosen on the start screen. Measured over several runs: with one
       display mode the engine's output is exactly the screen size it is told, in points (backing scale ignored):
       956x440 pt -> 956x440, 1434x660 -> 1434x660, 597x275 -> 597x275 (half was wrong) */
    static double k = 0;
    if (!k) k = [MSConfig()[@"Retina2x"] isEqual:@NO] ? 1 : MacShimModeScale(MacShimCurrentMode());
    return k;
}
double MacShimAppKitScale(void) { return MSAKScale(); }
static CGRect MSAKFromUI(CGRect r) { double k = MSAKScale(); return CGRectMake(r.origin.x * k, r.origin.y * k, r.size.width * k, r.size.height * k); }
static CGRect MSUIFromAK(CGRect r) { double k = MSAKScale(); return CGRectMake(r.origin.x / k, r.origin.y / k, r.size.width / k, r.size.height / k); }

/* ---------------------------------------------------------------- NSScreen */
@interface NSScreen : MSBase
+ (NSScreen *)mainScreen; + (NSArray *)screens;
@end
@implementation NSScreen
+ (NSScreen *)mainScreen { static NSScreen *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [NSScreen new]; }); return s; }
+ (NSArray *)screens { return @[ [self mainScreen] ]; }
- (CGRect)frame { double w, h; MacShimScreenInfo(&w, &h, 0, 0); return MSAKFromUI(CGRectMake(0, 0, w, h)); }
- (CGRect)visibleFrame { return [self frame]; }
- (CGFloat)backingScaleFactor { double s; MacShimScreenInfo(0, 0, &s, 0); return [MSConfig()[@"Retina2x"] isEqual:@NO] ? s : 2; }
- (NSInteger)maximumFramesPerSecond { double f; MacShimScreenInfo(0, 0, 0, &f); return (NSInteger)f; }
- (CGFloat)maximumExtendedDynamicRangeColorComponentValue {
    __block CGFloat v = 1; MSOnMain(^{ id n = [UIScreen.mainScreen valueForKey:@"currentEDRHeadroom"]; if ([n respondsToSelector:@selector(doubleValue)]) v = [n doubleValue]; }); return v < 1 ? 1 : v; }
- (CGFloat)maximumPotentialExtendedDynamicRangeColorComponentValue {
    __block CGFloat v = 1; MSOnMain(^{ id n = [UIScreen.mainScreen valueForKey:@"potentialEDRHeadroom"]; if ([n respondsToSelector:@selector(doubleValue)]) v = [n doubleValue]; }); return v < 1 ? 1 : v; }
- (NSString *)localizedName { return @"iPad Display"; }
- (NSDictionary *)deviceDescription {
    CGRect f = [self frame]; CGFloat s = [self backingScaleFactor];
    return @{ @"NSScreenNumber": @(1u), @"NSDeviceSize": [NSValue valueWithCGSize:f.size],
              @"NSDeviceResolution": [NSValue valueWithCGSize:CGSizeMake(72 * s, 72 * s)] };
}
@end

/* ---------------------------------------------------------------- NSEvent + keyboard map */
@interface NSEvent : MSBase
@property(nonatomic) NSUInteger type, modifierFlags; @property(nonatomic) NSInteger buttonNumber, clickCount;
@property(nonatomic) CGPoint locationInWindow; @property(nonatomic) unsigned short keyCode;
@property(nonatomic) CGFloat scrollingDeltaX, scrollingDeltaY, deltaX, deltaY; @property(nonatomic) BOOL hasPreciseScrollingDeltas, isARepeat;
@property(nonatomic) NSTimeInterval timestamp; @property(nonatomic, copy) NSString *characters, *charactersIgnoringModifiers;
@property(nonatomic, weak) id window;
+ (CGPoint)mouseLocation;
+ (id)addLocalMonitorForEventsMatchingMask:(unsigned long long)mask handler:(NSEvent *(^)(NSEvent *))h;
+ (void)removeMonitor:(id)m;
+ (void)setMouseCoalescingEnabled:(BOOL)b;
@end

@interface MSMonitor : NSObject @property unsigned long long mask; @property(copy) NSEvent *(^handler)(NSEvent *); @end
@implementation MSMonitor @end
static NSMutableArray *g_monitors;

@implementation NSEvent
+ (CGPoint)mouseLocation { return g_mouse; }
+ (id)addLocalMonitorForEventsMatchingMask:(unsigned long long)mask handler:(NSEvent *(^)(NSEvent *))h {
    static dispatch_once_t o; dispatch_once(&o, ^{ g_monitors = [NSMutableArray array]; });
    MSMonitor *m = [MSMonitor new]; m.mask = mask; m.handler = h; @synchronized (g_monitors) { [g_monitors addObject:m]; } return m; }
+ (void)removeMonitor:(id)m { @synchronized (g_monitors) { [g_monitors removeObject:m]; } }
+ (void)setMouseCoalescingEnabled:(BOOL)b {}
@end

/* GCKeyCode (USB HID usage) -> macOS virtual key code */
static NSDictionary *MSKeyMap(void) {   /* GCKeyCode (USB HID usage) -> macOS virtual key code; built at runtime (GCKeyCode* are not compile-time constants) */
    static NSDictionary *m; static dispatch_once_t o;
    dispatch_once(&o, ^{ m = @{
 @((NSInteger)GCKeyCodeKeyA): @0,
 @((NSInteger)GCKeyCodeKeyS): @1,
 @((NSInteger)GCKeyCodeKeyD): @2,
 @((NSInteger)GCKeyCodeKeyF): @3,
 @((NSInteger)GCKeyCodeKeyH): @4,
 @((NSInteger)GCKeyCodeKeyG): @5,
 @((NSInteger)GCKeyCodeKeyZ): @6,
 @((NSInteger)GCKeyCodeKeyX): @7,
 @((NSInteger)GCKeyCodeKeyC): @8,
 @((NSInteger)GCKeyCodeKeyV): @9,
 @((NSInteger)GCKeyCodeKeyB): @11,
 @((NSInteger)GCKeyCodeKeyQ): @12,
 @((NSInteger)GCKeyCodeKeyW): @13,
 @((NSInteger)GCKeyCodeKeyE): @14,
 @((NSInteger)GCKeyCodeKeyR): @15,
 @((NSInteger)GCKeyCodeKeyY): @16,
 @((NSInteger)GCKeyCodeKeyT): @17,
 @((NSInteger)GCKeyCodeOne): @18,
 @((NSInteger)GCKeyCodeTwo): @19,
 @((NSInteger)GCKeyCodeThree): @20,
 @((NSInteger)GCKeyCodeFour): @21,
 @((NSInteger)GCKeyCodeSix): @22,
 @((NSInteger)GCKeyCodeFive): @23,
 @((NSInteger)GCKeyCodeEqualSign): @24,
 @((NSInteger)GCKeyCodeNine): @25,
 @((NSInteger)GCKeyCodeSeven): @26,
 @((NSInteger)GCKeyCodeHyphen): @27,
 @((NSInteger)GCKeyCodeEight): @28,
 @((NSInteger)GCKeyCodeZero): @29,
 @((NSInteger)GCKeyCodeCloseBracket): @30,
 @((NSInteger)GCKeyCodeKeyO): @31,
 @((NSInteger)GCKeyCodeKeyU): @32,
 @((NSInteger)GCKeyCodeOpenBracket): @33,
 @((NSInteger)GCKeyCodeKeyI): @34,
 @((NSInteger)GCKeyCodeKeyP): @35,
 @((NSInteger)GCKeyCodeReturnOrEnter): @36,
 @((NSInteger)GCKeyCodeKeyL): @37,
 @((NSInteger)GCKeyCodeKeyJ): @38,
 @((NSInteger)GCKeyCodeQuote): @39,
 @((NSInteger)GCKeyCodeKeyK): @40,
 @((NSInteger)GCKeyCodeSemicolon): @41,
 @((NSInteger)GCKeyCodeBackslash): @42,
 @((NSInteger)GCKeyCodeComma): @43,
 @((NSInteger)GCKeyCodeSlash): @44,
 @((NSInteger)GCKeyCodeKeyN): @45,
 @((NSInteger)GCKeyCodeKeyM): @46,
 @((NSInteger)GCKeyCodePeriod): @47,
 @((NSInteger)GCKeyCodeTab): @48,
 @((NSInteger)GCKeyCodeSpacebar): @49,
 @((NSInteger)GCKeyCodeGraveAccentAndTilde): @50,
 @((NSInteger)GCKeyCodeDeleteOrBackspace): @51,
 @((NSInteger)GCKeyCodeEscape): @53,
 @((NSInteger)GCKeyCodeRightGUI): @54,
 @((NSInteger)GCKeyCodeLeftGUI): @55,
 @((NSInteger)GCKeyCodeLeftShift): @56,
 @((NSInteger)GCKeyCodeCapsLock): @57,
 @((NSInteger)GCKeyCodeLeftAlt): @58,
 @((NSInteger)GCKeyCodeLeftControl): @59,
 @((NSInteger)GCKeyCodeRightShift): @60,
 @((NSInteger)GCKeyCodeRightAlt): @61,
 @((NSInteger)GCKeyCodeRightControl): @62,
 @((NSInteger)GCKeyCodeF5): @96,
 @((NSInteger)GCKeyCodeF6): @97,
 @((NSInteger)GCKeyCodeF7): @98,
 @((NSInteger)GCKeyCodeF3): @99,
 @((NSInteger)GCKeyCodeF8): @100,
 @((NSInteger)GCKeyCodeF9): @101,
 @((NSInteger)GCKeyCodeF11): @103,
 @((NSInteger)GCKeyCodeF10): @109,
 @((NSInteger)GCKeyCodeF12): @111,
 @((NSInteger)GCKeyCodeHome): @115,
 @((NSInteger)GCKeyCodePageUp): @116,
 @((NSInteger)GCKeyCodeDeleteForward): @117,
 @((NSInteger)GCKeyCodeF4): @118,
 @((NSInteger)GCKeyCodeEnd): @119,
 @((NSInteger)GCKeyCodeF2): @120,
 @((NSInteger)GCKeyCodePageDown): @121,
 @((NSInteger)GCKeyCodeF1): @122,
 @((NSInteger)GCKeyCodeLeftArrow): @123,
 @((NSInteger)GCKeyCodeRightArrow): @124,
 @((NSInteger)GCKeyCodeDownArrow): @125,
 @((NSInteger)GCKeyCodeUpArrow): @126,
 @((NSInteger)GCKeyCodeKeypadEnter): @76,
 @((NSInteger)GCKeyCodeKeypadPeriod): @65,
 @((NSInteger)GCKeyCodeKeypadAsterisk): @67,
 @((NSInteger)GCKeyCodeKeypadPlus): @69,
 @((NSInteger)GCKeyCodeKeypadHyphen): @78,
 @((NSInteger)GCKeyCodeKeypadSlash): @75,
 @((NSInteger)GCKeyCodeKeypad0): @82,
 @((NSInteger)GCKeyCodeKeypad1): @83,
 @((NSInteger)GCKeyCodeKeypad2): @84,
 @((NSInteger)GCKeyCodeKeypad3): @85,
 @((NSInteger)GCKeyCodeKeypad4): @86,
 @((NSInteger)GCKeyCodeKeypad5): @87,
 @((NSInteger)GCKeyCodeKeypad6): @88,
 @((NSInteger)GCKeyCodeKeypad7): @89,
 @((NSInteger)GCKeyCodeKeypad8): @91,
 @((NSInteger)GCKeyCodeKeypad9): @92
    }; });
    return m;
}
static NSUInteger MSFlagForMac(unsigned short k) {
    switch (k) { case 56: case 60: return MSFlagShift; case 59: case 62: return MSFlagCtrl; case 58: case 61: return MSFlagOpt;
                 case 55: case 54: return MSFlagCmd; case 57: return MSFlagCaps; default: return 0; }
}

/* ---------------------------------------------------------------- forward decls */
@class NSWindow, NSView;
@interface NSApplication : MSBase
@property(nonatomic, strong) id delegate;
@property(nonatomic) NSUInteger presentationOptions;
@property(nonatomic, readonly) BOOL isActive, isHidden, isRunning;
@property(nonatomic, strong) NSMutableArray *windows;
@property(nonatomic, weak) NSWindow *keyWindow, *mainWindow;
@property(nonatomic, strong) id mainMenu;
+ (NSApplication *)sharedApplication;
- (void)run; - (void)sendEvent:(NSEvent *)e; - (void)msBecomeActive:(BOOL)a;
@end

static void MSDispatch(NSEvent *e);
static BOOL g_activePending;
static _Atomic int g_galaxyFailures;

/* ---------------------------------------------------------------- NSTrackingArea / NSCursor / NSImage / NSMenu / NSWorkspace */
@interface NSTrackingArea : MSBase
- (instancetype)initWithRect:(CGRect)r options:(NSUInteger)o owner:(id)owner userInfo:(NSDictionary *)u; @end
@implementation NSTrackingArea - (instancetype)initWithRect:(CGRect)r options:(NSUInteger)o owner:(id)owner userInfo:(NSDictionary *)u { return [super init]; } @end

@interface NSCursor : MSBase @end
@implementation NSCursor
+ (NSCursor *)arrowCursor { static NSCursor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = [NSCursor new]; }); return c; }
+ (NSCursor *)currentCursor { return [self arrowCursor]; }
+ (NSCursor *)pointingHandCursor { return [self arrowCursor]; } + (NSCursor *)IBeamCursor { return [self arrowCursor]; }
+ (void)hide   { if (!g_cursorHidden) { static int n; if (n++ < 20) MSLogf(@"cursor hidden (gameplay?)"); } g_cursorHidden = YES; }
+ (void)unhide { if (g_cursorHidden) { static int n; if (n++ < 20) MSLogf(@"cursor shown"); } g_cursorHidden = NO; }
+ (void)setHiddenUntilMouseMoves:(BOOL)b {}
- (void)set {} - (void)push {} + (void)pop {}
@end

@interface NSImage : MSBase
@property(nonatomic) CGSize size;
- (instancetype)initWithSize:(CGSize)s; - (instancetype)initWithCGImage:(CGImageRef)i size:(CGSize)s; @end
@implementation NSImage
- (instancetype)initWithSize:(CGSize)s { self = [super init]; _size = s; return self; }
- (instancetype)initWithCGImage:(CGImageRef)i size:(CGSize)s { self = [super init]; _size = s; return self; }
- (void)lockFocus {} - (void)unlockFocus {}
@end

@interface NSMenu : MSBase @end
@implementation NSMenu + (void)setMenuBarVisible:(BOOL)v {} + (BOOL)menuBarVisible { return NO; } @end

@interface NSWorkspace : MSBase + (NSWorkspace *)sharedWorkspace; - (BOOL)openURL:(NSURL *)u; @end
@implementation NSWorkspace
+ (NSWorkspace *)sharedWorkspace { static NSWorkspace *w; static dispatch_once_t o; dispatch_once(&o, ^{ w = [NSWorkspace new]; }); return w; }
- (BOOL)openURL:(NSURL *)u { MSMainAsync(^{ [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil]; }); return YES; }
@end

/* ---------------------------------------------------------------- UIKit side: host view + root VC */
@interface MSHostView : UIView <UIPointerInteractionDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, weak) NSView *owner;
- (void)msClick:(CGPoint)p right:(BOOL)r;
- (void)msScrollBy:(CGPoint)d at:(CGPoint)p;
- (void)msMouseDelta:(CGPoint)d;
- (NSEvent *)msEvent:(NSUInteger)type at:(CGPoint)p;
- (void)msButton:(BOOL)down right:(BOOL)r at:(CGPoint)p;
- (void)msTouches:(NSSet<UITouch *> *)ts phase:(int)ph event:(UIEvent *)ev;
@end
static _Atomic int g_gcmCount;                   /* GameController mice connected (see MSAttachMouse) */
@interface MSRootVC : UIViewController @end
@implementation MSRootVC
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)prefersPointerLocked { return g_pointerLocked || g_gcmCount > 0; }   /* a locked pointer is what makes iOS send raw mouse motion */
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
void MacShimLogC(const char *what, const char *detail) { MSLogf(@"%s: %s", what, detail); }   /* for MacShimC.c */
void MacShimSetPointerLocked(int locked) {
    if ((locked != 0) != g_pointerLocked) { static int n; if (n++ < 20) MSLogf(@"pointer %@", locked ? @"locked (gameplay)" : @"unlocked"); }
    g_pointerLocked = locked != 0;
    MSMainAsync(^{
        for (id w in [(NSApplication *)NSApp windows]) {
            UIWindow *uw = [w valueForKey:@"uiWindow"]; [uw.rootViewController setNeedsUpdateOfPrefersPointerLocked];
        }
    });
}

/* ---------------------------------------------------------------- NSView (plain object that owns a UIView) */
@interface NSView : NSResponder
@property(nonatomic) CGRect frame; @property(nonatomic, readonly) CGRect bounds;
@property(nonatomic, weak) NSWindow *window; @property(nonatomic, weak) NSView *superview; @property(nonatomic, strong) NSMutableArray *subviews;
@property(nonatomic) BOOL wantsLayer, hidden; @property(nonatomic, strong) CALayer *layer; @property(nonatomic, strong) NSMutableArray *trackingAreas;
@property(nonatomic, strong, readonly) MSHostView *host;
- (instancetype)initWithFrame:(CGRect)f;
- (void)msLayoutFromHost;
@end

static CGPoint MSToCocoa(CGPoint p, UIView *v) { double k = MSAKScale(); return CGPointMake(p.x * k, (v.bounds.size.height - p.y) * k); }

/* The game's mouse gate: GameView's mouseDown:/mouseMoved:/scrollWheel: drop every event unless a byte in the engine's
 * global input state (0x10853fac0 + 0x39, getter 0x102e2c184) is set. On a Mac it is set once a real mouse is in use;
 * nothing on the phone sets it, so touches never moved the cursor. The shim sets it whenever a touch acts as the mouse. */
#define MS_MOUSE_GATE 0x10853faf9ULL
static intptr_t MSExeSlide(void) {
    static intptr_t s = -1;
    if (s == -1) for (uint32_t k = 0; k < _dyld_image_count(); k++) if (_dyld_get_image_header(k)->filetype == MH_EXECUTE) { s = _dyld_get_image_vmaddr_slide(k); break; }
    return s;
}
static int MSMouseGate(void) { return *(volatile uint8_t *)(MS_MOUSE_GATE + MSExeSlide()); }
static void MSOpenMouseGate(void) {
    volatile uint8_t *g = (volatile uint8_t *)(MS_MOUSE_GATE + MSExeSlide());
    if (!*g) { *g = 1; static int n; if (n++ < 5) MSLogf(@"mouse gate opened (touch = mouse)"); }
}
static _Atomic long long g_gcmMoves, g_gcmHovers; static _Atomic double g_gcmLastMoveAt;
static CGPoint g_gcmCursor; static BOOL g_gcmCursorSet;  /* where menu mouse events point (view points) */
static void MSGCMouseMove(MSHostView *h, CGPoint d);
static CGPoint MSGCMouseAt(MSHostView *h);
static CGPoint g_gcmPending; static BOOL g_gcmLeft, g_gcmRight;
static __weak MSHostView *g_hostView;           /* the game's view, for the AutoKeys test aid */
/* camera swipe -> mouse look. Touches come in bursts (whenever the game's loop lets the run loop turn), so sending
   them as they arrive gave the camera uneven steps (jitter). The pad adds all finger movement (coalesced touches,
   full touch rate) here; the game's event poll hands it over once per frame, smoothed: a share of what's pending
   goes out each frame and the rest follows, so no movement is lost. LookSmooth (0-0.9, default 0.35) = how much
   is held back per frame. */
static CGPoint g_lookPending; static os_unfair_lock g_lookLock = OS_UNFAIR_LOCK_INIT;
static int g_lookStick = -1;                          /* 1: swipe drives the right stick (default), 0: mouse look */
static double g_lookFingerAt;                         /* last time the look finger moved */
static void MSLookFlushStick(double dt);
static void MSGCMouseFlush(void);
static double MSLookSensitivity(void);
static void MSLookAdd(CGPoint d) { os_unfair_lock_lock(&g_lookLock); g_lookPending.x += d.x; g_lookPending.y += d.y; os_unfair_lock_unlock(&g_lookLock); }

/* a touch's position on the game's view. A touch on another screen (the phone while the picture is on a TV) maps
   by position: the whole phone screen covers the whole picture. */
static CGPoint MSTouchIn(UITouch *t, UIView *host) {
    UIView *v = t.view;
    if (!v || !host || v.window.screen == host.window.screen) return [t locationInView:host];
    CGPoint p = [t locationInView:v]; CGSize s = v.bounds.size, h = host.bounds.size;
    if (s.width < 1 || s.height < 1) return p;
    CGRect r;     /* the phone shows the picture too: a touch maps onto where the picture is drawn */
    if (MSMirrorFit(v, &r)) return CGPointMake(fmin(fmax((p.x - r.origin.x) / r.size.width, 0), 1) * h.width,
                                               fmin(fmax((p.y - r.origin.y) / r.size.height, 0), 1) * h.height);
    return CGPointMake(p.x / s.width * h.width, p.y / s.height * h.height);
}
@implementation MSHostView
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f]; if (!self) return nil;
    g_hostView = self;
    self.multipleTouchEnabled = YES; self.backgroundColor = UIColor.blackColor; self.opaque = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addInteraction:[[UIPointerInteraction alloc] initWithDelegate:self]];
    UIHoverGestureRecognizer *hv = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(msHover:)]; [self addGestureRecognizer:hv];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(msScroll:)];
    pan.allowedScrollTypesMask = UIScrollTypeMaskAll; pan.allowedTouchTypes = @[]; pan.minimumNumberOfTouches = 0; [self addGestureRecognizer:pan];
    return self;
}
- (void)layoutSubviews { [super layoutSubviews]; [self.owner msLayoutFromHost]; }
- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)i styleForRegion:(UIPointerRegion *)r { return g_cursorHidden ? [UIPointerStyle hiddenPointerStyle] : nil; }

- (NSEvent *)msEvent:(NSUInteger)type at:(CGPoint)p {
    NSEvent *e = [NSEvent new]; e.type = type; e.locationInWindow = MSToCocoa(p, self); e.modifierFlags = g_modFlags;
    e.timestamp = CACurrentMediaTime(); e.window = self.owner.window; g_mouse = e.locationInWindow; return e;
}
/* A finger on the game (menus; in gameplay the touch pad takes the screen): tap = move the cursor there, click a few
 * frames later (the game's UI only takes a click on what it already shows as hovered, and it reads input once per
 * frame); drag = scroll wheel (the user agreement must be scrolled to the end); hold still 0.35 s, then drag = mouse
 * drag (sliders); two-finger tap = right click. ScrollSpeed (default 1.5) scales the scrolling. */
static UITouch *g_fTouch; static CGPoint g_fStart, g_fLast; static int g_fMode, g_fFingers; static unsigned g_fGen; static BOOL g_fEntered;
static double g_fBeganAt, g_gcmButtonAt;          /* AssistiveTouch: a mouse click also arrives as a tap - keep only the click */
static void MSAfter(double s, dispatch_block_t b) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{ MSMainAsync(b); });
}
- (void)msButton:(BOOL)down right:(BOOL)r at:(CGPoint)p {
    NSEvent *e = [self msEvent:(r ? (down ? MSRDown : MSRUp) : (down ? MSLDown : MSLUp)) at:p]; e.clickCount = 1; e.buttonNumber = r; MSDispatch(e);
}
- (void)msScrollBy:(CGPoint)d at:(CGPoint)p {        /* finger movement in points: down = content moves down */
    static double speed; if (!speed) speed = MSCfgD(@"ScrollSpeed", 1.5);
    NSEvent *e = [self msEvent:MSScroll at:p];
    e.scrollingDeltaX = d.x * speed; e.scrollingDeltaY = d.y * speed; e.deltaX = d.x * speed / 10; e.deltaY = d.y * speed / 10;
    e.hasPreciseScrollingDeltas = NO; MSDispatch(e);
}
- (void)msMouseDelta:(CGPoint)d {                    /* relative mouse motion (camera look), cursor stays put */
    MSOpenMouseGate();
    CGPoint c = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
    NSEvent *e = [self msEvent:MSMouseMoved at:c]; e.deltaX = d.x; e.deltaY = d.y; MSDispatch(e);
}
- (void)msClick:(CGPoint)p right:(BOOL)r {
    MSDispatch([self msEvent:MSMouseMoved at:p]);
    MSAfter(0.07, ^{ [self msButton:YES right:r at:p]; MSAfter(0.07, ^{ [self msButton:NO right:r at:p]; }); });
}
/* iPhone + mouse: iOS passes a mouse on only through AssistiveTouch. The left button reaches the app either as a real
   GameController button or as a tap at AssistiveTouch's pointer (not where the game's blue cursor is) - seen both ways.
   Either one presses the left button at the blue cursor (screen centre in gameplay); when both come for one click,
   the first wins. A press is held at least 80 ms (the game reads buttons once per frame and missed shorter ones). */
static UITouch *g_atTouch; static BOOL g_atIgnore; static double g_leftDownAt; static int g_leftBy;   /* 1 = tap, 2 = GC */
static void MSLeftPress(int by, BOOL down) {
    MSHostView *h = g_hostView; if (!h) return;
    if (down) {
        if (g_leftBy) return;                              /* already down (the other source's twin) */
        g_leftBy = by; g_leftDownAt = CACurrentMediaTime(); g_gcmLeft = YES;
        MSOpenMouseGate(); MSGCMouseFlush(); [h msButton:YES right:NO at:MSGCMouseAt(h)];
        return;
    }
    if (g_leftBy != by) return;
    g_leftBy = 0;
    double held = CACurrentMediaTime() - g_leftDownAt;
    dispatch_block_t up = ^{ if (g_leftBy) return; g_gcmLeft = NO; MSHostView *hh = g_hostView; if (hh) [hh msButton:NO right:NO at:MSGCMouseAt(hh)]; };
    if (held < 0.08) MSAfter(0.08 - held, up); else up();
}
- (void)msMouseTap:(UITouch *)t phase:(int)ph {
    if (ph == 0) {
        if (g_atTouch) return;
        g_atTouch = t; g_atIgnore = g_leftBy != 0;          /* the GC button got this click first */
        static int n; if (n++ < 6) MSLogf(@"mouse: tap (left click)%@", g_atIgnore ? @" - twin of a button press, ignored" : @"");
        if (!g_atIgnore) MSLeftPress(1, YES);
        return;
    }
    if (t != g_atTouch || ph == 1) return;                 /* movement comes from the mouse itself */
    g_atTouch = nil; if (!g_atIgnore) MSLeftPress(1, NO);
}
- (void)msFinger:(UITouch *)t phase:(int)ph event:(UIEvent *)ev {
    if (g_gcmCount) { [self msMouseTap:t phase:ph]; return; }
    CGPoint p = MSTouchIn(t, self);
    if (ph == 0) {
        g_fBeganAt = CACurrentMediaTime();
        MSOpenMouseGate();
        if (!g_fEntered) { g_fEntered = YES; MSDispatch([self msEvent:MSEnter at:p]); }     /* the game tracks "cursor in view" */
        if (g_fTouch) { if (g_fMode == 0) g_fFingers = 2; return; }                         /* second finger: right click on release */
        g_fTouch = t; g_fStart = g_fLast = p; g_fMode = 0; g_fFingers = 1; unsigned gen = ++g_fGen;
        MSDispatch([self msEvent:MSMouseMoved at:p]);
        MSAfter(0.35, ^{
            if (gen != g_fGen || !g_fTouch || g_fMode != 0 || g_fFingers != 1) return;
            g_fMode = 2; [self msButton:YES right:NO at:g_fLast];
        });
        return;
    }
    if (t != g_fTouch) return;
    if (ph == 1) {
        CGFloat dx = p.x - g_fLast.x, dy = p.y - g_fLast.y;
        if (g_fMode == 0 && hypot(p.x - g_fStart.x, p.y - g_fStart.y) > 8) g_fMode = 1;
        if (g_fMode == 1) [self msScrollBy:CGPointMake(dx, dy) at:g_fStart];
        else if (g_fMode == 2) MSDispatch([self msEvent:MSLDrag at:p]);
        g_fLast = p; return;
    }
    g_fTouch = nil; g_fGen++;
    if (g_fMode == 2) [self msButton:NO right:NO at:p];
    else if (g_fMode == 0) [self msClick:g_fStart right:g_fFingers >= 2];
}
- (void)msTouches:(NSSet<UITouch *> *)ts phase:(int)ph event:(UIEvent *)ev {
    for (UITouch *f in ts) if (f.type == UITouchTypeDirect) [self msFinger:f phase:ph event:ev];
    UITouch *t = nil; for (UITouch *x in ts) if (x.type == UITouchTypeIndirectPointer) t = x;
    if (!t || g_gcmCount) return; CGPoint p = MSTouchIn(t, self);  /* mouse / trackpad: straight through (unless GCMouse has it) */
    MSOpenMouseGate();
    BOOL right = (t.type == UITouchTypeIndirectPointer) && (ev.buttonMask & UIEventButtonMaskSecondary);
    NSUInteger down = right ? MSRDown : MSLDown, up = right ? MSRUp : MSLUp, drag = right ? MSRDrag : MSLDrag;
    if (ph == 0 && t.type != UITouchTypeIndirectPointer) MSDispatch([self msEvent:MSMouseMoved at:p]);
    NSEvent *e = [self msEvent:(ph == 0 ? down : ph == 1 ? drag : up) at:p]; e.clickCount = 1; e.buttonNumber = right ? 1 : 0; MSDispatch(e);
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e     { [self msTouches:t phase:0 event:e]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e     { [self msTouches:t phase:1 event:e]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e     { [self msTouches:t phase:2 event:e]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self msTouches:t phase:2 event:e]; }
- (void)msHover:(UIHoverGestureRecognizer *)g {
    CGPoint p = [g locationInView:self];
    if (g_gcmCount) {                   /* a mouse is connected: raw motion moves the cursor; if none arrives (AssistiveTouch
                                           keeps it for its own pointer), follow that pointer instead */
        if (CACurrentMediaTime() - g_gcmLastMoveAt < 1.0 || g_pointerLocked) return;
        static CGPoint last; static BOOL have;
        if (g.state == UIGestureRecognizerStateBegan || !have) { last = p; have = YES; }
        CGPoint d = CGPointMake(p.x - last.x, p.y - last.y); last = p; g_gcmHovers++;
        if (g.state == UIGestureRecognizerStateEnded) have = NO;
        if (d.x != 0 || d.y != 0) MSGCMouseMove(self, d);
        return;
    }
    MSOpenMouseGate();
    if (g.state == UIGestureRecognizerStateBegan) MSDispatch([self msEvent:MSEnter at:p]);
    if (g.state == UIGestureRecognizerStateChanged) MSDispatch([self msEvent:MSMouseMoved at:p]);
    if (g.state == UIGestureRecognizerStateEnded) MSDispatch([self msEvent:MSExit at:p]);
}
- (void)msScroll:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGPoint tr = [g translationInView:self]; [g setTranslation:CGPointZero inView:self];
    NSEvent *e = [self msEvent:MSScroll at:[g locationInView:self]]; e.scrollingDeltaX = tr.x; e.scrollingDeltaY = tr.y; e.deltaX = tr.x; e.deltaY = tr.y;
    e.hasPreciseScrollingDeltas = YES; MSDispatch(e);
}
@end

@implementation NSView
@synthesize layer = _layer;
- (instancetype)initWithFrame:(CGRect)f {
    self = [super init]; if (!self) return nil;
    _subviews = [NSMutableArray array]; _trackingAreas = [NSMutableArray array];
    __block MSHostView *h; MSOnMain(^{ h = [[MSHostView alloc] initWithFrame:MSUIFromAK(f)]; }); _host = h; _host.owner = self; _frame = f; return self;
}
- (instancetype)init { return [self initWithFrame:CGRectMake(0, 0, 100, 100)]; }
- (CGRect)bounds { return CGRectMake(0, 0, _frame.size.width, _frame.size.height); }
- (void)setFrame:(CGRect)f { _frame = f; MSOnMain(^{ if (self.superview) self.host.frame = MSUIFromAK(f); }); }
- (void)setFrameSize:(CGSize)s { [self setFrame:CGRectMake(_frame.origin.x, _frame.origin.y, s.width, s.height)]; }
- (void)setFrameOrigin:(CGPoint)p { [self setFrame:CGRectMake(p.x, p.y, _frame.size.width, _frame.size.height)]; }
- (void)addSubview:(NSView *)v { [_subviews addObject:v]; v.superview = self; MSOnMain(^{ [self.host addSubview:v.host]; v.host.frame = MSUIFromAK(v.frame); }); }
- (void)removeFromSuperview { NSView *s = _superview; [s.subviews removeObject:self]; _superview = nil; MSOnMain(^{ [self.host removeFromSuperview]; }); }
- (void)setWantsLayer:(BOOL)b { _wantsLayer = b; }
- (CALayer *)layer { return _layer ?: _host.layer; }
- (void)setLayer:(CALayer *)l {
    _layer = l; if (!l) return;
    MSOnMain(^{ l.contentsScale = UIScreen.mainScreen.nativeScale; l.frame = self.host.bounds; [self.host.layer addSublayer:l]; });
    /* start screen "Performance overlay: Detailed" also turns on Apple's Metal HUD for the game's layer */
    if ([l isKindOfClass:CAMetalLayer.class] && MSPref(@"MacShimOverlay", 1) == 2 && [l respondsToSelector:NSSelectorFromString(@"setDeveloperHUDProperties:")])
        [l setValue:@{ @"mode": @"default" } forKey:@"developerHUDProperties"];
}
- (void)setHidden:(BOOL)h { _hidden = h; MSOnMain(^{ self.host.hidden = h; }); }
- (void)msLayoutFromHost {
    CGRect b = _host.bounds, ab = MSAKFromUI(b); BOOL changed = !CGSizeEqualToSize(ab.size, _frame.size);
    if (_layer) { [CATransaction begin]; [CATransaction setDisableActions:YES]; _layer.frame = b; [CATransaction commit]; }
    if (changed) {
        _frame.size = ab.size;
        if ([self respondsToSelector:@selector(viewDidChangeBackingProperties)]) ((void (*)(id, SEL))objc_msgSend)(self, @selector(viewDidChangeBackingProperties));
        id w = self.window; if (w && [w valueForKey:@"contentView"] == self) ((void (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"msContentResized"));
    }
}
- (void)addTrackingArea:(NSTrackingArea *)a { [_trackingAreas addObject:a]; }
- (void)removeTrackingArea:(NSTrackingArea *)a { [_trackingAreas removeObject:a]; }
- (NSArray *)trackingAreas { return _trackingAreas; }
- (void)updateTrackingAreas {} - (void)resetCursorRects {} - (void)discardCursorRects {} - (void)addCursorRect:(CGRect)r cursor:(id)c {}
- (void)viewDidMoveToWindow {} - (void)setNeedsDisplay:(BOOL)b {} - (void)lockFocus {} - (void)unlockFocus {}
- (CGPoint)convertPoint:(CGPoint)p fromView:(NSView *)v { return p; } - (CGPoint)convertPoint:(CGPoint)p toView:(NSView *)v { return p; }
- (CGRect)convertRectToBacking:(CGRect)r { CGFloat s = [NSScreen.mainScreen backingScaleFactor]; return CGRectMake(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s); }
- (CGRect)convertRectFromBacking:(CGRect)r { CGFloat s = [NSScreen.mainScreen backingScaleFactor]; return CGRectMake(r.origin.x / s, r.origin.y / s, r.size.width / s, r.size.height / s); }
- (BOOL)isHidden { return _hidden; }
- (BOOL)canBecomeKeyView { return YES; } - (BOOL)mouseDownCanMoveWindow { return NO; } - (BOOL)isFlipped { return NO; }
@end

/* ---------------------------------------------------------------- NSWindow / NSWindowController */
@interface NSWindow : NSResponder
@property(nonatomic, strong) NSView *contentView; @property(nonatomic, weak) id delegate; @property(nonatomic, weak) id windowController;
@property(nonatomic) NSUInteger styleMask; @property(nonatomic, copy) NSString *title; @property(nonatomic, strong) NSResponder *firstResponder;
@property(nonatomic) BOOL isVisible, isKeyWindow, isMainWindow, acceptsMouseMovedEvents;
- (instancetype)initWithContentRect:(CGRect)r styleMask:(NSUInteger)m backing:(NSUInteger)b defer:(BOOL)d;
- (instancetype)initWithContentRect:(CGRect)r styleMask:(NSUInteger)m backing:(NSUInteger)b defer:(BOOL)d screen:(id)s;
- (void)makeKeyAndOrderFront:(id)s; - (void)msBecameKey; - (void)msResignedKey;
@end

@implementation NSWindow {
    UIWindow *_uiWindow; CGRect _frame;
}
- (instancetype)initWithContentRect:(CGRect)r styleMask:(NSUInteger)m backing:(NSUInteger)b defer:(BOOL)d screen:(id)s {
    self = [super init]; if (!self) return nil;
    _styleMask = m; _frame = [NSScreen.mainScreen frame];
    MSOnMain(^{
        /* in the app's window scene: iOS only delivers touches to windows that belong to a scene (one made with
           initWithFrame: is drawn but never gets a touch - touch-as-mouse never reached the game) */
        UIWindowScene *sc = MSAppScene();
        self->_uiWindow = sc ? [[UIWindow alloc] initWithWindowScene:sc] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        MSLogf(@"game window created %@", sc ? @"in the app's scene" : @"WITHOUT a scene (no touches)");
        self->_uiWindow.rootViewController = [MSRootVC new]; self->_uiWindow.backgroundColor = UIColor.blackColor;
    });
    NSApplication *app = [NSApplication sharedApplication]; [app.windows addObject:self];
    return self;
}
- (instancetype)initWithContentRect:(CGRect)r styleMask:(NSUInteger)m backing:(NSUInteger)b defer:(BOOL)d { return [self initWithContentRect:r styleMask:m backing:b defer:d screen:nil]; }
- (UIWindow *)uiWindow { return _uiWindow; }
- (void)setContentView:(NSView *)v {
    _contentView = v; v.window = self; v.superview = nil;
    MSOnMain(^{
        UIView *root = self->_uiWindow.rootViewController.view; v.host.frame = root.bounds; [root addSubview:v.host];
        v.host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    });
    MSOnMain(^{ MSTVRoute(); });
    [v msLayoutFromHost];
    if ([v respondsToSelector:@selector(viewDidMoveToWindow)]) ((void (*)(id, SEL))objc_msgSend)(v, @selector(viewDidMoveToWindow));
}
- (CGRect)frame { return _frame; } - (CGRect)contentLayoutRect { return CGRectMake(0, 0, _frame.size.width, _frame.size.height); }
- (CGRect)contentRectForFrameRect:(CGRect)r { return r; } - (CGRect)frameRectForContentRect:(CGRect)r { return r; }
- (void)setFrame:(CGRect)f display:(BOOL)d animate:(BOOL)a {} - (void)setFrame:(CGRect)f display:(BOOL)d {} - (void)setContentSize:(CGSize)s {} - (void)setFrameOrigin:(CGPoint)p {}
- (void)setContentAspectRatio:(CGSize)s {} - (void)center {} - (void)setOpaque:(BOOL)b {} - (void)setLevel:(NSInteger)l {} - (void)setCollectionBehavior:(NSUInteger)c {}
- (id)screen { return NSScreen.mainScreen; } - (CGFloat)backingScaleFactor { return [NSScreen.mainScreen backingScaleFactor]; }
- (CGPoint)convertPointFromScreen:(CGPoint)p { return p; } - (CGPoint)convertPointToScreen:(CGPoint)p { return p; }
- (BOOL)canBecomeKeyWindow { return YES; } - (BOOL)canBecomeMainWindow { return YES; }
- (BOOL)makeFirstResponder:(NSResponder *)r { if (_firstResponder == r) return YES; [_firstResponder resignFirstResponder]; _firstResponder = r; [r becomeFirstResponder]; return YES; }
- (void)makeKeyAndOrderFront:(id)s {
    MSLogf(@"window makeKeyAndOrderFront");
    _isVisible = YES; MSOnMain(^{
        if (!self->_uiWindow.windowScene) self->_uiWindow.windowScene = MSAppScene();
        [self->_uiWindow makeKeyAndVisible];
        g_gameWin = self; MSTVObserve(); MSTVRoute();
    });
    [self msBecameKey];
}
- (void)orderOut:(id)s { _isVisible = NO; MSOnMain(^{ self->_uiWindow.hidden = YES; }); }
- (void)makeMainWindow { _isMainWindow = YES; ((NSApplication *)NSApp).mainWindow = self; }
- (void)msBecameKey {
    if (_isKeyWindow) return; _isKeyWindow = YES; _isMainWindow = YES; NSApplication *a = NSApp; a.keyWindow = self; a.mainWindow = self;
    if (!_firstResponder) _firstResponder = _contentView;
    NSNotification *n = [NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:self];
    [NSNotificationCenter.defaultCenter postNotification:n];
    if ([_delegate respondsToSelector:@selector(windowDidBecomeKey:)]) ((void (*)(id, SEL, id))objc_msgSend)(_delegate, @selector(windowDidBecomeKey:), n);
    if ([_delegate respondsToSelector:@selector(windowDidBecomeMain:)]) ((void (*)(id, SEL, id))objc_msgSend)(_delegate, @selector(windowDidBecomeMain:), n);
}
- (void)msResignedKey {
    if (!_isKeyWindow) return; _isKeyWindow = NO;
    NSNotification *n = [NSNotification notificationWithName:NSWindowDidResignKeyNotification object:self];
    [NSNotificationCenter.defaultCenter postNotification:n];
    if ([_delegate respondsToSelector:@selector(windowDidResignKey:)]) ((void (*)(id, SEL, id))objc_msgSend)(_delegate, @selector(windowDidResignKey:), n);
}
- (void)msContentResized {
    NSNotification *n = [NSNotification notificationWithName:NSWindowDidResizeNotification object:self];
    [NSNotificationCenter.defaultCenter postNotification:n];
    if ([_delegate respondsToSelector:@selector(windowDidResize:)]) ((void (*)(id, SEL, id))objc_msgSend)(_delegate, @selector(windowDidResize:), n);
}
- (void)toggleFullScreen:(id)sender {
    /* iPadOS apps are always full screen: walk the delegate through the Cocoa full-screen callbacks */
    BOOL enter = !(_styleMask & MSStyleFullScreen);
    SEL will = enter ? NSSelectorFromString(@"windowWillEnterFullScreen:") : NSSelectorFromString(@"windowWillExitFullScreen:");
    SEL did  = enter ? NSSelectorFromString(@"windowDidEnterFullScreen:")  : NSSelectorFromString(@"windowDidExitFullScreen:");
    NSNotification *n = [NSNotification notificationWithName:(enter ? @"NSWindowWillEnterFullScreenNotification" : NSWindowWillExitFullScreenNotification) object:self];
    if ([_delegate respondsToSelector:will]) ((void (*)(id, SEL, id))objc_msgSend)(_delegate, will, n);
    [NSNotificationCenter.defaultCenter postNotification:n];
    _styleMask = enter ? (_styleMask | MSStyleFullScreen) : (_styleMask & ~MSStyleFullScreen);
    MSMainAsync(^{
        if ([self->_delegate respondsToSelector:did]) ((void (*)(id, SEL, id))objc_msgSend)(self->_delegate, did, n);
    });
}
- (void)close {
    NSNotification *n = [NSNotification notificationWithName:NSWindowWillCloseNotification object:self];
    [NSNotificationCenter.defaultCenter postNotification:n];
    if ([_delegate respondsToSelector:@selector(windowWillClose:)]) ((void (*)(id, SEL, id))objc_msgSend)(_delegate, @selector(windowWillClose:), n);
    [self orderOut:nil]; [((NSApplication *)NSApp).windows removeObject:self];
}
- (void)miniaturize:(id)s {} - (void)deminiaturize:(id)s {} - (void)zoom:(id)s {}
@end


/* ---------------------------------------------------------------- TV out (AirPlay screen mirroring, USB-C/HDMI)
 * With a second screen the game's view moves into a window on that screen, scaled to fill it. The phone keeps the
 * touch controls (their own window, on top) and the rest of its screen becomes a touch surface for the cursor
 * (MSTouchIn: the phone screen maps onto the whole picture). Connected before Play: the game renders in the TV's shape
 * (g_tvAspect); connected later, the picture keeps the phone's shape, letterboxed. Unplugging brings it back. The
 * view keeps its bounds (the size AppKit was told), only a transform scales it, so the engine never sees a resize.
 * TVOut = NO in macshim.plist turns this off. */
static UIWindow *g_tvWin; static UIView *g_tvPad;
/* Mirror: every frame the game presents is also copied (one GPU blit, same command queue, right after the game's
   command buffer) into a Metal layer on the phone, so the picture is on both screens. Touches map onto the picture. */
static BOOL MSMirrorFit(UIView *v, CGRect *r) {
    if (!g_mirrorOn || !v) return NO;
    CGSize b = v.bounds.size, d = g_mirrorLayer.drawableSize; double a = d.width > 0 && d.height > 0 ? d.width / d.height : g_sw / g_sh;
    if (b.width < 1 || b.height < 1 || !(a > 0)) return NO;
    double w = b.width, h = w / a; if (h > b.height) { h = b.height; w = h * a; }
    *r = CGRectMake((b.width - w) / 2, (b.height - h) / 2, w, h); return YES;
}
@interface MSTVPadView : UIView @property(strong) UILabel *note; @end
@implementation MSTVPadView
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f]; if (!self) return nil;
    self.multipleTouchEnabled = YES; self.backgroundColor = UIColor.blackColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (MSCfgD(@"TVMirror", 1) != 0) {
        CAMetalLayer *m = [CAMetalLayer layer]; m.device = MTLCreateSystemDefaultDevice(); m.framebufferOnly = NO; m.opaque = YES;
        m.contentsGravity = kCAGravityResizeAspect; m.maximumDrawableCount = 3; m.contentsScale = UIScreen.mainScreen.scale; m.frame = self.bounds;
        [self.layer insertSublayer:m atIndex:0]; g_mirrorLayer = m;
    }
    UILabel *l = [UILabel new]; l.numberOfLines = 2; l.textAlignment = NSTextAlignmentCenter; self.note = l;
    l.text = @"Playing on the external display\nTouch here to move the cursor";
    l.textColor = [UIColor colorWithWhite:1 alpha:0.35]; l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    l.translatesAutoresizingMaskIntoConstraints = NO; [self addSubview:l];
    [l.centerXAnchor constraintEqualToAnchor:self.centerXAnchor].active = YES;
    [l.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor constant:16].active = YES;
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (g_mirrorLayer) { [CATransaction begin]; [CATransaction setDisableActions:YES]; g_mirrorLayer.frame = self.bounds; [CATransaction commit]; }
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e     { [g_hostView msTouches:t phase:0 event:e]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e     { [g_hostView msTouches:t phase:1 event:e]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e     { [g_hostView msTouches:t phase:2 event:e]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [g_hostView msTouches:t phase:2 event:e]; }
@end
static void MSFitHost(UIView *host, UIView *into) {
    double w, h; MacShimScreenInfo(&w, &h, 0, 0);
    if (host.superview != into) [into insertSubview:host atIndex:0];
    host.autoresizingMask = UIViewAutoresizingNone; host.transform = CGAffineTransformIdentity;
    host.bounds = CGRectMake(0, 0, w, h);
    CGSize c = into.bounds.size; CGFloat k = MIN(c.width / w, c.height / h); if (!(k > 0)) k = 1;
    host.center = CGPointMake(c.width / 2, c.height / 2); host.transform = CGAffineTransformMakeScale(k, k);
}
static void MSTVRoute(void) {                                     /* main thread */
    NSWindow *gw = g_gameWin; MSHostView *host = gw.contentView.host; UIView *phone = gw.uiWindow.rootViewController.view;
    if (!host || !phone || MSCfgD(@"TVOut", 1) == 0) return;
    UIScreen *ext = MSExternalScreen();
    if (ext) {
        if (!g_tvWin || g_tvWin.screen != ext) {
            g_tvWin.hidden = YES; g_tvWin = nil;
            UIWindowScene *sc = nil;
            for (UIScene *x in UIApplication.sharedApplication.connectedScenes)
                if ([x isKindOfClass:UIWindowScene.class] && ((UIWindowScene *)x).screen == ext) sc = (UIWindowScene *)x;
            if (sc) g_tvWin = [[UIWindow alloc] initWithWindowScene:sc];
            else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                g_tvWin = [[UIWindow alloc] initWithFrame:ext.bounds]; g_tvWin.screen = ext;     /* no scene for it (yet) */
#pragma clang diagnostic pop
            }
            g_tvWin.backgroundColor = UIColor.blackColor; g_tvWin.userInteractionEnabled = NO;
            g_tvWin.rootViewController = [MSRootVC new]; g_tvWin.rootViewController.view.backgroundColor = UIColor.blackColor;
            g_tvWin.hidden = NO;
            MSLogf(@"TV out: external display %.0fx%.0f pt @%.0fx, %@, game picture %.0fx%.0f moved there", ext.bounds.size.width, ext.bounds.size.height,
                   ext.scale, sc ? @"own scene" : @"no scene (screen property)", g_sw, g_sh);
        }
        UIView *root = g_tvWin.rootViewController.view; root.frame = g_tvWin.bounds;
        MSFitHost(host, root);
        if (!g_tvPad) g_tvPad = [[MSTVPadView alloc] initWithFrame:phone.bounds];
        if (g_tvPad.superview != phone) {
            g_tvPad.frame = phone.bounds; [phone addSubview:g_tvPad];
            if (g_mirrorLayer) {           /* the picture is on the phone too: the note only shows for a moment */
                UILabel *l = ((MSTVPadView *)g_tvPad).note; l.text = @"Also on the external display"; l.alpha = 1;
                MSAfter(4, ^{ [UIView animateWithDuration:0.6 animations:^{ l.alpha = 0; }]; });
                MSLogf(@"TV out: picture mirrored on the phone too");
            }
        }
        g_mirrorOn = g_mirrorLayer != nil;
    } else if (g_tvWin || host.superview != phone || (g_tvAspect > 0 && host.autoresizingMask != UIViewAutoresizingNone)) {
        g_mirrorOn = NO; [g_tvPad removeFromSuperview];
        MSFitHost(host, phone);
        g_tvWin.hidden = YES; g_tvWin = nil;
        MSLogf(@"TV out: external display gone, game back on the phone");
    }
}
static void MSTVObserve(void) {
    static BOOL done; if (done) return; done = YES;
    /* the screen and its scene arrive one after the other; route again shortly after each */
    for (NSString *n in @[ UIScreenDidConnectNotification, UIScreenDidDisconnectNotification, UIScreenModeDidChangeNotification,
                           UISceneWillConnectNotification, UISceneDidDisconnectNotification ])
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *x) {
            MSMainAsync(^{ MSTVRoute(); });
            MSAfter(0.5, ^{ MSTVRoute(); });
        }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *x) {
        if (MSCfgD(@"TVOut", 1) != 0) MSLogf(@"TV out: display connected"); }];
}

@interface NSWindowController : MSBase
@property(nonatomic, strong) NSWindow *window;
- (instancetype)initWithWindow:(NSWindow *)w; - (void)showWindow:(id)s; - (void)windowDidLoad;
@end
@implementation NSWindowController
- (instancetype)initWithWindow:(NSWindow *)w { self = [super init]; _window = w; w.windowController = self; return self; }
- (void)setWindow:(NSWindow *)w { _window = w; w.windowController = self; }
- (void)showWindow:(id)s { [_window makeKeyAndOrderFront:s]; }
- (void)windowDidLoad {} - (void)close { [_window close]; }
@end

/* ---------------------------------------------------------------- NSApplication + UIKit app delegate */
static NSApplication *g_app;
static BOOL g_uikitUp;                          /* UIApplicationMain is already running (MSBootUIKit) */
static void MSBootUIKit(void);
static BOOL MSCalledFromGameMain(void *ret);
@interface MSUIDelegate : UIResponder <UIApplicationDelegate> @property(nonatomic, strong) UIWindow *window; @end

@implementation NSApplication {
    BOOL _active; NSInteger _activationPolicy;
}
- (NSInteger)activationPolicy { return _activationPolicy; }
+ (NSApplication *)sharedApplication {
    /* First thing the game's main() does is [NSApplication sharedApplication]. Its loading (seconds to minutes, all on
       the main thread) used to happen before [NSApp run] started UIKit, so iOS showed nothing and killed the app after
       20 s (0x8BADF00D process-launch). Start UIKit here instead and re-enter main() once launching has finished. */
    if (!g_uikitUp && [NSThread isMainThread] && MSCalledFromGameMain(__builtin_return_address(0))) MSBootUIKit();
    static dispatch_once_t o; dispatch_once(&o, ^{ g_app = [self new]; g_app.windows = [NSMutableArray array]; NSApp = g_app; });
    return g_app;
}
- (BOOL)isActive { return _active; } - (BOOL)isHidden { return NO; } - (BOOL)isRunning { return YES; }
- (BOOL)setActivationPolicy:(NSInteger)p { _activationPolicy = p; return YES; }
- (void)activateIgnoringOtherApps:(BOOL)f {} - (void)stop:(id)s {}
/* The game runs its own loop and calls [NSApp finishLaunching] itself; AppKit answers with the delegate's
 * applicationWill/DidFinishLaunching:. That's where the game registers for controller and mouse connect notifications
 * (-> setupController: installs its gamepad callbacks), its key monitor and a timer. This was an empty stub, so no
 * controller - real or on-screen - and no mouse ever got wired up. Runs once (-run also gets here when UIKit is up). */
- (void)finishLaunching {
    static BOOL done; if (done) return;
    id d = self.delegate; if (!d) { MSLogf(@"finishLaunching before the game set a delegate - later"); return; }
    done = YES;
    MSLogf(@"finishLaunching: calling the game's applicationDidFinishLaunching (delegate %@)", NSStringFromClass([d class]));
    NSNotification *n = [NSNotification notificationWithName:@"NSApplicationDidFinishLaunchingNotification" object:self];
    if ([d respondsToSelector:@selector(applicationWillFinishLaunching:)]) ((void (*)(id, SEL, id))objc_msgSend)(d, @selector(applicationWillFinishLaunching:), n);
    [NSNotificationCenter.defaultCenter postNotificationName:@"NSApplicationWillFinishLaunchingNotification" object:self];
    if ([d respondsToSelector:@selector(applicationDidFinishLaunching:)]) ((void (*)(id, SEL, id))objc_msgSend)(d, @selector(applicationDidFinishLaunching:), n);
    [NSNotificationCenter.defaultCenter postNotification:n];
    MSLogf(@"finishLaunching: done");
} - (void)hide:(id)s {} - (void)unhide:(id)s {} - (void)hideOtherApplications:(id)s {}
- (void)setMainMenu:(id)m { _mainMenu = m; }
- (NSArray *)orderedWindows { return [_windows copy]; }
- (void)terminate:(id)s {
    if ([_delegate respondsToSelector:@selector(applicationWillTerminate:)]) ((void (*)(id, SEL, id))objc_msgSend)(_delegate, @selector(applicationWillTerminate:), nil);
    exit(0);
}
- (void)run {
    if (g_uikitUp) {                            /* UIKit already running: do what MSUIDelegate's launch callback does */
        MSLogf(@"[NSApp run] with UIKit up; entering the game's applicationDidFinishLaunching");
        NSNotification *n = [NSNotification notificationWithName:@"NSApplicationDidFinishLaunchingNotification" object:self];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
            MSMainAsync(^{ [self msBecomeActive:YES]; });     /* delivered on the game's first event poll */
        (void)n; [self finishLaunching];
        for (;;) CFRunLoopRun();
    }
    char **argv = *_NSGetArgv(); int argc = *_NSGetArgc();
    @autoreleasepool { UIApplicationMain(argc, argv, nil, NSStringFromClass([MSUIDelegate class])); }
}
- (NSEvent *)nextEventMatchingMask:(unsigned long long)mask untilDate:(NSDate *)d inMode:(NSString *)mode dequeue:(BOOL)dq {
    /* The game polls this every frame (usually with a past date). Spin the main run loop once so UIKit can deliver
       touches, key presses, display-link and scene callbacks; our input arrives through MSDispatch, so return nil. */
    NSTimeInterval t = d ? [d timeIntervalSinceNow] : 0; if (t < 0) t = 0; if (t > 0.1) t = 0.1;
    if ([NSThread isMainThread]) {
        if (g_inBackground) {
            MSLogf(@"background: game frozen");
            while (g_inBackground) @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false); }
            MSLogf(@"foreground: game continues");
        }
        static BOOL awake; if (!awake) { awake = YES; UIApplication.sharedApplication.idleTimerDisabled = YES; }  /* a controller doesn't count as touching the screen: don't auto-lock mid-game */
        MSLowLatencyWait();
        /* Handle EVERY pending run-loop source, not just one: returnAfterSourceHandled made it one source per game frame,
           so touches queued up behind display-link / timer / block sources and reached the game late - the laggy
           buttons and sticks. Bounded so a flood can't stall the frame. */
        SInt32 rr = CFRunLoopRunInMode(kCFRunLoopDefaultMode, t, true);
        for (int n = 0; rr == kCFRunLoopRunHandledSource && n < 64; n++) rr = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
        {   /* camera swipe: hand the pending movement to the game, at most once per ~frame */
            static double lastFlush, keep = -1; double tn = CACurrentMediaTime();
            if (keep < 0) { keep = MSCfgD(@"LookSmooth", 0.35); if (keep < 0) keep = 0; if (keep > 0.9) keep = 0.9; }
            if (g_lookStick < 0) g_lookStick = ![MSConfig()[@"LookMode"] isEqual:@"mouse"];
            if (g_lookStick && tn - lastFlush > 0.006) { MSLookFlushStick(lastFlush ? tn - lastFlush : 1 / 30.0); lastFlush = tn; }
            else if (!g_lookStick && tn - lastFlush > 0.006) {
                os_unfair_lock_lock(&g_lookLock); CGPoint d = CGPointMake(g_lookPending.x * (1 - keep), g_lookPending.y * (1 - keep));
                if (fabs(g_lookPending.x) < 0.05 && fabs(g_lookPending.y) < 0.05) d = g_lookPending;     /* tail: send the rest */
                g_lookPending.x -= d.x; g_lookPending.y -= d.y; os_unfair_lock_unlock(&g_lookLock);
                if (d.x != 0 || d.y != 0) { MSHostView *h = g_hostView; if (h) [h msMouseDelta:d]; lastFlush = tn; }
            }
            MSGCMouseFlush();
        }
        MSInputReport();
        double now = CACurrentMediaTime();
        if (g_mqAsked > g_mqBeat && now - g_mqAsked > 0.25) {         /* main queue starved: run its blocks here */
            static int n; if (n++ < 3) MSLogf(@"main dispatch queue not serviced for %.1f s - draining it from the game loop", now - g_mqAsked);
            _dispatch_main_queue_callback_4CF(NULL);
        }
        if (now - g_mqAsked > 0.5) { g_mqAsked = now; dispatch_async(dispatch_get_main_queue(), ^{ g_mqBeat = CACurrentMediaTime(); }); }
    }
    else if (t > 0) [NSThread sleepForTimeInterval:t];
    return nil;
}
- (void)postEvent:(NSEvent *)e atStart:(BOOL)a { MSDispatch(e); }
- (void)sendEvent:(NSEvent *)e {
    SEL s = NULL;
    switch (e.type) {
        case MSLDown: s = @selector(mouseDown:); break;          case MSLUp: s = @selector(mouseUp:); break;
        case MSRDown: s = @selector(rightMouseDown:); break;     case MSRUp: s = @selector(rightMouseUp:); break;
        case MSMouseMoved: s = @selector(mouseMoved:); break;    case MSLDrag: s = @selector(mouseDragged:); break;
        case MSRDrag: s = @selector(rightMouseDragged:); break;  case MSEnter: s = @selector(mouseEntered:); break; case MSExit: s = @selector(mouseExited:); break;
        case MSKeyDown: s = @selector(keyDown:); break;          case MSKeyUp: s = @selector(keyUp:); break;
        case MSFlagsChanged: s = @selector(flagsChanged:); break; case MSScroll: s = @selector(scrollWheel:); break;
        case MSODown: s = @selector(otherMouseDown:); break;     case MSOUp: s = @selector(otherMouseUp:); break; case MSODrag: s = @selector(otherMouseDragged:); break;
        default: return;
    }
    NSWindow *w = _keyWindow ?: _windows.firstObject; id t = w.firstResponder ?: w.contentView;
    if (e.type != MSKeyDown && e.type != MSKeyUp && e.type != MSFlagsChanged) {
        /* AppKit sends mouse events to the view under the pointer, not to the first responder (which may be the window) */
        NSView *v = w.contentView, *hit = [v respondsToSelector:s] ? v : nil;
        for (BOOL deeper = YES; deeper && v; ) {
            deeper = NO;
            for (NSView *sub in [v.subviews reverseObjectEnumerator]) if (!sub.isHidden && CGRectContainsPoint(sub.frame, e.locationInWindow)) {
                v = sub; if ([v respondsToSelector:s]) hit = v; deeper = YES; break;
            }
        }
        if (hit) t = hit;
    }
    static int logged; if (logged < 12 && e.type != MSKeyDown && e.type != MSKeyUp && e.type != MSFlagsChanged) { logged++;
        MSLogf(@"event %@ -> %@ (responds %d, window %@, content %@)", NSStringFromSelector(s), NSStringFromClass([t class]), [t respondsToSelector:s], NSStringFromClass([w class]), NSStringFromClass([w.contentView class])); }
    if ([t respondsToSelector:s]) ((void (*)(id, SEL, id))objc_msgSend)(t, s, e);
}
- (void)setDelegate:(id)d {
    _delegate = d;
    /* activation that arrived before the game had a delegate (UIKit boots first) is delivered now */
    if (d && g_activePending) { g_activePending = NO; MSMainAsync(^{ [self msBecomeActive:YES]; }); }
}
- (void)msBecomeActive:(BOOL)a {
    if (a && !_delegate) { g_activePending = YES; MSLogf(@"app active before the game set its delegate - held back"); return; }
    if (!a) g_activePending = NO;
    if (a == _active) return; _active = a; MSLogf(@"game told: app %@ (delegate %@)", a ? @"active" : @"inactive", NSStringFromClass([_delegate class]));
    SEL will = a ? @selector(applicationWillBecomeActive:) : @selector(applicationWillResignActive:);
    SEL did  = a ? @selector(applicationDidBecomeActive:)  : @selector(applicationDidResignActive:);
    NSNotification *n = [NSNotification notificationWithName:(a ? @"NSApplicationDidBecomeActiveNotification" : NSApplicationDidResignActiveNotification) object:self];
    if ([_delegate respondsToSelector:will]) ((void (*)(id, SEL, id))objc_msgSend)(_delegate, will, n);
    for (NSWindow *w in [_windows copy]) { if (a) { if (w == _keyWindow || _windows.count == 1) [w msBecameKey]; } else [w msResignedKey]; }
    [NSNotificationCenter.defaultCenter postNotification:n];
    if ([_delegate respondsToSelector:did]) ((void (*)(id, SEL, id))objc_msgSend)(_delegate, did, n);
}
@end

@implementation MSUIDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    MSLogf(@"UIKit launched; calling the game's applicationDidFinishLaunching");
    NSApplication *a = [NSApplication sharedApplication];
    NSNotification *n = [NSNotification notificationWithName:@"NSApplicationDidFinishLaunchingNotification" object:a];
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *x) {
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidChangeScreenParametersNotification object:a]; }];
    /* The game's applicationDidFinishLaunching: runs the whole game loop on the main thread and never returns (it pumps
       events itself via nextEventMatchingMask:). iOS kills an app whose didFinishLaunching takes > 20 s (0x8BADF00D),
       so let UIKit finish launching first and enter the game on the next turn of the main queue. */
    MSMainAsync(^{
        id d = a.delegate;
        MSLogf(@"entering the game's applicationDidFinishLaunching (delegate %@)", NSStringFromClass([d class]));
        if ([d respondsToSelector:@selector(applicationWillFinishLaunching:)]) ((void (*)(id, SEL, id))objc_msgSend)(d, @selector(applicationWillFinishLaunching:), n);
        if ([d respondsToSelector:@selector(applicationDidFinishLaunching:)])  ((void (*)(id, SEL, id))objc_msgSend)(d, @selector(applicationDidFinishLaunching:), n);
        MSLogf(@"game's applicationDidFinishLaunching returned");
    });
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)app { MSLogf(@"app became active"); MSRefreshScreen(); if (NSApp) [(NSApplication *)NSApp msBecomeActive:YES]; }
- (void)applicationWillResignActive:(UIApplication *)app { [(NSApplication *)NSApp msBecomeActive:NO]; }
- (void)applicationWillTerminate:(UIApplication *)app {
    id d = [(NSApplication *)NSApp delegate];
    if ([d respondsToSelector:@selector(applicationWillTerminate:)]) ((void (*)(id, SEL, id))objc_msgSend)(d, @selector(applicationWillTerminate:), nil);
}
- (UIInterfaceOrientationMask)application:(UIApplication *)a supportedInterfaceOrientationsForWindow:(UIWindow *)w { return UIInterfaceOrientationMaskLandscape; }
@end

/* ---------------------------------------------------------------- keyboard -> NSEvent */
static void MSKey(GCKeyCode code, BOOL pressed) {
    NSNumber *mk = MSKeyMap()[@((NSInteger)code)]; if (!mk) return; unsigned short mac = mk.unsignedShortValue;
    NSUInteger f = MSFlagForMac(mac); NSEvent *e = [NSEvent new]; e.keyCode = mac; e.timestamp = CACurrentMediaTime(); e.locationInWindow = g_mouse;
    if (f) { if (pressed) g_modFlags |= f; else g_modFlags &= ~f; e.type = MSFlagsChanged; }
    else   { e.type = pressed ? MSKeyDown : MSKeyUp; }
    e.modifierFlags = g_modFlags; MSDispatch(e);
}
static void MSAttachKeyboard(GCKeyboard *kb) {
    kb.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *k, GCControllerButtonInput *b, GCKeyCode code, BOOL pressed) { MSKey(code, pressed); };
}
/* hardware mouse through GameController (GCMouse): an iPhone has no UIKit pointer, so this is the only way a mouse reaches
   the game there. Gameplay (pointer locked): relative motion for the camera, sent once per game frame. Menus: moves a
   cursor over the game view (buttons held = drag). Left/right button and the wheel go to the game view. Speed follows
   the start screen's Look sensitivity (its default 1.5 = 1x) times MouseSpeed (plist, default 1). While a GCMouse is
   connected, UIKit pointer events (iPad) are ignored so nothing arrives twice. */
static os_unfair_lock g_gcmLock = OS_UNFAIR_LOCK_INIT;
static CGPoint MSGCMouseAt(MSHostView *h) {
    if (g_pointerLocked) return CGPointMake(h.bounds.size.width / 2, h.bounds.size.height / 2);
    if (!g_gcmCursorSet) { g_gcmCursor = CGPointMake(h.bounds.size.width / 2, h.bounds.size.height / 2); g_gcmCursorSet = YES; }
    return g_gcmCursor;
}
/* menus: the game hides the system cursor and moves its own (blue) cursor by the event's deltaX/deltaY, so every
   menu mouse event carries the motion as well as a position */
static void MSGCMouseMove(MSHostView *h, CGPoint d) {
    CGPoint c = MSGCMouseAt(h);
    c.x = fmin(fmax(c.x + d.x, 0), h.bounds.size.width - 1); c.y = fmin(fmax(c.y + d.y, 0), h.bounds.size.height - 1);
    g_gcmCursor = c; MSOpenMouseGate();
    NSEvent *e = [h msEvent:(g_gcmLeft ? MSLDrag : g_gcmRight ? MSRDrag : MSMouseMoved) at:c];
    double k = MSAKScale(); e.deltaX = d.x * k; e.deltaY = d.y * k;
    MSDispatch(e);
}
/* the game moved the (hidden) system cursor - e.g. centred it for a menu. Its blue cursor is there now, so the shim's
   mouse position (where clicks go) follows. Global display coordinates, top-left origin, AppKit points. */
void MacShimWarpCursor(double x, double y) {
    static int n; if (n++ < 6) MSLogf(@"mouse: game moved the cursor to %.0f,%.0f", x, y);
    MSMainAsync(^{
        MSHostView *h = g_hostView; if (!h) return;
        double k = MSAKScale(); CGPoint c = CGPointMake(x / k, y / k);
        c.x = fmin(fmax(c.x, 0), h.bounds.size.width - 1); c.y = fmin(fmax(c.y, 0), h.bounds.size.height - 1);
        g_gcmCursor = c; g_gcmCursorSet = YES; g_mouse = MSToCocoa(c, h);
    });
}
static void MSGCMouseFlush(void) {
    if (!g_gcmCount) return;
    MSHostView *h = g_hostView; if (!h) return;
    /* AssistiveTouch hands mouse motion over unevenly (often 10-30 times a second), so part of what's pending is kept
       for the next frame to even it out. Time based (MouseSmoothMs, default 10 ms; 0 = off): at 60 FPS ~a third is
       kept, at low FPS (long frames) almost nothing - the game only reads input once per frame, so holding motion back
       on a slow frame was felt as lag. */
    static double tau = -1, last; if (tau < 0) { tau = MSCfgD(@"MouseSmoothMs", 10) / 1000; if (tau < 0) tau = 0; }
    double now = CACurrentMediaTime(), dt = last ? now - last : 1 / 60.0; last = now;
    double keep = tau > 0 ? exp(-dt / tau) : 0;
    os_unfair_lock_lock(&g_gcmLock);
    CGPoint all = g_gcmPending, d = CGPointMake(all.x * (1 - keep), all.y * (1 - keep));
    if (fabs(all.x) < 0.5 && fabs(all.y) < 0.5) d = all;  /* the tail: send the rest */
    g_gcmPending.x -= d.x; g_gcmPending.y -= d.y;
    os_unfair_lock_unlock(&g_gcmLock);
    if (d.x == 0 && d.y == 0) return;
    if (g_pointerLocked) [h msMouseDelta:d]; else MSGCMouseMove(h, d);
}
static _Atomic long long g_gcmClicks; static _Atomic double g_gcmConnectAt;
static void MSGCMouseButton(BOOL right, BOOL down) {
    if (down) g_gcmClicks++;
    BOOL stray = !right && down && CACurrentMediaTime() - g_gcmConnectAt < 0.5;   /* AssistiveTouch's virtual mouse sends a
                                                                                  left-down (never released) as it appears */
    static int n; if (n++ < 10) MSLogf(@"mouse: %@ button %@%@", right ? @"right" : @"left", down ? @"down" : @"up", stray ? @" (stray, ignored)" : @"");
    if (stray) return;
    if (!right) { MSMainAsync(^{ MSLeftPress(2, down); }); return; }
    MSMainAsync(^{
        MSHostView *h = g_hostView; if (!h) return;
        MSGCMouseFlush();                                     /* motion first, so the click lands where the cursor is */
        if (down) g_gcmButtonAt = CACurrentMediaTime();
        if (right) g_gcmRight = down; else g_gcmLeft = down;
        MSOpenMouseGate(); [h msButton:down right:right at:MSGCMouseAt(h)];
    });
}
static void MSAttachMouse(GCMouse *m) {
    GCMouseInput *in = m.mouseInput; if (!in) return;
    g_gcmCount++; g_gcmConnectAt = CACurrentMediaTime();
    static dispatch_queue_t q; if (!q) q = dispatch_queue_create("cyport.mouse", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    m.handlerQueue = q;                                    /* handlers run at once, off the busy main thread */
    static double speed; if (!speed) speed = MSCfgD(@"MouseSpeed", 1.0);
    in.mouseMovedHandler = ^(GCMouseInput *mi, float dx, float dy) {
        double k = speed * MSLookSensitivity() / 1.5;
        g_gcmMoves++; g_gcmLastMoveAt = CACurrentMediaTime();
        static int logged; if (logged++ < 3) MSLogf(@"mouse: motion %+.1f %+.1f", dx, dy);
        os_unfair_lock_lock(&g_gcmLock); g_gcmPending.x += dx * k; g_gcmPending.y -= dy * k; os_unfair_lock_unlock(&g_gcmLock);   /* GC: +y is up */
    };
    in.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) { MSGCMouseButton(NO, pressed); };
    in.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) { MSGCMouseButton(YES, pressed); };
    in.scroll.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
        if (x == 0 && y == 0) return;
        MSMainAsync(^{ MSHostView *h = g_hostView; if (h) { MSOpenMouseGate(); [h msScrollBy:CGPointMake(x * 10, y * 10) at:MSGCMouseAt(h)]; } });
    };
    MacShimSetPointerLocked(g_pointerLocked);                 /* re-evaluates prefersPointerLocked */
    MSLogf(@"mouse connected: %@ (GameController) - touch controls hidden while it's connected", m.vendorName ?: @"mouse");
}
static void MSDispatch(NSEvent *e) {
    NSArray *ms; @synchronized (g_monitors) { ms = [g_monitors copy]; }
    for (MSMonitor *m in ms) if (m.mask & (1ULL << e.type)) {
        NSEvent *in = e; e = m.handler(e);
        if (!e) { static int n; if (n++ < 12) MSLogf(@"event type %lu swallowed by the game's event monitor", (unsigned long)in.type); return; }
    }
    [(NSApplication *)NSApp sendEvent:e];
}

/* ---------------------------------------------------------------- Metal: macOS-only multi-GPU observer API (iPad has exactly one GPU) */
NSArray<id<MTLDevice>> *MTLCopyAllDevicesWithObserver(id<NSObject> __autoreleasing *observer, void (^handler)(id<MTLDevice>, NSString *)) {
    if (observer) *observer = [NSObject new];
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); return d ? @[ d ] : @[];
}
void MTLRemoveDeviceObserver(id<NSObject> observer) {}

/* ---------------------------------------------------------------- data folder + Mac-like system values (dyld interpose) */
/* The retargeting tool re-points the game's imports of _NSGetExecutablePath and _sysctlbyname at the two functions below. */

static NSString *const kBookmarkKey = @"MacShimDataBookmark2";      /* "play from SSD" choice */
static NSString *const kImportSrcKey = @"MacShimImportSource";       /* folder being imported, to resume */
static NSString *g_root; static NSURL *g_scopedURL; static BOOL g_external, g_hadBookmark;

static BOOL MSLooksLikeGameFolder(NSString *p) {
    NSFileManager *fm = NSFileManager.defaultManager; BOOL isDir = NO;
    for (NSString *n in @[ @"archive", @"engine", @"r6" ])
        if (![fm fileExistsAtPath:[p stringByAppendingPathComponent:n] isDirectory:&isDir] || !isDir) return NO;
    return YES;
}
static NSString *MSInternalRoot(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Cyberpunk 2077"];
}
/* an import writes here and is renamed to MSInternalRoot() only once every file is complete */
static NSString *MSImportRoot(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Cyberpunk 2077 (importing)"];
}
/* the saved external folder with access started, or nil while it can't be reached (SSD unplugged / still mounting) */
static NSURL *MSResolveBookmarkKey(NSString *key) {
    NSData *bm = [NSUserDefaults.standardUserDefaults dataForKey:key]; if (!bm) return nil;
    BOOL stale = NO; NSURL *u = [NSURL URLByResolvingBookmarkData:bm options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
    if (!u) return nil;
    [u startAccessingSecurityScopedResource];             /* keep access for the whole session */
    if (!MSLooksLikeGameFolder(u.path)) { [u stopAccessingSecurityScopedResource]; return nil; }
    if (stale) { NSData *nb = [u bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil]; if (nb) [NSUserDefaults.standardUserDefaults setObject:nb forKey:key]; }
    return u;
}
static NSURL *MSResolveBookmark(void) { return MSResolveBookmarkKey(kBookmarkKey); }
static NSString *MSDataRoot(void) {            /* nil => setup screen (import / pick SSD folder) */
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        g_hadBookmark = [NSUserDefaults.standardUserDefaults dataForKey:kBookmarkKey] != nil;
        /* a copy in the app's own Documents (imported, or copied in with the Files app) wins: no drive to drop off the bus */
        if (MSLooksLikeGameFolder(MSInternalRoot())) { g_root = MSInternalRoot(); return; }
        if ([NSFileManager.defaultManager fileExistsAtPath:MSImportRoot()]) return;     /* unfinished import: setup resumes it */
        /* right after the SSD is plugged in (or re-enumerates) iOS needs a few seconds to mount it */
        for (int i = 0; g_hadBookmark && i < 16; i++) {
            NSURL *u = MSResolveBookmark();
            if (u) { g_scopedURL = u; g_root = u.path; g_external = YES; break; }
            usleep(500000);
        }
    });
    return g_root;
}
static NSDictionary *MSConfig(void) {
    static NSDictionary *c; static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSString *p = [(MSDataRoot() ?: MSInternalRoot()) stringByAppendingPathComponent:@"macshim.plist"];
        c = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!c) c = [NSDictionary dictionaryWithContentsOfFile:[MSInternalRoot() stringByAppendingPathComponent:@"macshim.plist"]] ?: @{};
    });
    return c;
}

/* ---- first-run screen: import the game into the app (copy), or play it from a folder on an external SSD ---- */
static uint64_t MSFreeBytes(NSString *path) {
    NSDictionary *v = [[NSURL fileURLWithPath:path] resourceValuesForKeys:@[ NSURLVolumeAvailableCapacityForImportantUsageKey ] error:nil];
    NSNumber *n = v[NSURLVolumeAvailableCapacityForImportantUsageKey];
    if (n.longLongValue > 0) return n.unsignedLongLongValue;
    return [[NSFileManager.defaultManager attributesOfFileSystemForPath:path error:nil][NSFileSystemFreeSize] unsignedLongLongValue];
}
static NSString *MSGB(uint64_t b) { return [NSString stringWithFormat:@"%.1f GB", b / 1e9]; }

@interface MSSetupVC : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic, strong) UILabel *info, *status; @property(nonatomic, strong) UIProgressView *bar;
@property(nonatomic, strong) UIButton *importBtn, *ssdBtn, *storeBtn; @property(nonatomic) BOOL pickForSSD, copying;
@end
@implementation MSSetupVC
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
    UILabel *title = [UILabel new]; title.text = @"CyPort"; title.font = [UIFont boldSystemFontOfSize:30]; title.textColor = UIColor.whiteColor;
    _info = [UILabel new]; _info.numberOfLines = 0; _info.textColor = [UIColor colorWithWhite:0.8 alpha:1]; _info.font = [UIFont systemFontOfSize:17];
    _importBtn = [UIButton buttonWithType:UIButtonTypeSystem]; _importBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [_importBtn addTarget:self action:@selector(importTapped) forControlEvents:UIControlEventTouchUpInside];
    _ssdBtn = [UIButton buttonWithType:UIButtonTypeSystem]; [_ssdBtn setTitle:@"Play from the SSD instead (no copy)…" forState:UIControlStateNormal];
    _ssdBtn.titleLabel.font = [UIFont systemFontOfSize:15]; [_ssdBtn addTarget:self action:@selector(ssdTapped) forControlEvents:UIControlEventTouchUpInside];
    _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault]; _bar.hidden = YES;
    _status = [UILabel new]; _status.numberOfLines = 0; _status.textColor = UIColor.systemOrangeColor; _status.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
    /* sign in to Steam / GOG / Epic and download the game data (shim/StoresUI.swift) */
    _storeBtn = [UIButton buttonWithType:UIButtonTypeSystem]; _storeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [_storeBtn setTitle:@"Download from Steam, GOG or Epic…" forState:UIControlStateNormal];
    [_storeBtn addTarget:self action:@selector(storeTapped) forControlEvents:UIControlEventTouchUpInside];
    _storeBtn.hidden = NSClassFromString(@"MSStoreUI") == nil;
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[ title, _info, _storeBtn, _importBtn, _bar, _status ]];   /* no "play from SSD": import only */
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 20; st.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor], [st.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [st.widthAnchor constraintLessThanOrEqualToConstant:560], [st.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24] ]];
    BOOL resume = [NSFileManager.defaultManager fileExistsAtPath:MSImportRoot()];
    _info.text = resume
        ? @"The game import didn't finish. Plug in the SSD and tap Continue - files that are already copied are skipped."
        : @"Download the game from the store you bought it on (Steam, GOG or Epic), or import it: pick the \"Cyberpunk 2077\" folder (with archive, engine and r6 inside), e.g. on your SSD. "
          @"It is copied to this iPhone (about 61 GB). Keep the app open while it copies.\n\n"
          @"You can also copy the \"Cyberpunk 2077\" folder yourself with the Files app into On My iPhone > this app.";
    [_importBtn setTitle:resume ? @"Continue import" : @"Import game…" forState:UIControlStateNormal];
}
- (void)importTapped {
    if (_copying) return;
    NSURL *src = [NSFileManager.defaultManager fileExistsAtPath:MSImportRoot()] ? MSResolveBookmarkKey(kImportSrcKey) : nil;
    if (src) { [self startImportFrom:src]; return; }      /* resume without asking again */
    _pickForSSD = NO; [self pick];
}
- (void)storeTapped {
    if (_copying) return;
    Class c = NSClassFromString(@"MSStoreUI"); if (!c) return;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    UIViewController *vc = ((UIViewController *(*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(c,
        NSSelectorFromString(@"makeWithDownloadRoot:internalRoot:bookmarkKey:"),
        [docs stringByAppendingPathComponent:@"Cyberpunk 2077 (downloading)"], MSInternalRoot(), kBookmarkKey);
    MSLogf(@"store screen opened");
    [self presentViewController:vc animated:YES completion:nil];
}
- (void)ssdTapped { if (!_copying) { _pickForSSD = YES; [self pick]; } }
- (void)pick {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ]];
    p.delegate = self; p.allowsMultipleSelection = NO; [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject; if (!u) return; [u startAccessingSecurityScopedResource];
    if (!MSLooksLikeGameFolder(u.path)) {
        NSString *sub = [u.path stringByAppendingPathComponent:@"Cyberpunk 2077"];     /* user picked the parent by mistake */
        if (MSLooksLikeGameFolder(sub)) u = [NSURL fileURLWithPath:sub isDirectory:YES];
        else { _status.text = @"That folder doesn't contain archive, engine and r6. Pick the \"Cyberpunk 2077\" folder itself."; [u stopAccessingSecurityScopedResource]; return; }
    }
    NSError *e = nil; NSData *bm = [u bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&e];
    if (!_pickForSSD) {
        if (bm) [NSUserDefaults.standardUserDefaults setObject:bm forKey:kImportSrcKey];
        [self startImportFrom:u]; return;
    }
    if (!bm) { _status.text = [NSString stringWithFormat:@"Couldn't remember that folder: %@", e.localizedDescription]; return; }
    [NSUserDefaults.standardUserDefaults setObject:bm forKey:kBookmarkKey]; [NSUserDefaults.standardUserDefaults synchronize];
    [self done:@"Folder saved" msg:@"Open the app again to start the game."];
}
- (void)done:(NSString *)t msg:(NSString *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { exit(0); }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)ui:(void (^)(void))b { MSMainAsync(b); }
- (void)startImportFrom:(NSURL *)src {
    _copying = YES; _importBtn.enabled = NO; _ssdBtn.hidden = YES; _bar.hidden = NO; _status.textColor = UIColor.lightGrayColor;
    _status.text = @"Scanning the game folder…";
    UIApplication.sharedApplication.idleTimerDisabled = YES;              /* screen lock would suspend the copy */
    NSString *from = src.path, *to = MSImportRoot();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = [self copyFrom:from to:to];
        [self ui:^{
            self.copying = NO; UIApplication.sharedApplication.idleTimerDisabled = NO;
            if (!err) { [self done:@"Game imported" msg:@"Open the app again to start the game. You can unplug the SSD."]; return; }
            self.status.textColor = UIColor.systemOrangeColor; self.status.text = err;
            self.importBtn.enabled = YES; [self.importBtn setTitle:@"Continue import" forState:UIControlStateNormal];
        }];
    });
}
/* returns nil on success, else a message for the user; resumable: complete files are skipped, partial ones appended */
- (NSString *)copyFrom:(NSString *)from to:(NSString *)to {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *rel = [NSMutableArray array]; NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    uint64_t total = 0, have = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:from];
    for (NSString *r in en) {
        if ([r.lastPathComponent isEqualToString:@".DS_Store"] || [r.lastPathComponent hasPrefix:@"._"]) continue;
        NSDictionary *a = en.fileAttributes;
        if (![a.fileType isEqualToString:NSFileTypeRegular]) continue;
        uint64_t sz = a.fileSize; [rel addObject:r]; [sizes addObject:@(sz)]; total += sz;
        NSDictionary *d = [fm attributesOfItemAtPath:[to stringByAppendingPathComponent:r] error:nil];
        if (d) have += MIN(d.fileSize, sz);
    }
    if (!rel.count) return @"Couldn't read the game folder. Is the SSD still plugged in?";
    uint64_t freeB = MSFreeBytes(NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject);
    if (total - have > freeB)                  /* no margin: iOS frees purgeable space as we write, and ENOSPC below stops cleanly + resumes */
        return [NSString stringWithFormat:@"Not enough space on this iPhone: the game needs %@ more, only %@ free.", MSGB(total - have), MSGB(freeB)];
    MSLogf(@"import: %lu files, %.1f GB, %.1f GB already there", (unsigned long)rel.count, total / 1e9, have / 1e9);
    [fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:nil];

    const size_t CH = 8 << 20; char *buf = malloc(CH);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent(), lastUI = 0; uint64_t start = have; NSString *err = nil;
    for (NSUInteger i = 0; i < rel.count && !err; i++) @autoreleasepool {
        NSString *s = [from stringByAppendingPathComponent:rel[i]], *d = [to stringByAppendingPathComponent:rel[i]];
        uint64_t sz = sizes[i].unsignedLongLongValue;
        uint64_t off = [[fm attributesOfItemAtPath:d error:nil] fileSize];
        if (off == sz && [fm fileExistsAtPath:d]) continue;
        if (off > sz) { [fm removeItemAtPath:d error:nil]; have -= sz; off = 0; }
        [fm createDirectoryAtPath:d.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        int in = open(s.fileSystemRepresentation, O_RDONLY), out = open(d.fileSystemRepresentation, O_WRONLY | O_CREAT, 0644);
        if (in < 0 || out < 0) { err = [NSString stringWithFormat:@"Couldn't open %@ (%s). Is the SSD still plugged in?", rel[i].lastPathComponent, strerror(errno)]; }
        else {
            fcntl(in, F_NOCACHE, 1); fcntl(out, F_NOCACHE, 1);
            lseek(in, off, SEEK_SET); lseek(out, off, SEEK_SET);
            while (off < sz) {
                ssize_t n = read(in, buf, (size_t)MIN((uint64_t)CH, sz - off));
                if (n <= 0) { err = [NSString stringWithFormat:@"Reading %@ failed (%s) - the SSD probably disconnected. Plug it back in and tap Continue.", rel[i].lastPathComponent, n < 0 ? strerror(errno) : "end of file"]; break; }
                ssize_t w = 0; while (w < n) { ssize_t k = write(out, buf + w, n - w); if (k <= 0) break; w += k; }
                if (w < n) { err = [NSString stringWithFormat:@"Writing failed (%s). Is the iPhone full?", strerror(errno)]; break; }
                off += n; have += n;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastUI > 0.5) {
                    lastUI = now; double rate = (have - start) / MAX(now - t0, 0.1);
                    int eta = rate > 0 ? (int)((total - have) / rate) : 0;
                    NSString *t = [NSString stringWithFormat:@"%@ of %@  ·  %.0f MB/s  ·  %d min left\n%@", MSGB(have), MSGB(total), rate / 1e6, eta / 60 + 1, rel[i].lastPathComponent];
                    float p = (float)((double)have / total);
                    [self ui:^{ self.status.text = t; self.bar.progress = p; }];
                }
            }
        }
        if (in >= 0) close(in);
        if (out >= 0) { fsync(out); close(out); }
    }
    free(buf);
    if (err) { MSLogf(@"import stopped: %@", err); return err; }
    NSError *e = nil;
    if ([fm fileExistsAtPath:MSInternalRoot()]) [fm removeItemAtPath:MSInternalRoot() error:nil];      /* incomplete leftovers */
    if (![fm moveItemAtPath:to toPath:MSInternalRoot() error:&e]) return [NSString stringWithFormat:@"Couldn't finish: %@", e.localizedDescription];
    [@"ok\n" writeToFile:[MSInternalRoot() stringByAppendingPathComponent:@".copy-complete"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kImportSrcKey];
    MSLogf(@"import complete");
    return nil;
}
- (BOOL)prefersStatusBarHidden { return YES; }
@end
@interface MSSetupDelegate : UIResponder <UIApplicationDelegate> @property(nonatomic, strong) UIWindow *window; @end
@implementation MSSetupDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController = [MSSetupVC new]; [self.window makeKeyAndVisible]; return YES;
}
@end
static void MSRunSetup(void) {                  /* replaces the game's startup; the user reopens the app afterwards */
    MSLogf(@"showing first-run folder picker");
    int argc = *_NSGetArgc(); char **argv = *_NSGetArgv();
    @autoreleasepool { UIApplicationMain(argc, argv, nil, NSStringFromClass([MSSetupDelegate class])); }
    exit(0);
}
/* ---- UIKit first, game second ---- */
static void *g_gameMain;                        /* main() of the game, from LC_MAIN */
static BOOL MSCalledFromGameMain(void *ret) {
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(0);
        const struct load_command *lc = (const struct load_command *)(h + 1);
        for (uint32_t i = 0; i < h->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize))
            if (lc->cmd == LC_MAIN) g_gameMain = (char *)h + ((const struct entry_point_command *)lc)->entryoff;
    });
    return g_gameMain && (char *)ret >= (char *)g_gameMain && (char *)ret < (char *)g_gameMain + 0x80;
}
@interface MSBootVC : UIViewController @end
@implementation MSBootVC
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
    UILabel *l = [UILabel new]; l.text = @"Loading…"; l.textColor = [UIColor colorWithWhite:0.7 alpha:1]; l.font = [UIFont systemFontOfSize:17];
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    sp.color = UIColor.whiteColor; [sp startAnimating];
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[ sp, l ]]; st.axis = UILayoutConstraintAxisVertical; st.spacing = 12;
    st.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:st];
    [NSLayoutConstraint activateConstraints:@[ [st.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor], [st.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor] ]];
}
- (BOOL)prefersStatusBarHidden { return YES; }
@end
/* call main(argc, argv, envp, NULL) with sp = stackTop; restores sp afterwards */
static int MSMainTrampoline(void *gameMain) {
    return ((int (*)(int, char **, char **, const char **))gameMain)(*_NSGetArgc(), *_NSGetArgv(), *_NSGetEnviron(), NULL);
}
int MSSwitchStack(void *arg, void *top, int (*fn)(void *));
__asm__(".text\n.p2align 2\n.globl _MSSwitchStack\n_MSSwitchStack:\n"
        "  stp x29, x30, [sp, #-32]!\n  str x19, [sp, #16]\n  mov x29, sp\n"
        "  mov x19, sp\n  mov sp, x1\n  blr x2\n  mov sp, x19\n"
        "  ldr x19, [sp, #16]\n  ldp x29, x30, [sp], #32\n  ret\n");
static int MSCallOnStack(void *top, void *gameMain) { return MSSwitchStack(gameMain, (void *)((uintptr_t)top & ~(uintptr_t)15), MSMainTrampoline); }

/* ---------------------------------------------------------------- start screen: resolution + Play
 * The game no longer starts by itself: this screen comes first. Resolution = render size offered to the game as the
 * display mode (screen size x 1, 1.5, 2 or 3 = native) and written into its UserSettings.json; dynamic resolution is
 * the game's own DRS (it renders at 50-65 % of the resolution while on). Choices are kept in NSUserDefaults. */
static const double g_modeScales[] = { 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3 };
#define MS_NMODES 8
#define MS_DEFAULT_MODE 3                                  /* 1.5x = 1434x660 on a 16 Pro Max (first run: low settings) */
int MacShimModeCount(void) { return MS_NMODES; }
double MacShimModeScale(int i) { return i >= 0 && i < MS_NMODES ? g_modeScales[i] : 1; }
int MacShimCurrentMode(void) {
    NSNumber *n = MSConfig()[@"ResMode"] ?: [NSUserDefaults.standardUserDefaults objectForKey:@"MacShimResMode2"];   /* plist override for tests */
    int i = n ? n.intValue : MS_DEFAULT_MODE; return i >= 0 && i < MS_NMODES ? i : MS_DEFAULT_MODE;
}
static NSString *MSModeName(int i) {
    double w, h; MacShimScreenInfo(&w, &h, 0, 0);
    return [NSString stringWithFormat:@"%zux%zu", (size_t)(w * g_modeScales[i] + 0.5), (size_t)(h * g_modeScales[i] + 0.5)];   /* rounded like the game */
}
/* start-screen choices (NSUserDefaults) */
static NSArray *g_upscalers, *g_upQuality, *g_fpsChoices;
static NSInteger MSPref(NSString *k, NSInteger def) { NSNumber *n = [NSUserDefaults.standardUserDefaults objectForKey:k]; return n ? n.integerValue : def; }
static void MSInitChoices(void) {
    static dispatch_once_t o; dispatch_once(&o, ^{
        g_upscalers = @[ @"Off", @"FSR2", @"FSR3", @"MetalFX" ];
        g_upQuality = @[ @"Auto", @"Quality", @"Balanced", @"Performance" ];
        g_fpsChoices = @[ @30, @40, @60 ];
    });
}
/* set a UserSettings.json option: value, and index when the option lists its values */
static void MSSetOpt(NSMutableDictionary *o, id value) {
    o[@"value"] = value;
    NSArray *vals = o[@"values"];
    if ([vals isKindOfClass:NSArray.class] && [value isKindOfClass:NSString.class]) { NSUInteger k = [vals indexOfObject:value]; if (k != NSNotFound) o[@"index"] = @(k); }
}
/* keys: which start-screen choices to write ("up" "q" "fps" "fg" "drs"; nil = all). The resolution is always written
   (the game is offered only that mode). Everything else stays as the game saved it, so in-game settings survive a
   restart. First run (no UserSettings.json yet): the bundled DefaultUserSettings.json (every graphics option at its
   lowest) is copied in first and all choices are written. */
/* text edit of one option in UserSettings.json: its "value" (and "index" when >= 0); value nil = only read. NO if the
   option or its value isn't there. The current value is returned through `was`. */
static BOOL MSTextSetOption(NSMutableString *txt, NSString *name, NSString *value, NSInteger index, NSString **was) {
    NSRange nr = [txt rangeOfString:[NSString stringWithFormat:@"\"name\"\\s*:\\s*\"%@\"", name] options:NSRegularExpressionSearch];
    if (nr.location == NSNotFound) return NO;
    NSRange open = [txt rangeOfString:@"{" options:NSBackwardsSearch range:NSMakeRange(0, nr.location)];
    NSRange close = [txt rangeOfString:@"}" options:0 range:NSMakeRange(nr.location, txt.length - nr.location)];
    if (open.location == NSNotFound || close.location == NSNotFound) return NO;
    NSRange obj = NSMakeRange(open.location, close.location - open.location + 1);
    NSRegularExpression *vre = [NSRegularExpression regularExpressionWithPattern:@"(\"value\"\\s*:\\s*\")([^\"]*)(\")" options:0 error:nil];
    NSTextCheckingResult *vm = [vre firstMatchInString:txt options:0 range:obj];
    if (!vm) return NO;
    if (was) *was = [txt substringWithRange:[vm rangeAtIndex:2]];
    if (!value) return YES;
    if (index >= 0) {                                          /* the index first: it sits after the value, ranges stay valid */
        NSRegularExpression *ire = [NSRegularExpression regularExpressionWithPattern:@"(\"index\"\\s*:\\s*)(\\d+)" options:0 error:nil];
        NSTextCheckingResult *im = [ire firstMatchInString:txt options:0 range:obj];
        if (im && [im rangeAtIndex:2].location > [vm rangeAtIndex:2].location) [txt replaceCharactersInRange:[im rangeAtIndex:2] withString:[NSString stringWithFormat:@"%ld", (long)index]];
    }
    [txt replaceCharactersInRange:[vm rangeAtIndex:2] withString:value];
    return YES;
}
/* ---------------------------------------------------------------- frame pacing
 * The frame rate is the game's own setting (Settings > Graphics: VSync / Maximum FPS). macshim.plist FrameRate = 30 / 40 / 60
 * makes CyPort hold it instead (a test aid).
 * 30/40/60 are whole multiples of the 120 Hz ProMotion refresh (4/3/2 refreshes), so every frame stays on screen
 * equally long - an uncapped 45-55 FPS looks less smooth than a steady 40 and heats the phone up faster.
 * Two parts: the game's render thread is held to the beat in nextDrawable (a frame limiter: less CPU/GPU work, less
 * heat), and each present asks Metal to keep the previous frame up for one beat (even frame times on the display). */
static _Atomic double g_paceT;                      /* seconds per frame CyPort holds the game to, 0 = not pacing */
static int g_paceMode = -1;                         /* 0 game, 1 auto, 30/40/60 fixed */
static _Atomic int g_paceFPS;                       /* what g_paceT means, for the overlay/log */
static int MSFrameRateChoice(void) {
    id c = MSConfig()[@"FrameRate"]; return [c respondsToSelector:@selector(intValue)] ? [c intValue] : 0;
}
static void MSPaceSet(int fps, NSString *why) {
    double t = fps > 0 ? 1.0 / fps : 0; if (t == g_paceT) return;
    g_paceT = t; g_paceFPS = fps;
    MSLogf(@"frame pacing: %@ (%@)", fps > 0 ? [NSString stringWithFormat:@"%d FPS", fps] : @"off", why);
}
static void MSPaceWait(void) {                      /* nextDrawable, on the game's render thread */
    double T = g_paceT; static __thread uint64_t next;
    if (T <= 0) { next = 0; return; }
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    uint64_t per = (uint64_t)(T * 1e9 * tb.denom / tb.numer), early = (uint64_t)(0.0007 * 1e9 * tb.denom / tb.numer);
    uint64_t now = mach_absolute_time();
    if (!next || now > next + per) next = now;      /* first frame, or more than a frame late: new beat from now */
    else if (now + early < next) mach_wait_until(next - early);
    next += per;
}

/* unquoted values (bool/int): "value": true / "value": 30 */
static BOOL MSTextSetRaw(NSMutableString *txt, NSString *name, NSString *value, NSString **was) {
    NSRange nr = [txt rangeOfString:[NSString stringWithFormat:@"\"name\"\\s*:\\s*\"%@\"", name] options:NSRegularExpressionSearch];
    if (nr.location == NSNotFound) return NO;
    NSRange open = [txt rangeOfString:@"{" options:NSBackwardsSearch range:NSMakeRange(0, nr.location)];
    NSRange close = [txt rangeOfString:@"}" options:0 range:NSMakeRange(nr.location, txt.length - nr.location)];
    if (open.location == NSNotFound || close.location == NSNotFound) return NO;
    NSRegularExpression *vre = [NSRegularExpression regularExpressionWithPattern:@"(\"value\"\\s*:\\s*)([^,\\s}\"]+)" options:0 error:nil];
    NSTextCheckingResult *vm = [vre firstMatchInString:txt options:0 range:NSMakeRange(open.location, close.location - open.location + 1)];
    if (!vm) return NO;
    NSString *old = [txt substringWithRange:[vm rangeAtIndex:2]]; if (was) *was = old;
    if (!value || [old isEqualToString:value]) return NO;
    [txt replaceCharactersInRange:[vm rangeAtIndex:2] withString:value]; return YES;
}
/* at Play: pick the pacing mode and set the game's own frame limiter to match (it sleeps early in the frame, which
   keeps input latency low; CyPort's limiter only steps in below it, e.g. Auto dropping to 30). Frame generation
   presents made-up frames in between, so with it on CyPort leaves pacing to the game. */
static BOOL MSApplyFrameRate(NSMutableString *txt) {
    int c = MSFrameRateChoice(); if (c != 30 && c != 40 && c != 60) c = 0;
    NSString *fg = nil, *fg3 = nil; MSTextSetOption(txt, @"FrameGeneration", nil, -1, &fg); MSTextSetRaw(txt, @"FSR3_FrameGeneration", nil, &fg3);
    BOOL frameGen = (fg && ![fg isEqualToString:@"Off"]) || [fg3 isEqualToString:@"true"];
    if (frameGen && c) { MSLogf(@"frame rate: frame generation is on - pacing left to the game"); c = 0; }
    g_paceMode = c;
    if (!c) { MSPaceSet(0, @"the game's own setting"); return NO; }
    BOOL ch = MSTextSetRaw(txt, @"MaximumFPS_OnOff", @"true", NULL);
    ch |= MSTextSetRaw(txt, @"MaximumFPS_Value", [NSString stringWithFormat:@"%d", c], NULL);
    MSPaceSet(c, @"macshim.plist FrameRate");
    return ch;
}
/* ---------------------------------------------------------------- open-world streaming (engine/config/platform/mac/user.ini)
 * The engine streams the city in on the game thread: by default up to 12 ms and 300 nodes per frame (Streaming/
 * TimeLimitStreamedPerFrame, MaxNodesPerFrame - defaults read from the exe's config table at 0x106b47af0). Tuned for a
 * desktop CPU; on a phone (throttled, at 30 FPS = 33 ms per frame) that much in one frame is the FPS drop you see while
 * driving. Spread over more frames instead: steadier frame times, things appear a little later. Loading screens keep
 * the engine's own limits. The file is CyPort's while its first line says so; StreamingTweaks = NO removes it. */
static void MSWriteStreamingIni(void) {
    NSString *root = g_root; if (!root) return;
    NSString *dir = [root stringByAppendingPathComponent:@"engine/config/platform/mac"], *p = [dir stringByAppendingPathComponent:@"user.ini"];
    NSString *mark = @"; CyPort performance settings";
    NSString *old = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (old && ![old hasPrefix:mark]) { MSLogf(@"streaming: %@ is the user's own - left alone", p.lastPathComponent); return; }
    if ([MSConfig()[@"StreamingTweaks"] isEqual:@NO]) { if (old) [NSFileManager.defaultManager removeItemAtPath:p error:nil]; MSLogf(@"streaming: engine defaults (StreamingTweaks = NO)"); return; }
    double ms = MSCfgD(@"StreamingMsPerFrame", 6); long nodes = (long)MSCfgD(@"StreamingNodesPerFrame", 200);
    NSString *ini = [NSString stringWithFormat:@"%@ (written by CyPort at every start - delete this line to keep your own edits)\n"
                     "; engine defaults 12 ms / 300 nodes per frame; spread over more frames for steadier FPS in the open world\n"
                     "[Streaming]\nTimeLimitStreamedPerFrame = %.1f\nMaxNodesPerFrame = %ld\n", mark, ms, nodes];
    if ([old isEqualToString:ini]) return;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if ([ini writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) MSLogf(@"streaming: at most %.1f ms and %ld nodes per frame (user.ini)", ms, nodes);
    else MSLogf(@"streaming: could not write %@", p);
}
/* ---------------------------------------------------------------- steady 30 (the game's dynamic resolution)
 * Hot, the A18 Pro's GPU slows to ~1/3 of its cool speed: at a fixed MetalFX Performance (50 %) the city then takes
 * 30-40 ms of GPU per frame and drops under 30. The engine's own DRS lowers the render size every frame to hold its
 * target FPS - but the Mac build's menu stops it at 50 %, exactly where Performance already is, so it could only make
 * things heavier. Its options.json limit goes down to 25 % (DRSMinLimit), and once (CyPortSteady30) the settings are
 * set to: MetalFX Dynamic, DRS on, target 30 FPS, 35-50 % (DRSMin / DRSMax). Never above Performance (60 % made the GPU
 * hotter while the CPU was the limit, and DRS only lowers it when the GPU is); MetalFX refuses input under 1/3 of output. Changed later in the game's menu, the player's choice stays.
 * Steady30 = NO leaves all of it alone. */
static void MSPatchDRSRange(void) {
    NSString *root = g_root; if (!root) return;
    NSString *p = [root stringByAppendingPathComponent:@"r6/config/settings/platform/mac/options.json"];
    NSMutableString *t = [NSMutableString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil]; if (!t) return;
    int lim = (int)MSCfgD(@"DRSMinLimit", 25); if (lim < 10) lim = 10; if (lim > 50) lim = 50;
    NSRange nr = [t rangeOfString:@"\"name\"\\s*:\\s*\"DRS_MinResolution\"" options:NSRegularExpressionSearch]; if (nr.location == NSNotFound) return;
    NSRange close = [t rangeOfString:@"}" options:0 range:NSMakeRange(nr.location, t.length - nr.location)]; if (close.location == NSNotFound) return;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\"min_value\"\\s*:\\s*)(\\d+)" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:t options:0 range:NSMakeRange(nr.location, close.location - nr.location)]; if (!m) return;
    NSString *want = [NSString stringWithFormat:@"%d", lim], *old = [t substringWithRange:[m rangeAtIndex:2]];
    if ([old isEqualToString:want]) return;
    [t replaceCharactersInRange:[m rangeAtIndex:2] withString:want];
    if ([t writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) MSLogf(@"steady 30: dynamic resolution may now go down to %@ %% (was %@ %%, options.json)", want, old);
}
static void MSRestoreDRSRange(void) {
    NSString *root = g_root; if (!root) return;
    NSString *p = [root stringByAppendingPathComponent:@"r6/config/settings/platform/mac/options.json"];
    NSMutableString *t = [NSMutableString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil]; if (!t) return;
    NSRange nr = [t rangeOfString:@"\"name\"\\s*:\\s*\"DRS_MinResolution\"" options:NSRegularExpressionSearch]; if (nr.location == NSNotFound) return;
    NSRange close = [t rangeOfString:@"}" options:0 range:NSMakeRange(nr.location, t.length - nr.location)]; if (close.location == NSNotFound) return;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\"min_value\"\\s*:\\s*)(\\d+)" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:t options:0 range:NSMakeRange(nr.location, close.location - nr.location)]; if (!m) return;
    if ([[t substringWithRange:[m rangeAtIndex:2]] isEqualToString:@"50"]) return;
    [t replaceCharactersInRange:[m rangeAtIndex:2] withString:@"50"]; [t writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static BOOL MSApplySteady30(NSMutableString *txt) {
    /* Measured over 4 hot city drives (2026-10-16): fixed MetalFX Performance 26.2 FPS avg (47 % of the time 28+), with the
       game's DRS 21-23 FPS even at a smaller render size - DRS itself costs frames here. So it is opt-in (Steady30 = YES),
       and the one CyPort switched on is switched back off once (CyPortDRSReverted). */
    if (![MSConfig()[@"Steady30"] boolValue]) {
        NSUserDefaults *u = NSUserDefaults.standardUserDefaults; BOOL ch = NO;
        if ([u boolForKey:@"CyPortSteady30v2"] && ![u boolForKey:@"CyPortDRSReverted"]) {
            ch |= MSTextSetRaw(txt, @"DynamicResolutionScaling", @"false", NULL);
            NSString *q = nil; MSTextSetOption(txt, @"MetalFX", nil, -1, &q);
            if ([q isEqualToString:@"Dynamic"]) { MSTextSetOption(txt, @"MetalFX", @"Performance", 3, NULL); ch = YES; }
            ch |= MSTextSetRaw(txt, @"DRS_MinResolution", @"50", NULL);
            MSRestoreDRSRange();
            [u setBool:YES forKey:@"CyPortDRSReverted"]; [u removeObjectForKey:@"CyPortSteady30v2"];
            MSLogf(@"steady 30: dynamic resolution switched back off, MetalFX Performance (measured faster)");
        }
        return ch;
    }
    MSPatchDRSRange();
    NSString *up = nil; MSTextSetOption(txt, @"ResolutionScaling", nil, -1, &up);
    if (![up isEqualToString:@"FSR2"]) { MSLogf(@"steady 30: upscaler is %@, not MetalFX - left alone", up); return NO; }
    int lo = (int)MSCfgD(@"DRSMin", 35), hi = (int)MSCfgD(@"DRSMax", 50); lo = MAX(34, MIN(lo, 100)); hi = MAX(lo, MIN(hi, 100));   /* MetalFX: input >= 1/3 of output */
    NSUserDefaults *u = NSUserDefaults.standardUserDefaults; BOOL ch = NO;
    if (![u boolForKey:@"CyPortSteady30v2"]) {
        ch |= MSTextSetRaw(txt, @"DynamicResolutionScaling", @"true", NULL);
        NSString *q = nil; MSTextSetOption(txt, @"MetalFX", nil, -1, &q);
        if (![q isEqualToString:@"Dynamic"]) { MSTextSetOption(txt, @"MetalFX", @"Dynamic", 5, NULL); ch = YES; }
        ch |= MSTextSetRaw(txt, @"DRS_TargetFPS", @"30", NULL);
        ch |= MSTextSetRaw(txt, @"DRS_MaxResolution", [NSString stringWithFormat:@"%d", hi], NULL);
        ch |= MSTextSetRaw(txt, @"DRS_MinResolution", [NSString stringWithFormat:@"%d", lo], NULL);
        [u setBool:YES forKey:@"CyPortSteady30v2"];
        MSLogf(@"steady 30: MetalFX dynamic resolution on, target 30 FPS, %d-%d %%", lo, hi);
    } else {                                                   /* the game clamps to its old 50 % limit when it saves */
        NSString *on = nil, *mn = nil; MSTextSetRaw(txt, @"DynamicResolutionScaling", nil, &on); MSTextSetRaw(txt, @"DRS_MinResolution", nil, &mn);
        if ([on isEqualToString:@"true"] && mn.intValue >= 50 && lo < 50) ch |= MSTextSetRaw(txt, @"DRS_MinResolution", [NSString stringWithFormat:@"%d", lo], NULL);
        MSLogf(@"steady 30: dynamic resolution %@, min %@ %%", [on isEqualToString:@"true"] ? @"on" : @"off (player's choice)", ch ? @(lo) : mn);
    }
    return ch;
}
static BOOL MSSmoothOn(void);
static void MSApplyGameSettings(NSSet *keys) {
    MSWriteStreamingIni();
    /* Only the resolution is written, as a text edit of its "value" (the game is offered only that one mode); the rest of
       the file stays byte for byte as the game wrote it. Re-serialising the whole file (NSJSONSerialization escapes every
       "/" as "\/" and reorders keys) made the game report corrupt settings at every start and reset them.
       First run (no file yet): the bundled DefaultUserSettings.json (every graphics option at its lowest) is copied in. */
    (void)keys; BOOL firstRun = NO, firstChanged = NO;
    NSString *p = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                   stringByAppendingPathComponent:@"CD Projekt Red/Cyberpunk 2077/UserSettings.json"];
    if (![NSFileManager.defaultManager fileExistsAtPath:p]) {
        NSString *t = [NSBundle.mainBundle pathForResource:@"DefaultUserSettings" ofType:@"json"];
        [NSFileManager.defaultManager createDirectoryAtPath:[p stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        if (t && [NSFileManager.defaultManager copyItemAtPath:t toPath:p error:nil]) { MSLogf(@"first run: lowest graphics settings installed"); firstRun = YES; }
    }
    NSMutableString *txt = [NSMutableString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    /* first run with smooth frame pacing on (the default): the template caps the game at 30 twice (VSync 30, Maximum FPS
       30), which leaves smooth pacing nothing to do. VSync Off (index 0 of the game's runtime list Off/120/60/40/30) and
       Maximum FPS off: smooth pacing then holds the highest even rate the phone keeps up with. Later launches keep
       whatever the player sets in the game. */
    if (firstRun && txt && MSSmoothOn()) {
        BOOL a = MSTextSetOption(txt, @"VSync", @"UI-Settings-Video-QualitySetting-Off", 0, NULL);
        BOOL b = MSTextSetRaw(txt, @"MaximumFPS_OnOff", @"false", NULL);
        if (a || b) { firstChanged = YES; MSLogf(@"first run: VSync Off, Maximum FPS off - smooth frame pacing picks the frame rate"); }
    }
    if (!txt) { MSLogf(@"start screen: no UserSettings.json yet (the game starts in %@)", MSModeName(MacShimCurrentMode())); return; }
    NSUInteger unesc = [txt replaceOccurrencesOfString:@"\\/" withString:@"/" options:0 range:NSMakeRange(0, txt.length)];  /* undo the old escaping */
    NSString *want = MSModeName(MacShimCurrentMode()); BOOL changed = unesc > 0 || firstChanged;
    NSRange nr = [txt rangeOfString:@"\"name\"\\s*:\\s*\"Resolution\"" options:NSRegularExpressionSearch];
    if (nr.location != NSNotFound) {
        NSRange open = [txt rangeOfString:@"{" options:NSBackwardsSearch range:NSMakeRange(0, nr.location)];
        NSRange close = [txt rangeOfString:@"}" options:0 range:NSMakeRange(nr.location, txt.length - nr.location)];
        if (open.location != NSNotFound && close.location != NSNotFound) {
            NSRange obj = NSMakeRange(open.location, close.location - open.location + 1);
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\"value\"\\s*:\\s*\")([^\"]*)(\")" options:0 error:nil];
            NSTextCheckingResult *m = [re firstMatchInString:txt options:0 range:obj];
            if (m && ![[txt substringWithRange:[m rangeAtIndex:2]] isEqualToString:want]) { [txt replaceCharactersInRange:[m rangeAtIndex:2] withString:want]; changed = YES; }
        }
    }
    /* once: the Mac build's upscaler names don't match its menu labels - value "FSR2" is MetalFX in the menu and in the
       engine (the MetalFX scaler is made for it), value "MetalFX" is FSR 3.1. An earlier CyPort (and its first-run
       template) wrote "MetalFX" meaning MetalFX, so the game ran FSR 3.1. Put it on real MetalFX, Performance. */
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"CyPortUpscalerNamesFixed"]) {
        NSString *was = nil;
        if (MSTextSetOption(txt, @"ResolutionScaling", nil, -1, &was) && [was isEqualToString:@"MetalFX"]) {
            MSTextSetOption(txt, @"ResolutionScaling", @"FSR2", 1, NULL);
            MSTextSetOption(txt, @"FSR2", @"Performance", 3, NULL);
            MSTextSetOption(txt, @"MetalFX", @"Performance", 3, NULL);
            changed = YES; MSLogf(@"upscaler: was FSR 3.1 (value \"MetalFX\"), now MetalFX Performance (value \"FSR2\")");
        }
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"CyPortUpscalerNamesFixed"];
    }
    if (MSApplyFrameRate(txt)) changed = YES;
    if (MSApplySteady30(txt)) changed = YES;
    if (changed && [txt writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil])
        MSLogf(@"start screen: resolution %@ (text edit%@)", want, unesc ? [NSString stringWithFormat:@", %lu escaped slashes repaired", (unsigned long)unesc] : @"");
}
static NSDictionary *MSRestartSettingsSnapshot(void); static void MSSyncStartScreenFrom(NSDictionary *v);
@interface MSLauncherVC : UIViewController @property(copy) void (^onPlay)(void); @end
@implementation MSLauncherVC { UIButton *_res, *_play; UISegmentedControl *_ov; UILabel *_hint; }
/* Start screen: resolution and performance overlay only. Everything else is set in the game's own settings menu
   (kept across restarts; the restart popup says when a change needs one). */
- (UILabel *)msLabel:(NSString *)t size:(CGFloat)sz color:(UIColor *)c bold:(BOOL)b {
    UILabel *l = [UILabel new]; l.text = t; l.textColor = c; l.font = b ? [UIFont boldSystemFontOfSize:sz] : [UIFont systemFontOfSize:sz]; l.numberOfLines = 0; return l;
}
- (UIStackView *)msRow:(NSString *)title control:(UIView *)v {
    UILabel *l = [self msLabel:title size:15 color:[UIColor colorWithWhite:0.75 alpha:1] bold:NO];
    [l.widthAnchor constraintEqualToConstant:170].active = YES;
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:@[ l, v ]]; r.spacing = 12; r.alignment = UIStackViewAlignmentCenter; return r;
}
- (void)msBuildResMenu {
    NSMutableArray *acts = [NSMutableArray array]; int cur = MacShimCurrentMode();
    NSArray *notes = @[ @"fastest", @"", @"", @"recommended", @"sharper, warmer", @"gets hot", @"very hot", @"native, very hot" ];
    for (int i = MacShimModeCount() - 1; i >= 0; i--) {
        NSString *t = [MSModeName(i) stringByReplacingOccurrencesOfString:@"x" withString:@" × "];
        if ([notes[i] length]) t = [t stringByAppendingFormat:@"  (%@)", notes[i]];
        UIAction *a = [UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction *x) {
            [NSUserDefaults.standardUserDefaults setInteger:i forKey:@"MacShimResMode2"]; [self msBuildResMenu]; [self msChanged]; }];
        if (i == cur) a.state = UIMenuElementStateOn;
        [acts addObject:a];
    }
    _res.menu = [UIMenu menuWithTitle:@"Resolution" children:acts]; _res.showsMenuAsPrimaryAction = YES;
    [_res setTitle:[[MSModeName(cur) stringByReplacingOccurrencesOfString:@"x" withString:@" × "] stringByAppendingString:@"  ▾"] forState:UIControlStateNormal];
}
- (void)viewDidLoad {
    [super viewDidLoad]; MSInitChoices(); self.view.backgroundColor = UIColor.blackColor;
    UIColor *yellow = [UIColor colorWithRed:0.99 green:0.93 blue:0.04 alpha:1];
    UILabel *title = [self msLabel:@"CYPORT" size:28 color:yellow bold:YES];
    _res = [UIButton buttonWithType:UIButtonTypeSystem]; _res.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [_res setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _res.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1]; _res.layer.cornerRadius = 8; _res.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    [self msBuildResMenu];
    _ov = [[UISegmentedControl alloc] initWithItems:@[ @"Off", @"FPS", @"Detailed" ]]; _ov.selectedSegmentIndex = MSPref(@"MacShimOverlay", 1);
    _ov.selectedSegmentTintColor = yellow;
    [_ov setTitleTextAttributes:@{ NSForegroundColorAttributeName: UIColor.blackColor } forState:UIControlStateSelected];
    [_ov setTitleTextAttributes:@{ NSForegroundColorAttributeName: UIColor.whiteColor } forState:UIControlStateNormal];
    [_ov addTarget:self action:@selector(msChanged) forControlEvents:UIControlEventValueChanged];
    _hint = [self msLabel:@"Other graphics settings: in the game's own Settings menu." size:12 color:[UIColor colorWithWhite:0.6 alpha:1] bold:NO];
    _hint.textAlignment = NSTextAlignmentCenter;
    _play = [UIButton buttonWithType:UIButtonTypeSystem];
    [_play setTitle:@"PLAY" forState:UIControlStateNormal]; _play.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [_play setTitleColor:UIColor.blackColor forState:UIControlStateNormal]; _play.backgroundColor = yellow; _play.layer.cornerRadius = 10;
    [_play.widthAnchor constraintEqualToConstant:220].active = YES; [_play.heightAnchor constraintEqualToConstant:48].active = YES;
    [_play addTarget:self action:@selector(msPlay) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[ title, [self msRow:@"Resolution" control:_res],
                                                                        [self msRow:@"Performance overlay" control:_ov], _hint, _play ]];
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 14; st.alignment = UIStackViewAlignmentCenter;
    [st setCustomSpacing:22 afterView:title]; [st setCustomSpacing:18 afterView:_hint];
    st.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:st];
    [NSLayoutConstraint activateConstraints:@[ [st.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor], [st.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
                                               [st.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-32] ]];
}
- (void)msChanged { [NSUserDefaults.standardUserDefaults setInteger:_ov.selectedSegmentIndex forKey:@"MacShimOverlay"]; }
- (void)msPlay {
    [self msChanged]; _play.enabled = NO; [_play setTitle:@"STARTING…" forState:UIControlStateNormal];
    MSApplyGameSettings([NSSet set]);                               /* resolution only (first run: lowest settings) */
    if (self.onPlay) self.onPlay();
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
/* ---------------------------------------------------------------- in-game settings that need a restart
 * Resolution, upscaler, frame generation, VSync/FPS, dynamic resolution, texture quality and window mode only take
 * effect at the next start (the game is offered one display mode, chosen on the start screen). While the game runs,
 * UserSettings.json is watched: when one of these changes in the game's menu, the start screen's choices are updated
 * to match (so Play doesn't overwrite them) and a popup offers to quit the app so it can be started again. Changes in
 * the first 30 s only set the baseline (the game rewrites the file while it starts). */
extern _Atomic long long g_frames;
static void (^g_settingsPoke)(void);                  /* "the game just applied graphics settings": check soon */
static NSString *MSUserSettingsPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"CD Projekt Red/Cyberpunk 2077/UserSettings.json"];
}
static NSDictionary *MSRestartSettingsSnapshot(void) {
    NSData *d = [NSData dataWithContentsOfFile:MSUserSettingsPath()]; if (!d) return nil;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; if (![j isKindOfClass:NSDictionary.class]) return nil;
    NSSet *watch = [NSSet setWithArray:@[ @"Resolution", @"WindowMode", @"ResolutionScaling", @"MetalFX", @"FSR2", @"FSR3", @"FrameGeneration",
                                          @"FSR3_FrameGeneration", @"VSync", @"DynamicResolutionScaling", @"TextureQuality",
                                          @"MaximumFPS_OnOff", @"MaximumFPS_Value", @"QuickPresets" ]];
    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    for (NSDictionary *grp in j[@"data"]) if ([grp isKindOfClass:NSDictionary.class]) for (NSDictionary *o in grp[@"options"])
        if ([o isKindOfClass:NSDictionary.class] && [watch containsObject:o[@"name"]] && o[@"value"]) snap[o[@"name"]] = o[@"value"];
    return snap;
}
/* the game's values -> the start screen's choices */
static void MSSyncStartScreenFrom(NSDictionary *v) {
    MSInitChoices(); NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
    NSUInteger up = [g_upscalers indexOfObject:v[@"ResolutionScaling"] ?: @""];
    if (up != NSNotFound) {
        [u setInteger:up forKey:@"MacShimUpscaler"];
        NSString *qk = @[ @"", @"FSR2", @"FSR3", @"MetalFX" ][up];
        NSUInteger q = qk.length ? [g_upQuality indexOfObject:v[qk] ?: @""] : NSNotFound;
        if (q != NSNotFound) [u setInteger:q forKey:@"MacShimUpQuality"];
    }
    BOOL fg = [v[@"FrameGeneration"] isEqual:@"FSR3"]; [u setBool:fg forKey:@"MacShimFrameGen"];
    if (v[@"DynamicResolutionScaling"]) [u setBool:[v[@"DynamicResolutionScaling"] boolValue] forKey:@"MacShimDRS"];
    int vs = [v[@"MaximumFPS_OnOff"] boolValue] ? [v[@"MaximumFPS_Value"] intValue] : [v[@"VSync"] intValue];
    if (vs > 0) { int fps = fg ? vs / 2 : vs, best = 0, bd = 1000;
        for (int i = 0; i < (int)g_fpsChoices.count; i++) { int dd = abs([g_fpsChoices[i] intValue] - fps); if (dd < bd) { bd = dd; best = i; } }
        [u setInteger:best forKey:@"MacShimFPS"]; }
}
@interface MSRestartVC : UIViewController @end
@implementation MSRestartVC
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
static UIWindow *g_restartWin;
static void MSShowRestartPopup(NSArray *changed) {
    if (g_restartWin) return;                                    /* already showing */
    UIWindowScene *sc = MSAppScene();
    g_restartWin = sc ? [[UIWindow alloc] initWithWindowScene:sc] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    g_restartWin.windowLevel = UIWindowLevelAlert + 20; g_restartWin.backgroundColor = UIColor.clearColor;
    g_restartWin.rootViewController = [MSRestartVC new]; g_restartWin.rootViewController.view.backgroundColor = UIColor.clearColor;
    g_restartWin.hidden = NO;
    NSDictionary *names = @{ @"Resolution": @"resolution", @"WindowMode": @"window mode", @"ResolutionScaling": @"upscaler", @"MetalFX": @"MetalFX quality",
                             @"FSR2": @"FSR 2 quality", @"FSR3": @"FSR 3 quality", @"FrameGeneration": @"frame generation", @"FSR3_FrameGeneration": @"frame generation",
                             @"VSync": @"FPS limit / VSync", @"DynamicResolutionScaling": @"dynamic resolution", @"TextureQuality": @"texture quality" };
    NSMutableOrderedSet *list = [NSMutableOrderedSet orderedSet]; for (NSString *k in changed) [list addObject:names[k] ?: k];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restart to apply settings"
        message:[NSString stringWithFormat:@"You changed: %@.\n\nThese settings take effect after restarting the game. Restart closes the app; open it again from the Home Screen.",
                 [list.array componentsJoinedByString:@", "]] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { g_restartWin.hidden = YES; g_restartWin = nil; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        MSLogf(@"restart popup: quitting so the new settings apply at the next start");
        [NSUserDefaults.standardUserDefaults synchronize];
        exit(0);
    }]];
    a.preferredAction = a.actions.lastObject;
    [g_restartWin.rootViewController presentViewController:a animated:YES completion:nil];
    MSLogf(@"restart popup shown (%@)", [changed componentsJoinedByString:@", "]);
}
static void MSWatchGameSettings(void) {
    if ([MSConfig()[@"RestartPopup"] isEqual:@NO]) return;
    static NSDictionary *base; static double t0, drawingSince; static BOOL pending;
    t0 = CACurrentMediaTime(); base = MSRestartSettingsSnapshot();
    NSString *dir = [MSUserSettingsPath() stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open(dir.fileSystemRepresentation, O_EVTONLY); if (fd < 0) return;
    dispatch_queue_t q = dispatch_queue_create("settings-watch", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB, q);
    static NSDate *lastMod;
    void (^check)(void) = ^{
        pending = NO;
        NSDate *mod = [NSFileManager.defaultManager attributesOfItemAtPath:MSUserSettingsPath() error:nil].fileModificationDate;
        if (mod && lastMod && [mod isEqualToDate:lastMod]) return;         /* not saved again */
        BOOL saved = lastMod != nil; lastMod = mod;
        NSDictionary *now = MSRestartSettingsSnapshot(); if (!now) return;
        if (saved) { NSMutableArray *d = [NSMutableArray array]; for (NSString *k in now) if (![now[k] isEqual:base[k]]) [d addObject:[NSString stringWithFormat:@"%@ %@ -> %@", k, base[k], now[k]]];
            MSLogf(@"game saved its settings (%.0f s after start)%@", CACurrentMediaTime() - t0, d.count ? [@": " stringByAppendingString:[d componentsJoinedByString:@", "]] : @" - nothing that needs a restart"); }
        /* startup grace: the game rewrites (normalises) the file while it loads; until it has drawn for 5 s only
           the baseline moves */
        if (g_frames > 60 && !drawingSince) drawingSince = CACurrentMediaTime();
        if (!base || !drawingSince || CACurrentMediaTime() - drawingSince < 5) { base = now; return; }
        if (base && g_paceMode > 0 && (![now[@"MaximumFPS_OnOff"] isEqual:base[@"MaximumFPS_OnOff"]] || ![now[@"MaximumFPS_Value"] isEqual:base[@"MaximumFPS_Value"]] || ![now[@"VSync"] isEqual:base[@"VSync"]])) {
            static int said; if (!said++) MSLogf(@"frame rate changed in the game's menu - CyPort keeps pacing at %d FPS (macshim.plist FrameRate)", (int)g_paceFPS);
        }
        NSMutableArray *changed = [NSMutableArray array];
        NSSet *live = [NSSet setWithArray:@[ @"MaximumFPS_OnOff", @"MaximumFPS_Value", @"QuickPresets" ]];   /* apply without a restart */
        for (NSString *k in now) if (![now[k] isEqual:base[k]] && ![live containsObject:k]) [changed addObject:k];
        if (!changed.count) return;
        base = now;
        MSSyncStartScreenFrom(now);
        MSLogf(@"in-game settings changed: %@", now);
        MSMainAsync(^{ MSShowRestartPopup(changed); });
    };
    dispatch_source_set_event_handler(src, ^{
        if (pending) return; pending = YES;                       /* the game writes in bursts: look a moment later */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), q, check);
    });
    /* the file also changes in place (no directory event on every write): check its modification time every 0.5 s
       (only a stat; the JSON is read when it changed) */
    dispatch_source_t tick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(tick, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), NSEC_PER_SEC / 2, NSEC_PER_SEC / 20);
    g_settingsPoke = ^{                                            /* applying settings: the save follows within ~2 s */
        for (int i = 1; i <= 12; i++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.25 * NSEC_PER_SEC)), q, ^{ if (!pending) check(); });
    };
    dispatch_source_set_event_handler(tick, ^{ if (!pending) check(); });
    static dispatch_source_t keep1, keep2; keep1 = src; keep2 = tick;
    dispatch_resume(src); dispatch_resume(tick);
    MSLogf(@"watching in-game settings for changes that need a restart");
}
@interface MSBootDelegate : MSUIDelegate @end
@implementation MSBootDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    MSLogf(@"UIKit launched before the game (boot)");
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *x) {
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp]; }];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    MSLauncherVC *lv = nil;
    __block void (^playAction)(void) = nil;            /* set below, once `go` exists */
    /* the SwiftUI start screen (Launcher.swift); the UIKit one stays as a fallback */
    Class sw = NSClassFromString(@"MSSwiftLauncher"); UIViewController *svc = nil;
    if (sw) {
        NSMutableArray *names = [NSMutableArray array], *notes = [NSMutableArray array];
        NSArray *n8 = @[ @"fastest", @"", @"", @"recommended", @"sharper, warmer", @"gets hot", @"very hot", @"native, very hot" ];
        for (int i = 0; i < MacShimModeCount(); i++) { [names addObject:[MSModeName(i) stringByReplacingOccurrencesOfString:@"x" withString:@" × "]]; [notes addObject:i < (int)n8.count ? n8[i] : @""]; }
        void (^onPlay)(NSInteger, NSInteger) = ^(NSInteger res, NSInteger ov) {
            [NSUserDefaults.standardUserDefaults setInteger:res forKey:@"MacShimResMode2"];
            [NSUserDefaults.standardUserDefaults setInteger:ov forKey:@"MacShimOverlay"];
            MSApplyGameSettings([NSSet set]);
            if (playAction) playAction();
        };
        svc = ((UIViewController *(*)(id, SEL, NSArray *, NSArray *, NSInteger, NSInteger, id))objc_msgSend)(sw,
              NSSelectorFromString(@"makeWithResolutions:notes:current:overlay:onPlay:"), names, notes, (NSInteger)MacShimCurrentMode(), MSPref(@"MacShimOverlay", 1), onPlay);
    }
    if (svc) self.window.rootViewController = svc;
    else { lv = [MSLauncherVC new]; self.window.rootViewController = lv; }
    [self.window makeKeyAndVisible];
    /* Leave a few run loop turns so the first frame is committed and iOS marks the launch finished, then run the game.
       main() starts over from the top; the only thing before sharedApplication is an autorelease pool push.
       Started from a run-loop timer, not the main dispatch queue: the game never returns, and the main queue can't run
       anything else while one of its blocks is running - GameController, NSOperationQueue.mainQueue observers and
       every dispatch to the main queue would be stuck for the whole game. */
    void (^start)(void) = ^{
        MSLogf(@"launch finished; starting the game's main()");
        /* iOS gives the main thread a 1 MB stack, macOS 8 MB, and the game runs its whole loop on the main thread.
           Run it on a big stack of its own (still the main thread) with a no-access guard below. */
        double mb = MSCfgD(@"MainStackMB", 64); int r;
        if (mb > 1) {
            size_t sz = (size_t)(mb * 1048576) & ~(size_t)0x3fff, guard = 64 << 10;
            vm_address_t va = 0; char *st = MAP_FAILED;
            if (vm_allocate(mach_task_self(), &va, sz + guard, VM_FLAGS_ANYWHERE) == KERN_SUCCESS) st = (char *)va;
            if (st != MAP_FAILED) {
                vm_protect(mach_task_self(), va, guard, FALSE, VM_PROT_NONE);
                MSLogf(@"game main thread runs on a %.0f MB stack at %p", mb, st + guard);
                r = MSCallOnStack(st + sz + guard, g_gameMain);
            } else r = ((int (*)(int, char **, char **, const char **))g_gameMain)(*_NSGetArgc(), *_NSGetArgv(), *_NSGetEnviron(), NULL);
        } else r = ((int (*)(int, char **, char **, const char **))g_gameMain)(*_NSGetArgc(), *_NSGetArgv(), *_NSGetEnviron(), NULL);
        MSLogf(@"game main() returned %d", r); exit(r);
    };
    __weak UIWindow *win = self.window;
    void (^go)(void) = ^{
        win.rootViewController = [MSBootVC new];
        MSStatusCreate();
        MSWatchGameSettings();
        if ([MSConfig()[@"BootFromMainQueue"] boolValue]) { MSLogf(@"(test) starting the game from the main queue"); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), start); }
        else [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer *t) { start(); }];
    };
    /* start screen first (AutoPlay = YES in macshim.plist skips it, for unattended tests) */
    if ([MSConfig()[@"AutoPlay"] boolValue]) { MSApplyGameSettings([NSSet set]); go(); }
    else { playAction = go; lv.onPlay = go; MSLogf(@"start screen shown (%@)", svc ? @"SwiftUI" : @"UIKit"); }
    return YES;
}
@end
static void MSBootUIKit(void) {
    g_uikitUp = YES; MSLogf(@"game main() reached sharedApplication; booting UIKit first");
    if (!MSDataRoot()) MSRunSetup();            /* no game folder: folder picker instead of the game (never returns) */
    MSLogf(@"starting UIKit before the game");
    @autoreleasepool { UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), nil, NSStringFromClass([MSBootDelegate class])); }
    exit(0);
}
static BOOL MSCallerIsMainExe(void *ret) { Dl_info i; return dladdr(ret, &i) && i.dli_fbase == (void *)_dyld_get_image_header(0); }

int ms_NSGetExecutablePath(char *buf, uint32_t *size) __asm("__NSGetExecutablePath");
int ms_NSGetExecutablePath(char *buf, uint32_t *size) {
    NSString *root = MSDataRoot();
    if (!root) {
        if (MSCallerIsMainExe(__builtin_return_address(0))) MSRunSetup();      /* the game itself asked: show the folder picker instead */
        root = MSInternalRoot();
    }
    const char *p = [[root stringByAppendingPathComponent:@"Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"] fileSystemRepresentation];
    uint32_t n = (uint32_t)strlen(p) + 1; if (*size < n) { *size = n; return -1; } memcpy(buf, p, n);
    static int logged; if (logged++ < 3) MSLogf(@"_NSGetExecutablePath -> %s", p);
    return 0;
}

int ms_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) __asm("_sysctlbyname");
int ms_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    NSDictionary *c = MSConfig(); const char *fake = NULL;
    if (!strcmp(name, "machdep.cpu.brand_string")) fake = [(c[@"CPUBrand"] ?: @"Apple M4") UTF8String];
    else if (!strcmp(name, "hw.model"))            fake = [(c[@"Model"] ?: @"Mac16,1") UTF8String];
    else if (!strcmp(name, "kern.osproductversion")) fake = [(c[@"OSVersion"] ?: @"15.5") UTF8String];
    double memGB = [c[@"MemSizeGB"] doubleValue];             /* MemSizeGB: what hw.memsize reports (engine memory budgets) */
    if (memGB > 0 && !newp && oldp && oldlenp && *oldlenp >= sizeof(uint64_t) && !strcmp(name, "hw.memsize")) {
        uint64_t v = (uint64_t)(memGB * 1073741824.0); memcpy(oldp, &v, sizeof v); *oldlenp = sizeof v;
        static int said; if (!said++) MSLogf(@"sysctl hw.memsize -> %.0f GB (MemSizeGB)", memGB);
        return 0;
    }
    int cpus = [c[@"CPUCount"] intValue];
    if (cpus > 0 && !newp && oldp && oldlenp && *oldlenp >= sizeof(int) &&
        (!strcmp(name, "hw.ncpu") || !strcmp(name, "hw.physicalcpu") || !strcmp(name, "hw.logicalcpu") || !strcmp(name, "hw.activecpu") ||
         !strcmp(name, "hw.physicalcpu_max") || !strcmp(name, "hw.logicalcpu_max"))) {
        if (*oldlenp >= sizeof(long long)) { long long v = cpus; memcpy(oldp, &v, sizeof v); *oldlenp = sizeof v; } else { memcpy(oldp, &cpus, sizeof cpus); *oldlenp = sizeof cpus; }
        return 0;
    }
    /* A18 Pro: perflevel0 = 2 performance cores, perflevel1 = 4 efficiency cores; with CPUCount keep them consistent */
    if (cpus > 0 && !newp && oldp && oldlenp && *oldlenp >= sizeof(int) && !strncmp(name, "hw.perflevel", 12) &&
        (strstr(name, "logicalcpu") || strstr(name, "physicalcpu"))) {
        int real = 0; size_t rl = sizeof real;
        static int (*rs)(const char *, void *, size_t *, void *, size_t); if (!rs) rs = (int (*)(const char *, void *, size_t *, void *, size_t))dlsym(RTLD_NEXT, "sysctlbyname");
        if (rs && rs("hw.perflevel0.logicalcpu", &real, &rl, NULL, 0) != 0) real = 2;
        int p0 = MIN(real, cpus), v = name[12] == '0' ? p0 : MAX(0, cpus - p0);
        if (*oldlenp >= sizeof(long long)) { long long w = v; memcpy(oldp, &w, sizeof w); *oldlenp = sizeof w; } else { memcpy(oldp, &v, sizeof v); *oldlenp = sizeof v; }
        static int said; if (said++ < 4) MSLogf(@"sysctl %s -> %d (CPUCount %d)", name, v, cpus);
        return 0;
    }
    if (fake && !newp) {
        size_t n = strlen(fake) + 1;
        if (oldp && oldlenp) { if (*oldlenp < n) { *oldlenp = n; errno = ENOMEM; return -1; } memcpy(oldp, fake, n); }
        if (oldlenp) *oldlenp = n; return 0;
    }
    static int (*real)(const char *, void *, size_t *, void *, size_t); if (!real) real = (int (*)(const char *, void *, size_t *, void *, size_t))dlsym(RTLD_NEXT, "sysctlbyname");
    size_t inLen = oldlenp ? *oldlenp : 0;
    int r = real ? real(name, oldp, oldlenp, newp, newlen) : -1; int e = errno;
    static NSMutableSet *seen; static dispatch_once_t o; dispatch_once(&o, ^{ seen = [NSMutableSet set]; });
    NSString *k = @(name); BOOL first; @synchronized (seen) { first = ![seen containsObject:k]; if (first) [seen addObject:k]; }
    if (first) {
        unsigned long long v = 0; if (r == 0 && oldp && oldlenp) memcpy(&v, oldp, MIN(*oldlenp, sizeof v));
        MSLogf(@"sysctl %s -> %d%s, buf %zu, len %zu, value %#llx", name, r, r ? [NSString stringWithFormat:@" errno %d", e].UTF8String : "", inLen, oldlenp ? *oldlenp : 0, v);
    }
    errno = e; return r;
}


/* the shim exports _mmap & co itself, so a plain call here would recurse: use libsystem's directly */
static void *(*kmmap)(void *, size_t, int, int, int, off_t); static int (*kmunmap)(void *, size_t);
static int (*kmadvise)(void *, size_t, int); static int (*kmprotect)(void *, size_t, int);
__attribute__((constructor(101))) static void MSResolveVM(void) {
    void *h = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOLOAD | RTLD_LAZY);
    kmmap = dlsym(h, "mmap"); kmunmap = dlsym(h, "munmap"); kmadvise = dlsym(h, "madvise"); kmprotect = dlsym(h, "mprotect");
}
/* ---------------------------------------------------------------- thread priority (QoS)
 * The engine sets its worker threads' QoS itself (pthread_set_qos_class_self_np, rerouted here by ios_retarget.py).
 * Values tuned for a Mac's 8+ performance cores make iOS park job/render threads on the 4 efficiency cores of an
 * A18 Pro. Default/utility requests become user-initiated (background stays background: streaming IO, shader
 * caches). ThreadQoS = NO keeps the game's values. */
static pthread_t g_slowWorker[8]; static _Atomic int g_slowWorkerN;   /* workers cool mode put on the efficiency cores */
int ms_pthread_set_qos_class_self_np(qos_class_t q, int rel) __asm("_pthread_set_qos_class_self_np");
int ms_pthread_set_qos_class_self_np(qos_class_t q, int rel) {
    static int (*real)(qos_class_t, int); static int boost = -1;
    if (!real) real = dlsym(dlopen("/usr/lib/system/libsystem_pthread.dylib", RTLD_NOLOAD | RTLD_LAZY), "pthread_set_qos_class_self_np");
    if (boost < 0) boost = ![MSConfig()[@"ThreadQoS"] isEqual:@NO];
    qos_class_t want = q;
    if (boost && (q == QOS_CLASS_UTILITY || q == QOS_CLASS_DEFAULT || q == QOS_CLASS_UNSPECIFIED)) want = QOS_CLASS_USER_INITIATED;
    /* Cool mode (always on; macshim.plist CoolMode = NO turns it off): the 5 job
       workers (redDispatcher*) ask for user-interactive QoS, which keeps them on the A18 Pro's 2 performance cores
       next to the game and render threads - the phone throttles within a minute or two. At utility QoS iOS runs them
       on the 4 efficiency cores, which do the same parallel work for a fraction of the power; the game and render
       threads keep the performance cores. All 5 there made frame times uneven (the game thread waits for their jobs every
       frame, and the slow cores answer late), while the 2 performance cores still had room: workers 1-2 stay on
       them, the rest go to the efficiency cores (CoolFastWorkers, default 2). */
    char nm[64] = ""; pthread_getname_np(pthread_self(), nm, sizeof nm);
    static int cool = -1;
    if (cool < 0) cool = ![MSConfig()[@"CoolMode"] isEqual:@NO];
    static int fastW = -1; if (fastW < 0) fastW = (int)MAX(0, MSCfgD(@"CoolFastWorkers", 2));
    if (cool && !strncmp(nm, "redDispatcher", 13) && q > QOS_CLASS_UTILITY) want = atoi(nm + 13) <= fastW ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY;
    if (want == QOS_CLASS_UTILITY && !strncmp(nm, "redDispatcher", 13)) { int i = g_slowWorkerN; if (i < 8) { g_slowWorker[i] = pthread_self(); g_slowWorkerN = i + 1; } }
    static _Atomic int n; if (n++ < 40) {
        MSLogf(@"thread '%s' asks QoS %#x%@", nm, q, want != q ? [NSString stringWithFormat:@" -> %#x", want] : @""); }
    return real ? real(want, rel) : 0;
}
/* ---------------------------------------------------------------- job wake-ups: spin a little before sleeping
 * Profile of a hot phone in the city (~20 FPS, GPU half idle): the game thread spends 70-95 % of its time waiting for the
 * frame's jobs (os_sync_wait_on_address from red::Atomic::Wait, 0x10000754c), and the 5 job workers sleep in
 * dispatch_semaphore_wait as soon as their queue is empty (red job queue 0x103974e34 never spins) and are woken by
 * dispatch_semaphore_signal for the next job - hundreds of times a frame. On a Mac a wake-up costs microseconds; on a
 * throttled iPhone, waking a sleeping core costs far more, and 7-15 % of every worker's samples were the sleep/wake itself.
 * Now workers and the game thread first watch for the new job / the changed value for a few tens of microseconds and
 * only then sleep. The spin time adapts every 30 s: longer while spins catch the wake-up, shorter while they don't.
 * Result on the phone: 70-77 % of worker waits caught, hot-city FPS unchanged (22.6 vs 21.3) -> opt-in, JobSpin = YES;
 * WorkerSpinUs / GameSpinUs set the starting times (default 40 / 60 us). */
static _Atomic uint64_t g_spinTicks[3];                 /* [1] workers, [2] game thread; mach ticks */
static _Atomic long long g_spinWaits[3], g_spinHits[3];
static double g_spinUs[3];
static __thread int t_spinKind = -1, t_spinCheck;
static void MSSpinInit(void);
static int MSSpinKind(void) {
    if (t_spinKind > 0) return t_spinKind;
    if (t_spinKind == 0 && (++t_spinCheck & 255)) return 0;        /* not (yet) named: look again now and then */
    char nm[64] = ""; pthread_getname_np(pthread_self(), nm, sizeof nm);
    t_spinKind = !strncmp(nm, "redDispatcher", 13) ? 1 : !strcmp(nm, "GameThread") ? 2 : 0;
    if (t_spinKind) { static dispatch_once_t o; dispatch_once(&o, ^{ MSSpinInit(); }); }
    return t_spinKind;
}
static uint64_t MSUsToTicks(double us) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (uint64_t)(us * 1000.0 * tb.denom / tb.numer); }
static void MSSpinInit(void) {                      /* first wait of a worker / the game thread (the config is readable by then) */
    if (![MSConfig()[@"JobSpin"] boolValue]) return;            /* opt-in: caught 70 % of waits but no FPS gain (22.6 vs 21.3), costs power */
    g_spinUs[1] = MSCfgD(@"WorkerSpinUs", 40); g_spinUs[2] = MSCfgD(@"GameSpinUs", 60);
    for (int k = 1; k < 3; k++) g_spinTicks[k] = g_spinUs[k] > 0 ? MSUsToTicks(g_spinUs[k]) : 0;
    MSLogf(@"job wake-ups: workers spin %.0f us, game thread %.0f us before sleeping", g_spinUs[1], g_spinUs[2]);
}
static void MSSpinPause(void) { for (int i = 0; i < 8; i++) __asm__ volatile("isb" ::: "memory"); }
long ms_dispatch_semaphore_wait(dispatch_semaphore_t s, dispatch_time_t t) __asm("_dispatch_semaphore_wait");
long ms_dispatch_semaphore_wait(dispatch_semaphore_t s, dispatch_time_t t) {
    static long (*real)(dispatch_semaphore_t, dispatch_time_t);
    if (!real) real = (long (*)(dispatch_semaphore_t, dispatch_time_t))dlsym(dlopen("/usr/lib/system/libdispatch.dylib", RTLD_NOLOAD | RTLD_LAZY), "dispatch_semaphore_wait");
    uint64_t spin;
    if (t == DISPATCH_TIME_FOREVER && MSSpinKind() == 1 && (spin = g_spinTicks[1])) {
        g_spinWaits[1]++;
        if (real(s, DISPATCH_TIME_NOW) == 0) { g_spinHits[1]++; return 0; }
        uint64_t end = mach_absolute_time() + spin;
        do { MSSpinPause(); if (real(s, DISPATCH_TIME_NOW) == 0) { g_spinHits[1]++; return 0; } } while (mach_absolute_time() < end);
    }
    return real(s, t);
}
int ms_os_sync_wait_on_address(void *a, uint64_t v, size_t sz, uint32_t fl) __asm("_os_sync_wait_on_address");
int ms_os_sync_wait_on_address(void *a, uint64_t v, size_t sz, uint32_t fl) {
    static int (*real)(void *, uint64_t, size_t, uint32_t);
    if (!real) real = (int (*)(void *, uint64_t, size_t, uint32_t))dlsym(dlopen("/usr/lib/system/libsystem_platform.dylib", RTLD_NOLOAD | RTLD_LAZY), "os_sync_wait_on_address");
    uint64_t spin;
    if ((sz == 4 || sz == 8) && MSSpinKind() == 2 && (spin = g_spinTicks[2])) {
        g_spinWaits[2]++;
        uint64_t end = mach_absolute_time() + spin;
        do {                                                  /* the caller re-checks its condition: returning early is allowed */
            uint64_t cur = sz == 4 ? __atomic_load_n((uint32_t *)a, __ATOMIC_ACQUIRE) : __atomic_load_n((uint64_t *)a, __ATOMIC_ACQUIRE);
            if (cur != (sz == 4 ? (uint32_t)v : v)) { g_spinHits[2]++; return 0; }
            MSSpinPause();
        } while (mach_absolute_time() < end);
    }
    return real(a, v, sz, fl);
}
/* every 30 s: log, and adapt each spin time to what it catches */
static NSString *MSSpinReport(double dt) {
    if (!g_spinTicks[1] && !g_spinTicks[2]) return nil;
    static long long lw[3], lh[3]; NSMutableArray *parts = [NSMutableArray array];
    const char *names[3] = { "", "workers", "game thread" };
    for (int k = 1; k < 3; k++) {
        long long w = g_spinWaits[k] - lw[k], h = g_spinHits[k] - lh[k]; lw[k] = g_spinWaits[k]; lh[k] = g_spinHits[k];
        if (!g_spinTicks[k] || w <= 0) continue;
        double rate = (double)h / w, was = g_spinUs[k];
        if (rate > 0.5 && g_spinUs[k] < 60) g_spinUs[k] = MIN(60, g_spinUs[k] * 1.25);
        else if (rate < 0.15 && g_spinUs[k] > 10) g_spinUs[k] = MAX(10, g_spinUs[k] * 0.7);
        g_spinTicks[k] = MSUsToTicks(g_spinUs[k]);
        [parts addObject:[NSString stringWithFormat:@"%s %.0f waits/s, %.0f%% caught by a %.0f us spin%@", names[k], w / dt, 100 * rate, was,
                          was != g_spinUs[k] ? [NSString stringWithFormat:@" (now %.0f us)", g_spinUs[k]] : @""]];
    }
    return parts.count ? [@"job wake-ups: " stringByAppendingString:[parts componentsJoinedByString:@"; "]] : nil;
}

/* ---------------------------------------------------------------- sched_yield back-off
 * The engine's spinlocks (~800 sites) spin 16 times, then call sched_yield in a loop while they wait. On a Mac that
 * is cheap; on an iPhone the 5 job workers (each ~43% CPU, evenly - the spinning signature) burn power and heat while
 * waiting, the phone throttles, and FPS drops. A thread that keeps yielding back to back now sleeps a little instead:
 * 20 us after 32 yields in a row, 100 us after 256. The count resets once the thread stops yielding for 1 ms (it got
 * the lock / found work), so real work never waits. YieldBackoff = NO turns it off. */
_Atomic long long g_yields, g_yieldSleeps;
/* engine threads ask for SCHED_RR (fixed "real-time" priority 41-47, see the priority table at 0x104a4c9f0). On a Mac
   with 8+ cores that's fine; on the iPhone's 6 they fill every core above the system threads that deliver mouse and
   keyboard input, so above ~30 FPS input arrived late and jittery. They run as normal (timeshare) threads at the same
   priority instead, which the scheduler shares fairly. RealtimeThreads = YES keeps the Mac policy. */
static int MSThreadPolicy(int policy) {
    static int keep = -1; if (keep < 0) keep = [MSConfig()[@"RealtimeThreads"] boolValue];
    if (keep || (policy != SCHED_RR && policy != SCHED_FIFO)) return policy;
    static _Atomic int n; if (n++ < 3) MSLogf(@"threads: engine asked for %s scheduling - using normal scheduling at the same priority", policy == SCHED_RR ? "round-robin real-time" : "FIFO real-time");
    return SCHED_OTHER;
}
int ms_pthread_attr_setschedpolicy(pthread_attr_t *a, int policy) __asm("_pthread_attr_setschedpolicy");
int ms_pthread_attr_setschedpolicy(pthread_attr_t *a, int policy) {
    static int (*real)(pthread_attr_t *, int); if (!real) real = (int (*)(pthread_attr_t *, int))dlsym(RTLD_NEXT, "pthread_attr_setschedpolicy");
    return real(a, MSThreadPolicy(policy));
}
int ms_pthread_setschedparam(pthread_t t, int policy, const struct sched_param *p) __asm("_pthread_setschedparam");
int ms_pthread_setschedparam(pthread_t t, int policy, const struct sched_param *p) {
    static int (*real)(pthread_t, int, const struct sched_param *); if (!real) real = (int (*)(pthread_t, int, const struct sched_param *))dlsym(RTLD_NEXT, "pthread_setschedparam");
    return real(t, MSThreadPolicy(policy), p);
}
int ms_sched_yield(void) __asm("_sched_yield");
int ms_sched_yield(void) {
    static int (*real)(void); static int on = -1;
    if (!real) real = dlsym(dlopen("/usr/lib/system/libsystem_c.dylib", RTLD_NOLOAD | RTLD_LAZY), "sched_yield");
    if (on < 0) on = ![MSConfig()[@"YieldBackoff"] isEqual:@NO];
    static __thread unsigned run; static __thread uint64_t last;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    run = now - last > 1000000 ? 1 : run + 1; last = now; g_yields++;
    if (on && run > 32) {
        struct timespec ts = { 0, run > 256 ? 100000 : 20000 }; g_yieldSleeps++;
        nanosleep(&ts, NULL); return 0;
    }
    return real ? real() : 0;
}
/* ---------------------------------------------------------------- address-space budget (mmap/munmap/madvise/mprotect)
 * Before main() the engine reserves ~118 GB of anonymous address space (16+64+32+4+1+1+0.5 GB). With the
 * extended-virtual-addressing entitlement an iPhone 16 Pro Max gets one 64 GB region (0x70_0000_0000-0x80_0000_0000)
 * plus ~1 GB, so the 64 GB reservation fails and the engine writes through the NULL it gets back.
 * The engine finds a pointer's pool by address range [base, base+requested), so ranges must never overlap: simply
 * shrinking every pool breaks frees. Instead every reservation the kernel can satisfy is left alone, and the one
 * that can't is placed at the very TOP of the address space with a smaller real backing (TopRealGB, default 1):
 * the unbacked rest of its range lies above the highest mappable address, where no other pointer can ever be.
 * The pools are bump allocators that only touch what they hand out; munmap/madvise/mprotect are clipped to what
 * is really mapped. Tunable in macshim.plist: TopRealGB. */
typedef struct { uintptr_t base, real, asked; } MSRegion;
static MSRegion g_regions[8]; static int g_nregions; static os_unfair_lock g_reglock = OS_UNFAIR_LOCK_INIT;
static NSString *MSCallerStr(void *ra) {      /* "image@0xaddr" with the image's unslid vmaddr, so it matches otool/objdump */
    Dl_info i; if (!dladdr(ra, &i)) return [NSString stringWithFormat:@"%p", ra];
    const char *n = strrchr(i.dli_fname, '/'); intptr_t slide = 0;
    for (uint32_t k = 0; k < _dyld_image_count(); k++) if (_dyld_get_image_header(k) == i.dli_fbase) slide = _dyld_get_image_vmaddr_slide(k);
    return [NSString stringWithFormat:@"%s@%#lx", n ? n + 1 : i.dli_fname, (unsigned long)((uintptr_t)ra - slide)];
}
static NSDictionary *MSConfig(void);
static NSInteger MSPref(NSString *k, NSInteger def);
static double MSCfgD(NSString *k, double def) { id v = MSConfig()[k]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def; }
/* clip [p, p+len) against top-placed regions; returns the length that is really mapped from p (0 = nothing real) */
static size_t MSClip(uintptr_t p, size_t len, BOOL *inRegion) {
    size_t out = len; *inRegion = NO;
    os_unfair_lock_lock(&g_reglock);
    for (int i = 0; i < g_nregions; i++) {
        MSRegion r = g_regions[i];
        if (p >= r.base && p < r.base + r.asked) { *inRegion = YES; uintptr_t end = r.base + r.real; out = p >= end ? 0 : (p + len > end ? end - p : len); break; }
    }
    os_unfair_lock_unlock(&g_reglock);
    return out;
}
/* largest free block [lo, hi) of address space, found by probing (1 GB precision) */
static BOOL MSLargestFree(uintptr_t *lo, size_t *size) {
    size_t a = (size_t)1 << 30, b = (size_t)1 << 40; void *best = NULL; size_t bestSz = 0;
    while (a <= b) {
        size_t m = ((a + b) / 2) & ~(((size_t)1 << 30) - 1); if (m < ((size_t)1 << 30)) break;
        void *p = kmmap(NULL, m, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED) { kmunmap(p, m); best = p; bestSz = m; a = m + ((size_t)1 << 30); } else b = m - ((size_t)1 << 30);
    }
    if (!best) return NO; *lo = (uintptr_t)best; *size = bestSz; return YES;
}
static void *MSPlaceAtTop(size_t len, int prot, int flags) {
    uintptr_t lo; size_t free_; if (!MSLargestFree(&lo, &free_)) return MAP_FAILED;
    uintptr_t top = lo + free_;
    size_t real = (size_t)(MSCfgD(@"TopRealGB", 1) * 1073741824.0) & ~(size_t)0xfffffff;
    if (real > free_) real = free_;
    void *hint = (void *)(top - real), *p = kmmap(hint, real, prot, flags & ~MAP_FIXED, -1, 0);
    if (p != hint) { if (p != MAP_FAILED) kmunmap(p, real); MSLogf(@"top placement failed (wanted %p, got %p)", hint, p); return MAP_FAILED; }
    os_unfair_lock_lock(&g_reglock); g_regions[g_nregions++] = (MSRegion){ (uintptr_t)p, real, len }; os_unfair_lock_unlock(&g_reglock);
    MSLogf(@"reservation of %.2f GB does not fit (largest free %.2f GB): placed at top of address space %p, %.2f GB backed, rest above the VA limit",
           len / 1073741824.0, free_ / 1073741824.0, p, real / 1073741824.0);
    return p;
}
static NSString *MSBacktraceStr(int depth) {
    void *f[16]; int n = backtrace(f, 16); NSMutableArray *a = [NSMutableArray array];
    for (int k = 1; k < n && (int)a.count < depth; k++) [a addObject:MSCallerStr(f[k])];
    return [a componentsJoinedByString:@" < "];
}
/* Pool reservations, new layout (needs the pool-end patch from ios_retarget.py): the engine's two reserve functions
 * do  bl mmap ; cmn x0,#1 ; b.eq fail ; add x1,x0,x19  and keep [base, x1) as the pool. The patch NOPs the add, so the
 * pool end is the x1 this mmap returns: the shim maps a smaller pool (PoolCapGB, default 8) and tells the engine the
 * real end. No overlap, nothing above the VA limit, and ~20 GB of the 64 GB region stays free for the GPU driver
 * (IOGPU command-buffer storage) and malloc. Without that headroom the first render pass aborted in
 * IOGPUMetalCommandBufferStorageAllocResourceAtIndex. */
typedef struct { void *p; uintptr_t end; } MSMapRet;      /* returned in x0 / x1 */
typedef struct { uintptr_t base; size_t real, asked, guard; } MSPool;
static MSPool g_pools[16]; static int g_npools;
static BOOL MSIsPatchedPoolSite(void *ra) {
    const uint32_t *i = (const uint32_t *)ra;               /* ra = instruction after the bl */
    return MSCallerIsMainExe(ra) && i[0] == 0xb100041f && (i[1] & 0xff00001f) == 0x54000000 && i[2] == 0xd503201f;
}
/* Without the extended-virtual-addressing entitlement there is no 64 GB region at 0x70_0000_0000, only the normal
 * (much smaller) address space. Then the pools are sized to fit it ("compact" layout): about CompactShare (default
 * 0.45) of the address space that can be reserved goes to the pools, the rest stays free for the GPU driver and malloc.
 * Pools only touch what they hand out (the game used ~0.5-1.2 GB of each 8 GB pool), so smaller caps cost nothing
 * until a pool really fills. CompactPools = YES forces this layout, NO never uses it. */
static int g_vaCompact = -1; static double g_vaBudgetGB, g_vaTotalGB;
static void MSVAInit(void) {
    if (g_vaCompact >= 0) return;
    void *t = kmmap((void *)0x7000000000, (size_t)1 << 30, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    BOOL big = t == (void *)0x7000000000; if (t != MAP_FAILED) kmunmap(t, (size_t)1 << 30);
    id force = MSConfig()[@"CompactPools"]; if (force) big = ![force boolValue];
    void *maps[256]; size_t sizes[256]; int n = 0; size_t total = 0;      /* reservable address space, 256 MB precision */
    for (size_t sz = (size_t)512 << 30; sz >= ((size_t)256 << 20) && n < 256; ) {
        void *p = kmmap(NULL, sz, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) { sz >>= 1; continue; }
        maps[n] = p; sizes[n++] = sz; total += sz;
    }
    for (int i = 0; i < n; i++) kmunmap(maps[i], sizes[i]);
    g_vaTotalGB = total / 1073741824.0; g_vaCompact = !big;
    double share = MSCfgD(@"CompactShare", 0.45); if (share < 0.1) share = 0.1; if (share > 0.8) share = 0.8;
    g_vaBudgetGB = g_vaTotalGB * share;
    MSLogf(@"address space: %.1f GB reservable, %@", g_vaTotalGB, big ? @"extended (64 GB region): normal pool layout"
           : [NSString stringWithFormat:@"no extended-virtual-addressing: compact pools, %.1f GB for them", g_vaBudgetGB]);
}
/* compact cap for a pool the engine asked `asked` bytes for: the engine makes 3 big pools (16/32/64 GB), up to ~8 of
   4 GB and a few of <= 1 GB; the budget is split by weight 4 / 1 / 0.5 */
static double MSCompactCapGB(size_t asked) {
    double u = g_vaBudgetGB / (3 * 4 + 8 * 1 + 3 * 0.5), a = asked / 1073741824.0;
    if (a >= 8) return fmin(fmax(4 * u, 1), 8);
    if (a >= 2) return fmin(fmax(u, 0.5), a);
    return fmin(a, fmax(0.25, u / 2));
}
static void *MSMmapOld(void *addr, size_t len, int prot, int flags, int fd, off_t off);
MSMapRet ms_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) __asm("_mmap");
MSMapRet ms_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    void *ra = __builtin_return_address(0);
    if (!addr && fd < 0 && (flags & MAP_ANON) && !(flags & MAP_FIXED) && len >= ((size_t)1 << 30) && MSIsPatchedPoolSite(ra)) {
        MSVAInit();
        /* per-pool override: PoolCap16GB, PoolCap64GB, ... (by the size the engine asked for), else PoolCapGB */
        double capGB = MSCfgD([NSString stringWithFormat:@"PoolCap%zuGB", len >> 30], MSCfgD(@"PoolCapGB", g_vaCompact ? MSCompactCapGB(len) : 8));
        size_t cap = (size_t)(capGB * 1073741824.0) & ~(size_t)0x3fff, real = len < cap ? len : cap, min = (size_t)256 << 20;
        /* a shrunk pool gets a no-access guard behind it: an engine that writes past the end it was told then faults
           right there (and the crash log names the pool) instead of silently corrupting the next pool */
        size_t guard = real < len ? (size_t)(MSCfgD(@"PoolGuardMB", g_vaCompact ? 16 : 512) * 1048576.0) & ~(size_t)0x3fff : 0;
        void *p = MAP_FAILED;
        /* Keep pools below 64 GB like on macOS (where big mmaps land around 0x3_0000_0000): left to itself iOS puts
           them at 0x70_0000_0000+, and the engine's allocators corrupt their free lists with pointers that high
           (tagged/packed pointers that assume ~36-bit addresses). First fit from 8 GB up, 1 GB steps. */
        /* Each pool on a boundary of its own (power-of-two) size, like the engine's allocators may assume when they
           round an address down to find a block header. Placed upward from 0x70_0000_0000 by hint. */
        if (g_vaCompact && ![MSConfig()[@"PoolAlign"] isEqual:@NO]) {
            /* compact: anywhere the kernel has room, still on a boundary of the pool's own (power-of-two) size -
               over-reserve by the alignment, then give back the head and the tail */
            size_t al = (size_t)1 << 20; while (al < real && al < ((size_t)8 << 30)) al <<= 1;
            void *q = kmmap(NULL, real + guard + al, prot, flags, -1, 0);
            if (q != MAP_FAILED) {
                uintptr_t a = ((uintptr_t)q + al - 1) & ~(uintptr_t)(al - 1), head = a - (uintptr_t)q, tail = al - head;
                if (head) kmunmap(q, head);
                if (tail) kmunmap((void *)(a + real + guard), tail);
                p = (void *)a;
            } else MSLogf(@"pool of %.2f GB (+%zu MB alignment): no room - trying smaller", real / 1073741824.0, al >> 20);
        }
        if (!g_vaCompact && ![MSConfig()[@"PoolAlign"] isEqual:@NO]) {
            static uintptr_t next = (uintptr_t)0x7000000000;
            size_t al = (size_t)1 << 20; while (al < real && al < ((size_t)8 << 30)) al <<= 1;
            for (int tries = 0; tries < 64 && p == MAP_FAILED; tries++) {
                uintptr_t h = (next + al - 1) & ~(uintptr_t)(al - 1);
                void *q = kmmap((void *)h, real + guard, prot, flags, -1, 0);
                if (q == (void *)h) { p = q; next = h + real + guard; }
                else { if (q != MAP_FAILED) kmunmap(q, real + guard); next = h + al; }
            }
            if (p == MAP_FAILED) MSLogf(@"pool of %.2f GB: no %zu MB-aligned slot", real / 1073741824.0, al >> 20);
        }
        if (p == MAP_FAILED && [MSConfig()[@"PoolsLow"] boolValue]) {
            static uintptr_t cursor = (uintptr_t)8 << 30; const uintptr_t limit = (uintptr_t)64 << 30;
            static dispatch_once_t once; dispatch_once(&once, ^{        /* what occupies the low 64 GB? */
                vm_address_t a = 0; vm_size_t sz; vm_region_basic_info_data_64_t vi; mach_msg_type_number_t cnt; mach_port_t on; uintptr_t last = 0;
                NSMutableString *m = [NSMutableString string];
                for (int n = 0; n < 4000; n++) {
                    cnt = VM_REGION_BASIC_INFO_COUNT_64;
                    if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&vi, &cnt, &on) != KERN_SUCCESS) break;
                    if (a >= ((uintptr_t)1 << 40)) break;
                    if (a - last >= ((uintptr_t)256 << 20)) [m appendFormat:@" free %#lx-%#lx (%.1f GB);", (unsigned long)last, (unsigned long)a, (a - last) / 1073741824.0];
                    if (sz >= ((uintptr_t)512 << 20)) [m appendFormat:@" [used %#lx-%#lx %.1f GB prot %d/%d share %d]", (unsigned long)a, (unsigned long)(a + sz), sz / 1073741824.0, vi.protection, vi.max_protection, vi.shared];
                    last = a + sz; a += sz;
                }
                MSLogf(@"VA gaps >= 256 MB:%@ top of last region %#lx", m, (unsigned long)last);
                void *t = kmmap((void *)((uintptr_t)8 << 30), (size_t)1 << 30, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
                MSLogf(@"probe mmap(hint 8 GB, 1 GB) -> %p errno %d", t, errno); if (t != MAP_FAILED) kmunmap(t, (size_t)1 << 30);
                uintptr_t lo; size_t fr; if (MSLargestFree(&lo, &fr)) MSLogf(@"largest free VA block: %#lx, %.0f GB", (unsigned long)lo, fr / 1073741824.0);
                size_t tot = 0; void *blocks[64]; int nb = 0;              /* total mappable VA in 4 GB pieces */
                for (; nb < 64; nb++) { blocks[nb] = kmmap(NULL, (size_t)4 << 30, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); if (blocks[nb] == MAP_FAILED) break; tot += (size_t)4 << 30; }
                for (int i = 0; i < nb; i++) kmunmap(blocks[i], (size_t)4 << 30);
                MSLogf(@"total free VA (4 GB pieces, max 256): %.0f GB", tot / 1073741824.0);
            });
            for (uintptr_t h = cursor; h + real + guard <= limit; h += (uintptr_t)1 << 30) {
                void *q = kmmap((void *)h, real + guard, prot, flags, -1, 0);
                if (q == (void *)h) { p = q; cursor = (h + real + guard + ((1u << 30) - 1)) & ~(uintptr_t)((1u << 30) - 1); break; }
                if (q != MAP_FAILED) kmunmap(q, real + guard);
            }
            if (p == MAP_FAILED) MSLogf(@"pool of %.2f GB does not fit below 64 GB - placing it high", real / 1073741824.0);
        }
        if (p == MAP_FAILED)
        for (; real >= min; real = (real / 2) & ~(size_t)0x3fff) if ((p = kmmap(NULL, real + guard, prot, flags, -1, 0)) != MAP_FAILED) break;
        if (p != MAP_FAILED) {
            if (guard) kmprotect((char *)p + real, guard, PROT_NONE);
            if (g_npools < 16) g_pools[g_npools++] = (MSPool){ (uintptr_t)p, real, len, guard };
            MSLogf(@"pool reservation %.2f GB -> %.2f GB at %p (engine told the real end)%@ from %@", len / 1073741824.0, real / 1073741824.0, p,
                   guard ? [NSString stringWithFormat:@", %zu MB guard behind it", guard >> 20] : @"", MSBacktraceStr(8));
            return (MSMapRet){ p, (uintptr_t)p + real };
        }
        MSLogf(@"pool reservation %.2f GB FAILED even at %.0f MB (errno %d)", len / 1073741824.0, min / 1048576.0, errno);
        errno = ENOMEM; return (MSMapRet){ MAP_FAILED, 0 };
    }
    static int warned; if (!warned && len >= ((size_t)8 << 30) && MSCallerIsMainExe(ra)) { warned = 1; MSLogf(@"pool-end patch NOT found in the game binary: using the old top-of-address-space layout (rebuild with the current tools/ios_retarget.py)"); }
    void *p = MSMmapOld(addr, len, prot, flags, fd, off);
    return (MSMapRet){ p, p == MAP_FAILED ? 0 : (uintptr_t)p + len };
}
/* old layout, used when the binary is not patched: see the comment above MSRegion */
static void *MSMmapOld(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    void *r = kmmap(addr, len, prot, flags, fd, off);
    if (r == MAP_FAILED && errno == ENOMEM && !addr && (flags & MAP_ANON) && !(flags & MAP_FIXED) && g_nregions < 1) {
        void *t = MSPlaceAtTop(len, prot, flags);
        if (t != MAP_FAILED) return t;
        errno = ENOMEM;
    } else if (r == MAP_FAILED && errno == ENOMEM && !addr && (flags & MAP_ANON) && !(flags & MAP_FIXED) && g_nregions < 8
               && MSCfgD(@"FallbackRealGB", 0.5) > 0) {
        /* experimental: no top slot left. Back a smaller part and leave a PROT_NONE guard behind it. The pool's
           address range can now overlap later mappings, so this may misattribute frees. */
        size_t real = (size_t)(MSCfgD(@"FallbackRealGB", 0.5) * 1073741824.0) & ~(size_t)0xfffff, guard = (size_t)64 << 20;
        if (real < len) {
            void *p = kmmap(NULL, real + guard, PROT_NONE, flags, -1, 0);
            if (p != MAP_FAILED && (prot == PROT_NONE || kmprotect(p, real, prot) == 0)) {
                os_unfair_lock_lock(&g_reglock); g_regions[g_nregions++] = (MSRegion){ (uintptr_t)p, real, len }; os_unfair_lock_unlock(&g_reglock);
                MSLogf(@"FALLBACK: reservation of %.2f GB shrunk to %.2f GB + guard at %p (from %@)", len / 1073741824.0, real / 1073741824.0, p, MSBacktraceStr(4));
                return p;
            }
            if (p != MAP_FAILED) kmunmap(p, real + guard);
        }
        errno = ENOMEM;
    }
    if (fd >= 0) {          /* file mappings: external drives (userfsd/FSKit) may refuse mmap; log, and emulate read-only ones */
        static int nf; if (nf++ < 40 || r == MAP_FAILED) MSLogf(@"file mmap fd=%d len=%#zx off=%#llx prot=%d flags=%#x -> %p%s", fd, len, (long long)off, prot, flags, r, r == MAP_FAILED ? strerror(errno) : "");
        if (r == MAP_FAILED && !(prot & PROT_WRITE && flags & MAP_SHARED) && len <= ((size_t)256 << 20)) {
            void *a = kmmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
            if (a != MAP_FAILED) {
                size_t got = 0; ssize_t k;
                while (got < len && (k = pread(fd, (char *)a + got, len - got, off + (off_t)got)) > 0) got += (size_t)k;
                kmprotect(a, len, prot); MSLogf(@"  emulated with pread (%zu bytes read)", got); return a;
            }
        }
        return r;
    }
    if (r == MAP_FAILED || len >= ((size_t)1 << 30))
        MSLogf(@"mmap %.2f GB prot=%d flags=%#x -> %p%@", len / 1073741824.0, prot, flags, r, r == MAP_FAILED ? [NSString stringWithFormat:@" FAILED errno=%d (from %@)", errno, MSBacktraceStr(5)] : @"");
    return r;
}
int ms_munmap(void *p, size_t len) __asm("_munmap");
int ms_munmap(void *p, size_t len) {
    os_unfair_lock_lock(&g_reglock);
    for (int i = 0; i < g_nregions; i++) if (g_regions[i].base == (uintptr_t)p && len >= g_regions[i].asked) {   /* whole reservation released */
        MSRegion r = g_regions[i]; g_regions[i] = g_regions[--g_nregions]; os_unfair_lock_unlock(&g_reglock);
        return kmunmap(p, r.real);
    }
    os_unfair_lock_unlock(&g_reglock);
    BOOL in; size_t n = MSClip((uintptr_t)p, len, &in); if (in && !n) return 0;
    return kmunmap(p, n);
}
int ms_madvise(void *p, size_t len, int adv) __asm("_madvise");
/* counts per advice value; KeepFreedPages = YES turns MADV_FREE / MADV_FREE_REUSABLE / MADV_DONTNEED into no-ops:
   iOS really reclaims such pages under memory pressure (macOS rarely does), and they come back zero-filled */
static _Atomic long long g_madv[16], g_madvBytes[16];
static NSString *MSMadviseStats(void) {
    NSMutableString *m = [NSMutableString string];
    for (int i = 0; i < 16; i++) if (g_madv[i]) [m appendFormat:@" adv%d: %lld calls %.0f MB;", i, g_madv[i], g_madvBytes[i] / 1048576.0];
    return m;
}
int ms_madvise(void *p, size_t len, int adv) {
    if (adv >= 0 && adv < 16) { g_madv[adv]++; g_madvBytes[adv] += (long long)len; }
    static int keep = -1; if (keep < 0) keep = [MSConfig()[@"KeepFreedPages"] boolValue];
    if (keep && (adv == MADV_FREE || adv == MADV_FREE_REUSABLE || adv == MADV_DONTNEED)) return 0;
    BOOL in; size_t n = MSClip((uintptr_t)p, len, &in); if (in && !n) return 0; return kmadvise(p, n, adv);
}
int ms_mprotect(void *p, size_t len, int prot) __asm("_mprotect");
int ms_mprotect(void *p, size_t len, int prot) {
    BOOL in; size_t n = MSClip((uintptr_t)p, len, &in);
    if (in && n < len) MSLogf(@"mprotect %p +%#zx past the real end of a shrunk reservation (clipped to %#zx)", p, len, n);
    if (in && !n) return 0; return kmprotect(p, n, prot);
}

/* Diagnostic: how much address space does this process get? (largest single anon mapping + total) */
static void MSProbeVA(void) {
    void *maps[256]; size_t sizes[256]; int n = 0; size_t total = 0, first = 0;
    for (size_t sz = (size_t)512 << 30; sz >= ((size_t)1 << 30) && n < 256; ) {
        void *p = kmmap(NULL, sz, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) { sz >>= 1; continue; }
        if (!first) first = sz; maps[n] = p; sizes[n++] = sz; total += sz;
    }
    MSLogf(@"VA probe: largest single mapping %.0f GB, total reservable %.0f GB in %d chunks", first / 1073741824.0, total / 1073741824.0, n);
    for (int i = 0; i < n; i++) kmunmap(maps[i], sizes[i]);
}


/* ---------------------------------------------------------------- case-insensitive game paths
 * The Mac build expects a case-insensitive file system (it opens archive/mac/content, GOG ships archive/Mac/content).
 * App containers on iOS are case-sensitive, so when a file call from the game fails with ENOENT the path is resolved
 * one component at a time ignoring case (results cached) and the call is retried. Only paths that resolve change. */
#include <dirent.h>
static DIR *(*k_opendir)(const char *); static char *(*k_realpath)(const char *, char *); static int (*k_stat)(const char *, struct stat *);
static int (*k_open)(const char *, int, ...); static FILE *(*k_fopen)(const char *, const char *); static int (*k_access)(const char *, int);
__attribute__((constructor(102))) static void MSResolveFS(void) {
    k_opendir = (DIR *(*)(const char *))dlsym(RTLD_NEXT, "opendir"); k_realpath = (char *(*)(const char *, char *))dlsym(RTLD_NEXT, "realpath$DARWIN_EXTSN");
    k_stat = (int (*)(const char *, struct stat *))dlsym(RTLD_NEXT, "stat"); k_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    k_fopen = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen"); k_access = (int (*)(const char *, int))dlsym(RTLD_NEXT, "access");
}
static NSMutableDictionary *g_caseCache; static os_unfair_lock g_caseLock = OS_UNFAIR_LOCK_INIT;
/* returns a malloc'd path that exists with different case, or NULL */
static char *MSCaseFix(const char *path) {
    if (!path || !*path) return NULL;
    @autoreleasepool {
        NSString *in = [NSString stringWithUTF8String:path]; if (!in) return NULL;
        if (![in isAbsolutePath]) in = [[NSFileManager.defaultManager currentDirectoryPath] stringByAppendingPathComponent:in];
        NSString *key = in.lowercaseString;
        os_unfair_lock_lock(&g_caseLock);
        if (!g_caseCache) g_caseCache = [NSMutableDictionary dictionary];
        id hit = g_caseCache[key];
        os_unfair_lock_unlock(&g_caseLock);
        if (hit) return hit == NSNull.null ? NULL : strdup([hit fileSystemRepresentation]);
        NSArray *parts = in.pathComponents; NSString *cur = @"/"; BOOL changed = NO;
        for (NSUInteger i = 1; i < parts.count; i++) {
            NSString *want = parts[i], *next = [cur stringByAppendingPathComponent:want]; struct stat st;
            if (k_stat(next.fileSystemRepresentation, &st) != 0) {
                NSString *found = nil;
                for (NSString *e in [NSFileManager.defaultManager contentsOfDirectoryAtPath:cur error:nil])
                    if ([e caseInsensitiveCompare:want] == NSOrderedSame) { found = e; break; }
                if (!found) { cur = nil; break; }
                next = [cur stringByAppendingPathComponent:found]; changed = YES;
            }
            cur = next;
        }
        NSString *res = (cur && changed) ? cur : nil;
        os_unfair_lock_lock(&g_caseLock); g_caseCache[key] = res ?: (id)NSNull.null; os_unfair_lock_unlock(&g_caseLock);
        if (res) { static int n; if (n++ < 20) MSLogf(@"case fix: %s -> %@", path, res); }
        return res ? strdup(res.fileSystemRepresentation) : NULL;
    }
}
/* path-length audit: REDengine comes from Windows (260-char paths); iOS container paths are ~80 chars longer than
   macOS home paths. Logs every new longest path and anything over 200 chars (first 40). */
static _Atomic size_t g_maxPath;
static void MSNotePath(const char *fn, const char *path) {
    if (!path) return; size_t l = strlen(path);
    static _Atomic int n;
    if (l > g_maxPath) { g_maxPath = l; MSLogf(@"path: new longest %zu chars in %s: %s", l, fn, path); }
    else if (l >= 200 && n++ < 40) MSLogf(@"path: %zu chars in %s: %s", l, fn, path);
}
#define MS_CASE_RETRY(CALL_ORIG, FAILED, CALL_FIXED) \
    MSNotePath(__func__, path); \
    __typeof__(CALL_ORIG) r = CALL_ORIG; \
    if ((FAILED) && errno == ENOENT) { char *f = MSCaseFix(path); if (f) { r = CALL_FIXED; free(f); } else errno = ENOENT; } \
    return r;
DIR *ms_opendir(const char *path) __asm("_opendir");
DIR *ms_opendir(const char *path) { MS_CASE_RETRY(k_opendir(path), !r, k_opendir(f)) }
char *ms_realpath(const char *path, char *out) __asm("_realpath$DARWIN_EXTSN");
static char *ms_realpath2(const char *path, char *out) { MS_CASE_RETRY(k_realpath(path, out), !r, k_realpath(f, out)) }
char *ms_realpath(const char *path, char *out) {
    char *r = ms_realpath2(path, out);
    if (r) { size_t l = strlen(r); static _Atomic int n; if (l >= 200 && n++ < 20) MSLogf(@"path: realpath result %zu chars into %s buffer: %s", l, out ? "caller's" : "new", r); }
    return r;
}
int ms_stat(const char *path, struct stat *st) __asm("_stat");
int ms_stat(const char *path, struct stat *st) { MS_CASE_RETRY(k_stat(path, st), r != 0, k_stat(f, st)) }
int ms_access(const char *path, int m) __asm("_access");
int ms_access(const char *path, int m) { MS_CASE_RETRY(k_access(path, m), r != 0, k_access(f, m)) }
FILE *ms_fopen(const char *path, const char *mode) __asm("_fopen");
FILE *ms_fopen(const char *path, const char *mode) { MS_CASE_RETRY(k_fopen(path, mode), !r, k_fopen(f, mode)) }
/* ---------------------------------------------------------------- external SSD: survive it dropping off the bus
 * Under load an SSD on the phone's USB-C port can disconnect for a moment (seen: every read on every open file fails
 * with EIO, F_GETPATH fails, and on the next launch the bookmark doesn't resolve until it remounts). The engine treats
 * a failed read as fatal, so instead: remember the path and offset of every game file the engine opens, and when a read
 * fails block the IO thread, wait for the volume to come back, open the file again and send that fd's reads and seeks
 * to the new file from then on (the engine keeps its own fd number; dup2 onto it left it EBADF on device). Game-file
 * reads are also throttled to keep the drive's power draw down (macshim.plist: MaxParallelReads, default 1;
 * ReadChunkKB, default 1024; MaxReadMBps, default 120, 0 = no cap). */
#define MS_MAXFD 4096
static char *g_fdPath[MS_MAXFD];                 /* absolute path of game files opened with open(), by fd */
static off_t g_fdPos[MS_MAXFD];                  /* their file offset, kept by read()/lseek() so it survives a dead fd */
static int g_fdAlt[MS_MAXFD];                    /* replacement fd + 1 after a reopen, 0 = none */
static os_unfair_lock g_fdLock = OS_UNFAIR_LOCK_INIT;
static pthread_mutex_t g_driveLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_semaphore_t g_readSlots;
static UILabel *g_driveBanner;
static int (*k_close)(int);
static off_t (*k_lseek)(int, off_t, int);
static ssize_t (*k_read)(int, void *, size_t);
static void MSIOSyms(void) {
    if (!k_close) k_close = (int (*)(int))dlsym(RTLD_NEXT, "close");
    if (!k_lseek) k_lseek = (off_t (*)(int, off_t, int))dlsym(RTLD_NEXT, "lseek");
    if (!k_read) k_read = (ssize_t (*)(int, void *, size_t))dlsym(RTLD_NEXT, "read");
}

static int MSOpenCase(const char *path, int flags, int mode) { MS_CASE_RETRY(k_open(path, flags, mode), r < 0, k_open(f, flags, mode)) }
static BOOL MSDriveErr(int e) { return e == EIO || e == ENXIO || e == ENODEV || e == ETIMEDOUT || e == ESTALE || e == ENOENT || e == EPERM || e == EACCES; }
static BOOL MSDriveUp(void) {
    NSString *root = g_root; if (!root) return NO;
    struct stat st; return k_stat([root stringByAppendingPathComponent:@"archive"].fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode);
}
static char *MSAbsPath(const char *path) {
    if (path[0] == '/') return strdup(path);
    char cwd[MAXPATHLEN]; if (!getcwd(cwd, sizeof cwd)) return NULL;
    char *r = NULL; asprintf(&r, "%s/%s", cwd, path); return r;
}
static BOOL MSTracked(int fd) { return fd >= 0 && fd < MS_MAXFD && g_fdPath[fd]; }
static int MSRealFd(int fd) {                    /* the fd that really serves a tracked game fd */
    if (fd < 0 || fd >= MS_MAXFD) return fd;
    int a = g_fdAlt[fd]; return a ? a - 1 : fd;
}
static void MSUntrackFd(int fd) {
    if (fd < 0 || fd >= MS_MAXFD) return;
    os_unfair_lock_lock(&g_fdLock); char *p = g_fdPath[fd]; int a = g_fdAlt[fd]; g_fdPath[fd] = NULL; g_fdAlt[fd] = 0; os_unfair_lock_unlock(&g_fdLock);
    free(p); if (a) k_close(a - 1);
}
static void MSTrackFd(int fd, const char *path) {
    if (!g_external || fd < 0 || fd >= MS_MAXFD) return;
    MSUntrackFd(fd);                                    /* the engine may have closed this number some other way */
    char *abs = MSAbsPath(path); if (!abs) return;
    NSString *root = g_root;
    if (!root || strncmp(abs, root.fileSystemRepresentation, strlen(root.fileSystemRepresentation)) != 0) { free(abs); return; }
    os_unfair_lock_lock(&g_fdLock); g_fdPath[fd] = abs; g_fdPos[fd] = 0; os_unfair_lock_unlock(&g_fdLock);
}
static char *MSFdPath(int fd) {                  /* malloc'd copy or NULL */
    if (fd < 0 || fd >= MS_MAXFD) return NULL;
    os_unfair_lock_lock(&g_fdLock); char *p = g_fdPath[fd] ? strdup(g_fdPath[fd]) : NULL; os_unfair_lock_unlock(&g_fdLock); return p;
}
static void MSBanner(NSString *text) {
    MSMainAsync(^{
        static UIWindow *w;
        if (!text) { [g_driveBanner removeFromSuperview]; g_driveBanner = nil; w.hidden = YES; return; }
        if (!w) {
            UIWindowScene *sc = MSAppScene();
            if (!sc) return;
            w = [[UIWindow alloc] initWithWindowScene:sc]; w.windowLevel = UIWindowLevelAlert + 10; w.userInteractionEnabled = NO;
            w.backgroundColor = UIColor.clearColor; w.rootViewController = [UIViewController new];
        }
        w.hidden = NO;
        if (!g_driveBanner) {
            g_driveBanner = [UILabel new]; g_driveBanner.numberOfLines = 0; g_driveBanner.textAlignment = NSTextAlignmentCenter;
            g_driveBanner.textColor = UIColor.whiteColor; g_driveBanner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
            g_driveBanner.font = [UIFont boldSystemFontOfSize:18]; g_driveBanner.frame = w.bounds;
            g_driveBanner.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
        g_driveBanner.text = text; [w addSubview:g_driveBanner];
    });
}
/* Blocks until the game folder is reachable again (YES) or gives up after ~3 minutes (NO). One thread waits, the rest
 * queue on the lock and return at once when the drive is back. */
static BOOL MSWaitForDrive(const char *why) {
    if (!g_external) return NO;
    pthread_mutex_lock(&g_driveLock);
    BOOL up = MSDriveUp();
    if (!up) {
        static int drops; MSLogf(@"SSD unreachable (%s) - drop #%d, waiting for it to come back", why, ++drops);
        MSBanner(@"Lost connection to the SSD.\nUnplug it and plug it back in - the game continues when it's back.");
        double t0 = CACurrentMediaTime();
        for (int i = 0; !up && CACurrentMediaTime() - t0 < 180; i++) {
            usleep(250000);
            if (i % 8 == 7) @autoreleasepool {              /* every 2 s: the volume may remount under a new path */
                NSURL *u = MSResolveBookmark();
                if (u && ![u.path isEqualToString:g_root]) {
                    MSLogf(@"game folder moved: %@ -> %@", g_root, u.path);
                    NSString *old = g_root; g_scopedURL = u; g_root = u.path; chdir(u.path.fileSystemRepresentation);
                    os_unfair_lock_lock(&g_fdLock);
                    size_t ol = strlen(old.fileSystemRepresentation);
                    for (int fd = 0; fd < MS_MAXFD; fd++) if (g_fdPath[fd] && !strncmp(g_fdPath[fd], old.fileSystemRepresentation, ol)) {
                        char *np = NULL; asprintf(&np, "%s%s", u.path.fileSystemRepresentation, g_fdPath[fd] + ol); free(g_fdPath[fd]); g_fdPath[fd] = np;
                    }
                    os_unfair_lock_unlock(&g_fdLock);
                }
            }
            up = MSDriveUp();
        }
        MSLogf(up ? @"SSD back after %.1f s" : @"SSD still gone after %.0f s - giving up", CACurrentMediaTime() - t0);
        MSBanner(nil);
    }
    pthread_mutex_unlock(&g_driveLock);
    return up;
}
/* open a tracked game file again at `off` and route the fd's IO to it */
static BOOL MSReopenFd(int fd, off_t off) {
    for (int attempt = 0; attempt < 20; attempt++) {
        if (!MSWaitForDrive("read")) return NO;
        char *p = MSFdPath(fd); if (!p) return NO;
        int nfd = MSOpenCase(p, O_RDONLY, 0);
        if (nfd >= 0 && k_lseek(nfd, off, SEEK_SET) == off) {
            os_unfair_lock_lock(&g_fdLock); int old = g_fdAlt[fd]; g_fdAlt[fd] = nfd + 1; g_fdPos[fd] = off; os_unfair_lock_unlock(&g_fdLock);
            if (old) k_close(old - 1);
            MSLogf(@"reopened fd %d as %d (%s) at %lld", fd, nfd, p, (long long)off);
            free(p); return YES;
        }
        MSLogf(@"reopen %s failed: %s", p, strerror(errno)); free(p);
        if (nfd >= 0) k_close(nfd);
        usleep(500000);
    }
    return NO;
}

int ms_open(const char *path, int flags, ...) __asm("_open");
int ms_open(const char *path, int flags, ...) {
    MSIOSyms();
    { size_t l = path ? strlen(path) : 0;                 /* test aid: NoVideo = YES hides Bink videos (.bk2) */
      if (l > 4 && !strcasecmp(path + l - 4, ".bk2")) {
          static int nv = -1; if (nv < 0) nv = [MSConfig()[@"NoVideo"] boolValue];
          static _Atomic int n; if (n++ < 6) MSLogf(@"video open: %s%s", strrchr(path, '/') ? strrchr(path, '/') + 1 : path, nv ? " (hidden: NoVideo)" : "");
          if (nv) { errno = ENOENT; return -1; }
      } }
    int mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    int fd = MSOpenCase(path, flags, mode);
    if (fd < 0 && g_external && MSDriveErr(errno) && !MSDriveUp()) {       /* opened while the SSD is away */
        int e = errno; if (MSWaitForDrive("open")) fd = MSOpenCase(path, flags, mode); else errno = e;
    }
    if (fd >= 0) MSTrackFd(fd, path);
    return fd;
}
int ms_close(int fd) __asm("_close");
int ms_close(int fd) {
    MSIOSyms();
    if (fd >= 0 && fd < MS_MAXFD && (g_fdPath[fd] || g_fdAlt[fd])) {
        BOOL alt = g_fdAlt[fd] != 0; MSUntrackFd(fd);
        int r = k_close(fd); return alt ? 0 : r;          /* the original may already be dead; the engine needn't know */
    }
    return k_close(fd);
}
off_t ms_lseek(int fd, off_t off, int whence) __asm("_lseek");
off_t ms_lseek(int fd, off_t off, int whence) {
    MSIOSyms();
    if (!MSTracked(fd)) return k_lseek(fd, off, whence);
    off_t r = k_lseek(MSRealFd(fd), off, whence);
    if (r < 0 && whence != SEEK_END) {                    /* dead fd: answer from our own offset, the next read reopens */
        r = whence == SEEK_SET ? off : g_fdPos[fd] + off;
        if (r < 0) { errno = EINVAL; return -1; }
    }
    if (r >= 0) g_fdPos[fd] = r;
    return r;
}

/* ---------------------------------------------------------------- read(): the engine's IO workers treat any failed or short read
 * as fatal ("RedIO: Failed to read %u bytes", brk in redIOWorkerGeneric.cpp). Game data on an external SSD goes through
 * userfsd, which can fail a read transiently (EIO/EINTR/EAGAIN/ETIMEDOUT) or return it short. The fast path is one plain
 * read; otherwise the rest is read with retries, then through a bounce buffer (covers EFAULT on engine pool memory),
 * then - for game files - after reopening the file (once the drive is back if it went away). Every failure is logged. */
static void MSLogReadFail(int fd, const void *buf, size_t n, size_t got, int first, int err, int tries, BOOL recovered) {
    static int logged; if (logged++ >= 60) return;
    char p[MAXPATHLEN] = "?"; char *t = MSFdPath(fd); if (t) { strlcpy(p, t, sizeof p); free(t); } else fcntl(fd, F_GETPATH, p);
    MSLogf(@"read %s: fd %d (%s) off %lld want %zu got %zu buf %p first errno %d (%s), last errno %d (%s) after %d retries",
           recovered ? "recovered" : "FAILED", fd, p, MSTracked(fd) ? (long long)g_fdPos[fd] : (long long)k_lseek(fd, 0, SEEK_CUR),
           n, got, buf, first, strerror(first), err, strerror(err), tries);
}
static ssize_t MSReadRobust(int fd, void *buf, size_t n) {
    BOOL game = MSTracked(fd);
    off_t start = game ? g_fdPos[fd] : -1;
    ssize_t r = k_read(MSRealFd(fd), buf, n);
    if (r == (ssize_t)n || r == 0 || n == 0) { if (game && r > 0) g_fdPos[fd] = start + r; return r; }
    if (!game) {                       /* pipes, sockets, ttys: a short read or EAGAIN is normal, never wait to fill the buffer */
        int e = errno; struct stat st;
        if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) { errno = e; return r; }
        errno = e;
    }
    if (!game && r < 0) start = k_lseek(fd, 0, SEEK_CUR);
    size_t got = r > 0 ? (size_t)r : 0; int err = r < 0 ? errno : 0, first = err, tries = 0, reopens = 0; char *bounce = NULL;
    while (got < n) {
        size_t want = n - got; if (bounce && want > (8u << 20)) want = 8u << 20;
        r = k_read(MSRealFd(fd), bounce ? bounce : (char *)buf + got, want);
        if (r > 0) { if (bounce) memcpy((char *)buf + got, bounce, (size_t)r); got += (size_t)r; continue; }
        if (r == 0) break;                                           /* end of file */
        err = errno; if (!first) first = err;
        if (err == EFAULT && !bounce) { bounce = malloc(8u << 20); if (bounce) continue; }
        if ((err == EINTR || err == EAGAIN) && ++tries <= 50) { usleep(1000); continue; }
        if ((err == EIO || err == ETIMEDOUT || err == EFAULT) && ++tries <= 5) { usleep(2000 * tries); continue; }
        if (err == EINVAL && game && ++tries <= 3) {                 /* userfsd answers EINVAL as the SSD drops: try a positioned read */
            r = pread(MSRealFd(fd), bounce ? bounce : (char *)buf + got, want, start + (off_t)got);
            if (r > 0) { if (bounce) memcpy((char *)buf + got, bounce, (size_t)r); got += (size_t)r; k_lseek(MSRealFd(fd), start + (off_t)got, SEEK_SET); continue; }
            if (r == 0) break;
            err = errno; usleep(5000 * tries); if (err == EINVAL) continue;
        }
        /* game file: reopen it (waiting for the SSD if it's gone) and continue where this read left off */
        if (game && (MSDriveErr(err) || err == EBADF || err == EINVAL || err == EFAULT || err == EINTR || err == EAGAIN) && reopens++ < 8) {
            if (MSReopenFd(fd, start + (off_t)got)) { tries = 0; continue; }
        }
        break;
    }
    free(bounce);
    if (game) g_fdPos[fd] = start + (off_t)got;
    MSLogReadFail(fd, buf, n, got, first, err, tries, got == n);
    if (got == 0 && r < 0) { errno = err; return -1; }
    return (ssize_t)got;
}
/* status panel: while the game loads (a black screen otherwise), show elapsed time, data read, CPU, memory and the
 * last log lines at the bottom of the screen; the same numbers go to the log every 5 s. Off with ShowStatus = NO. */
static _Atomic long long g_readBytes, g_readCalls;
static _Atomic double g_lastReadAt;
#define MS_TAIL 30
static NSString *g_logTail[MS_TAIL]; static int g_logTailN; static os_unfair_lock g_tailLock = OS_UNFAIR_LOCK_INIT;
static void MSTailAdd(NSString *m) {
    NSString *root = g_root;
    if (root.length) m = [m stringByReplacingOccurrencesOfString:root withString:@"…"];
    if (m.length > 160) m = [[m substringToIndex:160] stringByAppendingString:@"…"];
    os_unfair_lock_lock(&g_tailLock); g_logTail[g_logTailN++ % MS_TAIL] = m; os_unfair_lock_unlock(&g_tailLock);
}
static double MSCPUSeconds(void) {
    struct rusage u; getrusage(RUSAGE_SELF, &u);
    return u.ru_utime.tv_sec + u.ru_stime.tv_sec + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6;
}
/* per-thread CPU over the last interval: where the engine's CPU time goes (spinning workers vs the game thread) */
static NSString *MSThreadCPUReport(void) {
    static NSMutableDictionary *last; if (!last) last = [NSMutableDictionary dictionary];
    thread_act_array_t th; mach_msg_type_number_t n = 0; if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) return @"";
    NSMutableArray *rows = [NSMutableArray array]; NSMutableDictionary *now = [NSMutableDictionary dictionary]; double t = CACurrentMediaTime();
    static double lastT; double dt = lastT ? t - lastT : 0; lastT = t;
    for (mach_msg_type_number_t k = 0; k < n; k++) {
        thread_basic_info_data_t bi; mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
        thread_identifier_info_data_t ii; mach_msg_type_number_t ci = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(th[k], THREAD_BASIC_INFO, (thread_info_t)&bi, &c) == KERN_SUCCESS && thread_info(th[k], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &ci) == KERN_SUCCESS) {
            double cpu = bi.user_time.seconds + bi.user_time.microseconds / 1e6 + bi.system_time.seconds + bi.system_time.microseconds / 1e6;
            NSNumber *key = @(ii.thread_id); now[key] = @(cpu);
            if (dt > 0 && last[key]) {
                double pct = (cpu - [last[key] doubleValue]) / dt * 100;
                if (pct >= 8) { char nm[64] = ""; pthread_t pt = pthread_from_mach_thread_np(th[k]); if (pt) pthread_getname_np(pt, nm, sizeof nm);
                    [rows addObject:@[ @(pct), [NSString stringWithFormat:@"%s %.0f%%", nm[0] ? nm : "?", pct] ]]; }
            }
        }
        mach_port_deallocate(mach_task_self(), th[k]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof *th);
    last = now;
    [rows sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableArray *out = [NSMutableArray array]; for (NSArray *r in rows) { if (out.count >= 10) break; [out addObject:r[1]]; }
    return [out componentsJoinedByString:@", "];
}
/* where the engine's worker threads (redDispatcher*) spend their time: 2 s of PC samples (~250 Hz per thread), top
   code addresses as the exe's own addresses (0x1xxxxxxxx, as in a disassembler) or library+offset. WorkerSampler=YES on. */
static NSString *MSWhere(uint64_t pc, intptr_t exeSlide, uint64_t exeLo, uint64_t exeHi) {
    if (pc >= exeLo && pc < exeHi) return [NSString stringWithFormat:@"%#llx", pc - (uint64_t)exeSlide];
    Dl_info di; if (dladdr((void *)pc, &di) && di.dli_fname) {
        const char *b = strrchr(di.dli_fname, '/'); b = b ? b + 1 : di.dli_fname;
        if (di.dli_sname) return [NSString stringWithFormat:@"%s:%s+%#lx", b, di.dli_sname, (unsigned long)(pc - (uint64_t)di.dli_saddr)];
        return [NSString stringWithFormat:@"%s+%#lx", b, (unsigned long)(pc - (uint64_t)di.dli_fbase)];
    }
    return [NSString stringWithFormat:@"%#llx", pc];
}
static NSString *MSSampleWorkers(void) {
    if (![MSConfig()[@"WorkerSampler"] boolValue]) return nil;        /* opt-in: suspending the workers stalls the job system */
    intptr_t slide = 0; uint64_t lo = 0, hi = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i); if (!n || !strstr(n, "/Cyberpunk2077.app/Cyberpunk2077")) continue;
        slide = _dyld_get_image_vmaddr_slide(i); unsigned long sz = 0;
        uint8_t *t = getsectiondata((const struct mach_header_64 *)_dyld_get_image_header(i), "__TEXT", "__text", &sz);
        lo = (uint64_t)t; hi = lo + sz; break;
    }
    thread_act_array_t th; mach_msg_type_number_t n = 0; if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) return nil;
    thread_act_t w[16]; int nw = 0;
    for (mach_msg_type_number_t k = 0; k < n; k++) {
        char nm[64] = ""; pthread_t pt = pthread_from_mach_thread_np(th[k]); if (pt) pthread_getname_np(pt, nm, sizeof nm);
        if (nw < 16 && strncmp(nm, "redDispatcher", 13) == 0) w[nw++] = th[k]; else mach_port_deallocate(mach_task_self(), th[k]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof *th);
    if (!nw) return nil;
    NSCountedSet *pcs = [NSCountedSet set], *lrs = [NSCountedSet set]; int total = 0, running = 0;
    for (int round = 0; round < 500; round++) {
        for (int k = 0; k < nw; k++) {
            if (thread_suspend(w[k]) != KERN_SUCCESS) continue;
            arm_thread_state64_t st; mach_msg_type_number_t c = ARM_THREAD_STATE64_COUNT;
            thread_basic_info_data_t bi; mach_msg_type_number_t cb = THREAD_BASIC_INFO_COUNT;
            kern_return_t kr = thread_get_state(w[k], ARM_THREAD_STATE64, (thread_state_t)&st, &c);
            BOOL run = thread_info(w[k], THREAD_BASIC_INFO, (thread_info_t)&bi, &cb) == KERN_SUCCESS && bi.run_state == TH_STATE_RUNNING;
            thread_resume(w[k]);
            if (kr != KERN_SUCCESS) continue;
            total++; if (!run) continue;                       /* only time actually spent on a CPU */
            running++;
            [pcs addObject:@((uint64_t)arm_thread_state64_get_pc(st))];
            [lrs addObject:@((uint64_t)arm_thread_state64_get_lr(st))];
        }
        usleep(4000);
    }
    for (int k = 0; k < nw; k++) mach_port_deallocate(mach_task_self(), w[k]);
    NSString *(^top)(NSCountedSet *) = ^NSString *(NSCountedSet *set) {
        NSArray *all = [set.allObjects sortedArrayUsingComparator:^NSComparisonResult(id a, id b) { return [@([set countForObject:b]) compare:@([set countForObject:a])]; }];
        NSMutableArray *o = [NSMutableArray array];
        for (NSNumber *v in all) { if (o.count >= 12) break; [o addObject:[NSString stringWithFormat:@"%@ %.0f%%", MSWhere(v.unsignedLongLongValue, slide, lo, hi), 100.0 * [set countForObject:v] / MAX(1, running)]]; }
        return [o componentsJoinedByString:@", "];
    };
    return [NSString stringWithFormat:@"%d workers, %d samples, %.0f%% on CPU | top code: %@ | called from: %@", nw, total, 100.0 * running / MAX(1, total), top(pcs), top(lrs)];
}
static const char *MSThermal(void); extern _Atomic long long g_frames;
/* ---------------------------------------------------------------- slow-frame profiler + hot-phone worker test
 * When the open world runs under 24 FPS, the busy threads are sampled for 1.5 s: share of time on a CPU, where they
 * run (first exe frames of the stack) and, when not running, what they wait in (system call + exe caller). That shows
 * which thread a slow frame waits for. FrameProfiler = NO turns it off.
 * Hot-phone test: cool mode keeps 3 job workers on the efficiency cores (utility QoS). When the phone is hot iOS slows
 * utility work hardest, and the game thread waits for those workers' jobs every frame. So while hot and slow, the
 * shim times 15 s blocks with those workers raised to user-initiated and back (off/on/off/on); if raising them gives
 * 2+ FPS more it stays raised while the phone is hot. Tested 2026-10-16: no gain (19.5 vs 18.5 FPS) -> off by default;
 * HotBoost = test runs the test, YES always raises them. */
static NSString *MSSite(uint64_t pc, intptr_t slide, uint64_t lo, uint64_t hi) {
    if (pc >= lo && pc < hi) return [NSString stringWithFormat:@"%#llx", pc - (uint64_t)slide];
    Dl_info di; if (dladdr((void *)pc, &di) && di.dli_sname) return @(di.dli_sname);
    return [NSString stringWithFormat:@"%#llx", pc];
}
static void MSExeRange(intptr_t *slide, uint64_t *lo, uint64_t *hi) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i); if (!n || !strstr(n, "/Cyberpunk2077.app/Cyberpunk2077")) continue;
        *slide = _dyld_get_image_vmaddr_slide(i); unsigned long sz = 0;
        uint8_t *t = getsectiondata((const struct mach_header_64 *)_dyld_get_image_header(i), "__TEXT", "__text", &sz);
        *lo = (uint64_t)t; *hi = *lo + sz; return;
    }
}
/* Raw stack capture: runs while the target thread is SUSPENDED, so it must not take any lock (no malloc, no ObjC, no
   dladdr - the suspended thread may hold them, and the sampler would then hang with a game thread stopped).
   f[0] = pc, f[1] = lr, then the frame-pointer chain's return addresses; *run = thread was on a CPU. */
static int MSRawStack(thread_act_t t, uint64_t stLo, uint64_t stHi, uint64_t *f, int max, BOOL *run) {
    thread_basic_info_data_t bi; mach_msg_type_number_t cb = THREAD_BASIC_INFO_COUNT;
    *run = thread_info(t, THREAD_BASIC_INFO, (thread_info_t)&bi, &cb) == KERN_SUCCESS && bi.run_state == TH_STATE_RUNNING;
    arm_thread_state64_t st; mach_msg_type_number_t c = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(t, ARM_THREAD_STATE64, (thread_state_t)&st, &c) != KERN_SUCCESS) return 0;
    uint64_t fp = (uint64_t)arm_thread_state64_get_fp(st); int nf = 0;
    f[nf++] = (uint64_t)arm_thread_state64_get_pc(st); f[nf++] = (uint64_t)arm_thread_state64_get_lr(st) & 0xFFFFFFFFFull;
    (void)stLo; (void)stHi;                                   /* the game's main thread runs on CyPort's own stack */
    for (int d = 0; nf < max && fp && !(fp & 7); d++) {
        uint64_t pair[2]; vm_size_t got = 0;              /* a syscall: fails cleanly on a bad pointer, takes no lock */
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, 16, (vm_address_t)pair, &got) != KERN_SUCCESS || got != 16) break;
        uint64_t nfp = pair[0], ret = pair[1] & 0xFFFFFFFFFull;
        if (ret) f[nf++] = ret;
        if (nfp <= fp) break; fp = nfp;
    }
    return nf;
}
/* after resuming: "inner<outer" for the first 2 exe frames; *wait = the system function it sits in when not in the exe */
static NSString *MSStackKey(const uint64_t *f, int nf, intptr_t slide, uint64_t lo, uint64_t hi, NSString **wait) {
    *wait = (f[0] >= lo && f[0] < hi) ? nil : MSSite(f[0], slide, lo, hi);
    NSMutableArray *ex = [NSMutableArray array];
    for (int i = 0; i < nf && ex.count < 2; i++) if (f[i] >= lo && f[i] < hi && !(i == 1 && f[1] == f[0])) [ex addObject:MSSite(f[i], slide, lo, hi)];
    return ex.count ? [ex componentsJoinedByString:@"<"] : @"(no exe frame)";
}
static thread_act_t g_mainMach;
__attribute__((constructor)) static void MSNoteMainThread(void) { g_mainMach = pthread_mach_thread_np(pthread_self()); }
static double MSThreadCPU(thread_act_t t) {
    thread_basic_info_data_t bi; mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
    if (thread_info(t, THREAD_BASIC_INFO, (thread_info_t)&bi, &c) != KERN_SUCCESS) return -1;
    return bi.user_time.seconds + bi.user_time.microseconds / 1e6 + bi.system_time.seconds + bi.system_time.microseconds / 1e6;
}
static void MSProfileFrame(double fps) {
    intptr_t slide = 0; uint64_t lo = 0, hi = 0; MSExeRange(&slide, &lo, &hi); if (!lo) return;
    thread_act_array_t th; mach_msg_type_number_t n = 0; if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) return;
    thread_act_t self = mach_thread_self(), mainT = g_mainMach;
    double *c0 = calloc(n, sizeof(double)); for (mach_msg_type_number_t k = 0; k < n; k++) c0[k] = MSThreadCPU(th[k]);
    double t0 = CACurrentMediaTime(); usleep(500000); double dt = CACurrentMediaTime() - t0;
    enum { MAXT = 20 }; thread_act_t sel[MAXT]; double pct[MAXT]; int ns = 0;
    for (mach_msg_type_number_t k = 0; k < n; k++) {
        double p = (MSThreadCPU(th[k]) - c0[k]) / dt * 100;
        BOOL keep = th[k] != self && (p >= 4 || th[k] == mainT) && ns < MAXT;
        if (keep) { sel[ns] = th[k]; pct[ns++] = p; } else mach_port_deallocate(mach_task_self(), th[k]);
    }
    free(c0); vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof *th); mach_port_deallocate(mach_task_self(), self);
    NSCountedSet *run[MAXT], *wait[MAXT]; int tot[MAXT] = {0}, onCPU[MAXT] = {0};
    pthread_t pts[MAXT]; uint64_t sLo[MAXT], sHi[MAXT];
    for (int i = 0; i < ns; i++) {
        run[i] = [NSCountedSet set]; wait[i] = [NSCountedSet set]; pts[i] = pthread_from_mach_thread_np(sel[i]);
        sHi[i] = pts[i] ? (uint64_t)pthread_get_stackaddr_np(pts[i]) : 0; sLo[i] = pts[i] ? sHi[i] - pthread_get_stacksize_np(pts[i]) : 0;
    }
    for (int round = 0; round < 250; round++) {
        for (int i = 0; i < ns; i++) {
            uint64_t f[24]; BOOL r = NO; int nf;
            if (thread_suspend(sel[i]) != KERN_SUCCESS) continue;
            nf = MSRawStack(sel[i], sLo[i], sHi[i], f, 24, &r);          /* nothing that can lock in between */
            thread_resume(sel[i]);
            if (!nf) continue;
            @autoreleasepool {
                NSString *w = nil, *key = MSStackKey(f, nf, slide, lo, hi, &w);
                tot[i]++; if (r) { onCPU[i]++; [run[i] addObject:key]; } else [wait[i] addObject:w ? [NSString stringWithFormat:@"%@ from %@", w, key] : key];
            }
        }
        usleep(5000);
    }
    NSString *(^top)(NSCountedSet *, int) = ^NSString *(NSCountedSet *s, int total) {
        NSArray *a = [s.allObjects sortedArrayUsingComparator:^NSComparisonResult(id x, id y) { return [@([s countForObject:y]) compare:@([s countForObject:x])]; }];
        NSMutableArray *o = [NSMutableArray array];
        for (NSString *k in a) { if (o.count >= 5) break; [o addObject:[NSString stringWithFormat:@"%@ %.0f%%", k, 100.0 * [s countForObject:k] / MAX(1, total)]]; }
        return o.count ? [o componentsJoinedByString:@", "] : @"-";
    };
    MSLogf(@"profile: %.0f FPS, thermal %s, %d busy threads (~1.5 s, %% of each thread's samples)", fps, MSThermal(), ns);
    for (int i = 0; i < ns; i++) {
        char nm[64] = ""; if (pts[i]) pthread_getname_np(pts[i], nm, sizeof nm);
        qos_class_t q = QOS_CLASS_UNSPECIFIED; int rel = 0; if (pts[i]) pthread_get_qos_class_np(pts[i], &q, &rel);
        MSLogf(@"profile: %s%s qos %#x cpu %.0f%%, running %.0f%% | runs: %@ | waits: %@", sel[i] == mainT ? "MAIN " : "", nm[0] ? nm : "?", q, pct[i],
               100.0 * onCPU[i] / MAX(1, tot[i]), top(run[i], tot[i]), top(wait[i], tot[i]));
        mach_port_deallocate(mach_task_self(), sel[i]);
    }
}
static pthread_override_t g_boostOv[8]; static BOOL g_boosted;
static void MSBoostSlowWorkers(BOOL on) {
    if (on == g_boosted) return;
    for (int i = 0, n = MIN(8, (int)g_slowWorkerN); i < n; i++) {
        if (on) g_boostOv[i] = pthread_override_qos_class_start_np(g_slowWorker[i], QOS_CLASS_USER_INITIATED, 0);
        else if (g_boostOv[i]) { pthread_override_qos_class_end_np(g_boostOv[i]); g_boostOv[i] = NULL; }
    }
    g_boosted = on;
}
static double MSFPSFor(double secs, double *cpu) {
    long long f0 = g_frames; double t0 = CACurrentMediaTime(), c0 = MSCPUSeconds(); usleep((useconds_t)(secs * 1e6));
    double dt = CACurrentMediaTime() - t0; if (cpu) *cpu = (MSCPUSeconds() - c0) / dt * 100; return (g_frames - f0) / dt;
}
static BOOL MSIsHot(void) { return NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious; }
static void MSStartPerfLab(void) {
    static dispatch_once_t once; dispatch_once(&once, ^{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{     /* at utility it starved behind the game for minutes */
        id hb = MSConfig()[@"HotBoost"]; int mode = [hb isEqual:@"test"] ? 1 : [hb boolValue] ? 2 : 0;   /* 0 off (default: tested, no gain), 1 test, 2 always */
        BOOL prof = [MSConfig()[@"FrameProfiler"] boolValue];          /* opt-in: its sampling causes short hitches */
        double lastProf = 0, lastTest = 0, verdictAt = 0; int profiles = 0, verdict = 0;     /* verdict: 1 boost helps, -1 doesn't */
        for (;;) @autoreleasepool {
            BOOL bg0 = g_inBackground; double cpu = 0, fps = MSFPSFor(10, &cpu), now = CACurrentMediaTime();
            if (g_frames < 1500 || bg0 || g_inBackground) continue;
            BOOL hot = MSIsHot(), slow = fps > 3 && fps < 24 && cpu > 150;             /* open world, not menus or loading */
            if (prof && (slow || (hot && cpu > 250)) && profiles < 3 && now - lastProf > 120) { MSProfileFrame(fps); lastProf = now; profiles++; continue; }
            if (!mode || !g_slowWorkerN) continue;
            if (mode == 2 || verdict == 1) {
                if (hot != g_boosted) { MSBoostSlowWorkers(hot); MSLogf(@"hot boost: %d efficiency-core workers %@ (thermal %s, %.0f FPS)", (int)g_slowWorkerN, hot ? @"raised to user-initiated" : @"back on utility", MSThermal(), fps); }
                if (verdict == 1 && now - verdictAt > 600) verdict = 0;                     /* re-test every 10 min */
                if (mode == 2 || verdict) continue;
            }
            if (verdict == -1 && now - verdictAt < 600) continue;
            if (!hot || !slow || now - lastTest < 120) continue;
            double f[4], c[4];
            for (int i = 0; i < 4; i++) { MSBoostSlowWorkers(i & 1); MSFPSFor(1, NULL); f[i] = MSFPSFor(14, &c[i]); }
            MSBoostSlowWorkers(NO); lastTest = verdictAt = CACurrentMediaTime();
            double off = (f[0] + f[2]) / 2, on = (f[1] + f[3]) / 2; verdict = on >= off + 2 ? 1 : -1;
            MSLogf(@"hot boost test: workers on utility %.1f / %.1f FPS (CPU %.0f / %.0f%%), raised %.1f / %.1f FPS (CPU %.0f / %.0f%%) -> %@",
                   f[0], f[2], c[0], c[2], f[1], f[3], c[1], c[3], verdict == 1 ? @"raising them while the phone is hot" : @"keeping them on utility");
        }
    }); });
}

/* MetalFX: the game asks MTLFXTemporalScalerDescriptor whether this GPU can do MetalFX and falls back to FSR when it
   says no (seen: the game saved "ResolutionScaling MetalFX -> FSR2" ~60 s after starting). Every answer is logged; the
   support check is answered YES on an Apple GPU (A14 and later all do MetalFX). MetalFXForce = NO keeps the real answer. */
static IMP g_fxSupports, g_fxMin, g_fxMax, g_fxNew;
static BOOL ms_fxSupports(id self, SEL c, id dev) {
    BOOL real = ((BOOL (*)(id, SEL, id))g_fxSupports)(self, c, dev);
    BOOL force = ![MSConfig()[@"MetalFXForce"] isEqual:@NO] && [dev respondsToSelector:@selector(supportsFamily:)] && [dev supportsFamily:MTLGPUFamilyApple7];
    static int n; if (n++ < 6) MSLogf(@"MetalFX: %@ supportsDevice:%@ -> %@%@", self, [dev name], real ? @"YES" : @"NO", !real && force ? @" (answered YES)" : @"");
    return real || force;
}
static float ms_fxMin(id self, SEL c, id dev) { float v = ((float (*)(id, SEL, id))g_fxMin)(self, c, dev); static int n; if (n++ < 3) MSLogf(@"MetalFX: min input scale %.2f", v); return v; }
static float ms_fxMax(id self, SEL c, id dev) { float v = ((float (*)(id, SEL, id))g_fxMax)(self, c, dev); static int n; if (n++ < 3) MSLogf(@"MetalFX: max input scale %.2f", v); return v; }
/* per-frame render width the game hands MetalFX (dynamic resolution changes it every frame): min/avg/max per 30 s */
static IMP g_fxSetW; static _Atomic long g_fxWN, g_fxWSum, g_fxWMin = 1 << 30, g_fxWMax, g_fxOutW;
static void ms_fxSetW(id self, SEL c, NSUInteger w) {
    g_fxWN++; g_fxWSum += (long)w; if ((long)w < g_fxWMin) g_fxWMin = (long)w; if ((long)w > g_fxWMax) g_fxWMax = (long)w;
    ((void (*)(id, SEL, NSUInteger))g_fxSetW)(self, c, w);
}
static NSString *MSRenderWidthReport(void) {
    long n = g_fxWN, sum = g_fxWSum, lo = g_fxWMin, hi = g_fxWMax, out = g_fxOutW; g_fxWN = 0; g_fxWSum = 0; g_fxWMin = 1 << 30; g_fxWMax = 0;
    if (!n || !out) return nil;
    return [NSString stringWithFormat:@"render size: %ld-%ld px wide, avg %ld (%.0f-%.0f %%, avg %.0f %% of %ld)", lo, hi, sum / n, 100.0 * lo / out, 100.0 * hi / out, 100.0 * sum / n / out, out];
}
static id ms_fxNew(id self, SEL c, id dev) {
    id r = ((id (*)(id, SEL, id))g_fxNew)(self, c, dev);
    if (r) {
        g_fxOutW = (long)[[self valueForKey:@"outputWidth"] unsignedLongValue];
        Method m = class_getInstanceMethod(object_getClass(r), @selector(setInputContentWidth:));
        if (m && method_getImplementation(m) != (IMP)ms_fxSetW) { IMP o = method_setImplementation(m, (IMP)ms_fxSetW); if (!g_fxSetW) g_fxSetW = o; }
    }
    static int n; if (n++ < 6) MSLogf(@"MetalFX: temporal scaler %@ (input %lux%lu -> output %lux%lu)", r ? @"created" : @"FAILED",
        [[self valueForKey:@"inputWidth"] unsignedLongValue], [[self valueForKey:@"inputHeight"] unsignedLongValue],
        [[self valueForKey:@"outputWidth"] unsignedLongValue], [[self valueForKey:@"outputHeight"] unsignedLongValue]);
    return r;
}
static void MSHookMetalFX(const struct mach_header *mh, intptr_t slide) {
    static BOOL done; if (done) return;
    Class d = NSClassFromString(@"MTLFXTemporalScalerDescriptor"); if (!d) return;
    done = YES;
    Method m;
    if ((m = class_getClassMethod(d, @selector(supportsDevice:)))) g_fxSupports = method_setImplementation(m, (IMP)ms_fxSupports);
    if ((m = class_getClassMethod(d, NSSelectorFromString(@"supportedInputContentMinScaleForDevice:")))) g_fxMin = method_setImplementation(m, (IMP)ms_fxMin);
    if ((m = class_getClassMethod(d, NSSelectorFromString(@"supportedInputContentMaxScaleForDevice:")))) g_fxMax = method_setImplementation(m, (IMP)ms_fxMax);
    if ((m = class_getInstanceMethod(d, NSSelectorFromString(@"newTemporalScalerWithDevice:")))) g_fxNew = method_setImplementation(m, (IMP)ms_fxNew);
    MSLogf(@"MetalFX: hooks in (supports %d, scaler %d)", g_fxSupports != NULL, g_fxNew != NULL);
}
__attribute__((constructor)) static void MSInstallMetalFXHooks(void) { _dyld_register_func_for_add_image(MSHookMetalFX); }

static long long MSYieldRate(int slept) {             /* per second since the last call (each kind) */
    extern _Atomic long long g_yields, g_yieldSleeps;
    static long long lastY, lastS; static double lastT[2]; double t = CACurrentMediaTime(), dt = lastT[slept] ? t - lastT[slept] : 0; lastT[slept] = t;
    long long v = slept ? g_yieldSleeps : g_yields, d = v - (slept ? lastS : lastY); if (slept) lastS = v; else lastY = v;
    return dt > 0 ? (long long)(d / dt) : 0;
}
static const char *MSThermal(void) {
    switch (NSProcessInfo.processInfo.thermalState) { case NSProcessInfoThermalStateNominal: return "cool"; case NSProcessInfoThermalStateFair: return "warm";
        case NSProcessInfoThermalStateSerious: return "HOT (throttling)"; case NSProcessInfoThermalStateCritical: return "CRITICAL (heavy throttling)"; }
    return "?";
}
static double MSFootprintMB(void) {
    task_vm_info_data_t v; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v, &n) == KERN_SUCCESS ? v.phys_footprint / 1048576.0 : 0;
}
/* The game loads everything on the main thread, so UIKit can't draw while it does. The panel is plain CALayers in a
 * window made before the game starts, updated from a background thread with explicit CATransactions, which the render
 * server shows without the main thread. The bar is an estimate: the size of the last load that reached the first frames
 * (4 GB until one has). Once the game draws frames itself the panel shrinks to a strip and then goes away. */
_Atomic long long g_frames;
static IMP g_origNextDrawable;
static _Atomic long long g_drawDone;                 /* drawables the game's render thread got (frames it started presenting) */
static _Atomic double g_drawAt, g_drawIv = 1 / 30.0;  /* when the last one came, average time between them */
/* Low latency, part 1: with 3 drawables the render thread could queue up to 2 finished frames in front of the display
   when the GPU is the limit - every queued frame is one more frame of input lag. 2 keeps one on screen + one being
   drawn. Costs frame rate though: with 2 drawables a frame that misses a refresh waits for the next one, so the game
   snaps to 30 (or 20) FPS and can't reach 60 - tester: "FPS stays at 30, performance got worse". So it is OFF unless
   the start screen's "Low-latency input" switch (CyPortLowLatency) or LowLatency = YES turns it on; Drawables = 3
   only undoes this part. */
static BOOL MSLowLatencyOn(void) {
    id v = MSConfig()[@"LowLatency"];
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : MSPref(@"CyPortLowLatency", 0) != 0;
}
static void MSLowLatencyLayer(CAMetalLayer *l) {
    static __weak CAMetalLayer *done; if (l == done) return; done = l;
    /* v2: low latency keeps 3 drawables (2 halved the frame rate: 120 -> 60, 60 -> 30) and limits the frames queued for
       the GPU instead (MSLowLatencyWait). Drawables = 2 in macshim.plist still forces the old way. */
    int want = (int)MSCfgD(@"Drawables", 0); if (want != 2 && want != 3) return;
    NSUInteger was = l.maximumDrawableCount; if (was != (NSUInteger)want) l.maximumDrawableCount = want;
    MSLogf(@"low latency: game layer %.0fx%.0f, at most %d drawables (was %lu)", l.drawableSize.width, l.drawableSize.height, want, (unsigned long)was);
}
static _Atomic double g_gameMinDur = -1;             /* last cap the game presented with (0 = none), -1 = not drawing yet */
/* Smooth frame pacing. When the game can't keep up with its cap (VSync 120/Off at 60-85 FPS, 60 when hot) frames take
 * 2 refreshes, then 3, then 2: 17/25/17 ms - the FPS counter looks fine but it doesn't feel smooth. This holds the game
 * to the highest even step it really keeps up with (120, 60, 40, 30 - whole refreshes on a 120 Hz screen, never above
 * the game's own cap): down after 2 s with > 10% late frames, and now and then (20 s, doubling to 160 s after a failed
 * try) it tries the next step up for 3 s. Start screen switch "Smooth frame pacing" (CyPortSmoothPacing, default on);
 * SmoothPacing = YES/NO in macshim.plist overrides; FrameRate in macshim.plist (fixed pacing) turns it off. */
static BOOL MSSmoothOn(void) {
    id v = MSConfig()[@"SmoothPacing"];
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : MSPref(@"CyPortSmoothPacing", 1) != 0;
}
static void MSSmoothFrame(double tOut) {                 /* render thread, after every nextDrawable */
    static int on = -1; if (on < 0) on = MSSmoothOn(); if (!on || g_paceMode > 0 || g_inBackground) return;
    static double last, winStart, probeAt, backoff = 20; static int n, late, step, top, probing, probeFrom, probeWins, badWins;
    int maxHz = (int)lround(g_fps); if (maxHz < 60) maxHz = 60;
    double gd = g_gameMinDur; int cap = gd > 0 ? (int)lround(1 / gd) : maxHz; if (cap > maxHz) cap = maxHz;
    static const int steps[] = { 120, 60, 40, 30 };
    int newTop = 0; for (int i = 0; i < 4; i++) if (steps[i] <= cap && maxHz % steps[i] == 0) { newTop = steps[i]; break; }
    if (newTop != top) {                                  /* game cap changed (or first frame) */
        top = newTop; probing = 0; badWins = 0;
        if (!step || step > top) step = top; else if (step < top) probeAt = tOut + 3;
        if (top) MSLogf(@"smooth pacing: game cap %d FPS, steps up to %d", cap, top);
    }
    if (top <= 30) { if (g_paceT > 0) MSPaceSet(0, @"smooth pacing: nothing to smooth"); last = 0; return; }
    if (last > 0) {
        double dt = tOut - last;
        if (dt > 0.25) { n = late = 0; winStart = tOut; }   /* loading / hitch: not a pacing question */
        else { n++; if (dt > 1.3 / step) late++; }
    }
    last = tOut; if (!winStart) winStart = tOut;
    int was = step; NSString *why = nil;
    if (tOut - winStart >= 1 && n >= 10) {
        double frac = (double)late / n;
        if (probing) {
            if (frac > 0.08) { step = probeFrom; probing = 0; backoff = fmin(backoff * 2, 160); probeAt = tOut + backoff;
                               why = [NSString stringWithFormat:@"smooth: %d FPS not kept (%.0f%% late), next try in %.0f s", was, 100 * frac, backoff]; }
            else if (++probeWins >= 3) { probing = 0; backoff = 20; probeAt = tOut + 20;
                               MSLogf(@"smooth pacing: %d FPS holds", step); }
        } else if (frac > 0.10) {
            if (++badWins >= 2) {
                int lower = 0; for (int i = 0; i < 4; i++) if (steps[i] < step && maxHz % steps[i] == 0) { lower = steps[i]; break; }
                if (lower) { step = lower; probeAt = tOut + backoff; why = [NSString stringWithFormat:@"smooth: %.0f%% of frames late at %d FPS", 100 * frac, was]; }
                badWins = 0;
            }
        } else badWins = 0;
        if (!probing && step < top && probeAt > 0 && tOut >= probeAt) {
            int higher = top; for (int i = 3; i >= 0; i--) if (steps[i] > step && steps[i] <= top && maxHz % steps[i] == 0) { higher = steps[i]; break; }
            probing = 1; probeFrom = step; probeWins = 0; step = higher; why = [NSString stringWithFormat:@"smooth: trying %d FPS", higher];
        }
        n = late = 0; winStart = tOut;
    }
    if (step != was || (step >= cap) != (g_paceT <= 0)) MSPaceSet(step >= cap ? 0 : step, why ?: @"smooth pacing");
}
static id ms_nextDrawable(id self, SEL _cmd) {
    if (self == g_mirrorLayer) return ((id (*)(id, SEL))g_origNextDrawable)(self, _cmd);
    MSPaceWait(); g_frames++;
    MSLowLatencyLayer(self);
    if (g_mirrorOn && [(CAMetalLayer *)self framebufferOnly]) [(CAMetalLayer *)self setFramebufferOnly:NO];  /* the mirror copies from it */
    id d = ((id (*)(id, SEL))g_origNextDrawable)(self, _cmd);
    double t = CACurrentMediaTime(), last = g_drawAt;
    if (last > 0 && t - last < 0.25) g_drawIv = g_drawIv * 0.9 + (t - last) * 0.1;
    g_drawAt = t; g_drawDone++;
    MSSmoothFrame(t);
    return d;
}
/* Low latency, part 2. The game reads input at the start of its frame (nextEventMatchingMask: and the GameController
 * callbacks that run inside it), simulates, and its render thread draws that frame afterwards. When the render thread
 * (or the GPU behind it) is the slower one, the game thread runs ahead and then waits for it - but it has already read
 * the sticks/buttons/touches, so they are a frame or more old by the time the frame is drawn: the "laggy, imprecise"
 * controls. Here the game thread does that waiting BEFORE it reads input: until the render thread has taken a drawable
 * since the last read (= it is ready for the next frame). The frame rate stays the same (the wait only moves), input is
 * a frame fresher. Only while the game reads input once per drawn frame (measured for 3 s at the start and every 60 s;
 * loading screens and menus that stop drawing are left alone). Bounded to ~one frame. Off by default (MSLowLatencyOn). */
static long long g_llFrames, g_llWaited, g_llTimeouts; static double g_llWaitSum, g_llWaitMax;
/* Low latency, part 3: frames the render thread handed to the GPU (presenting command buffers) and how many of those
   the GPU finished. With 3 drawables the GPU could have 2-3 frames queued, each one a frame of input lag; the game
   thread now starts a frame (= reads input) only when at most one is left in flight. No refresh is skipped, so the
   frame rate doesn't snap to half like with 2 drawables. */
static _Atomic long long g_llSubmitted, g_llGpuDone;
static void MSLowLatencyTrack(id<MTLCommandBuffer> cb) {   /* render thread, presenting command buffer, before commit */
    static int on = -1; if (on < 0) on = MSLowLatencyOn(); if (!on || !cb) return;
    g_llSubmitted++;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> b) { g_llGpuDone++; }];
}
static long long g_llGpuWaited; static double g_llGpuWaitSum;
static void MSLowLatencyGpuWait(void) {
    if (g_llSubmitted == 0 || CACurrentMediaTime() - g_drawAt > 0.25) return;
    if (g_llSubmitted - g_llGpuDone <= 1) return;
    double t0 = CACurrentMediaTime(), now = t0;
    while (g_llSubmitted - g_llGpuDone > 1 && (now = CACurrentMediaTime()) - t0 < 0.05) usleep(200);
    g_llGpuWaited++; g_llGpuWaitSum += now - t0;
}
static void MSLowLatencyWait(void) {                  /* main thread, start of every game frame */
    static int on = -1; if (on < 0) on = MSLowLatencyOn(); if (!on) return;
    MSLowLatencyGpuWait();
    /* part 2 (game thread in lockstep with the render thread) also costs frame rate when both threads are busy:
       only with LowLatencyLockstep = YES */
    static int ls = -1; if (ls < 0) ls = MSCfgD(@"LowLatencyLockstep", 0) != 0; if (!ls) return;
    static long long seen, calPolls, calDraws0; static double calEnd, nextCal; static int okState = -1;
    double now = CACurrentMediaTime(), at = g_drawAt; long long dd = g_drawDone;
    if (at <= 0 || now - at > 0.25) { seen = dd; calEnd = 0; return; }            /* not drawing right now */
    g_llFrames++;
    if (calEnd == 0 && now >= nextCal) { calEnd = now + 3; calPolls = 0; calDraws0 = dd; }
    if (calEnd > 0) {                                                             /* measuring: no waiting */
        calPolls++; seen = dd;
        if (now >= calEnd) {
            long long draws = dd - calDraws0; double r = draws > 0 ? (double)calPolls / draws : 0;
            int ok = draws >= 20 && r > 0.8 && r < 1.25; calEnd = 0; nextCal = now + 60;
            if (ok != okState) MSLogf(@"low latency: the game reads input %.2fx per drawn frame -> %@", r,
                                      ok ? @"input is read once the render thread is ready" : @"waiting off for now");
            okState = ok;
        }
        return;
    }
    if (okState == 1 && dd <= seen) {
        double lim = fmin(g_drawIv * 1.1, 0.045), t0 = now;
        while (g_drawDone <= seen && (now = CACurrentMediaTime()) - t0 < lim) usleep(150);
        double w = now - t0; g_llWaited++; g_llWaitSum += w; if (w > g_llWaitMax) g_llWaitMax = w;
        if (g_drawDone <= seen) g_llTimeouts++;
    }
    seen = g_drawDone;
}
static UIWindow *g_statusWin; static CGFloat g_stPad; static CALayer *g_stRoot, *g_stBg, *g_stTrack, *g_stFill; static CATextLayer *g_stTitle, *g_stHead, *g_stLog;
static CATextLayer *MSTextLayer(CGFloat size, BOOL mono, UIColor *color) {
    CATextLayer *t = [CATextLayer layer]; t.contentsScale = UIScreen.mainScreen.scale; t.foregroundColor = color.CGColor;
    UIFont *f = mono ? [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightRegular] : [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
    t.font = (__bridge CFTypeRef)f; t.fontSize = size; t.truncationMode = kCATruncationEnd; t.wrapped = NO; return t;
}
/* ---------------------------------------------------------------- on-screen controller
 * The game reads gamepads through GameController (GCController.controllers + GCControllerDidConnectNotification,
 * extendedGamepad). A writable "snapshot" controller (+controllerWithExtendedGamepad) is added to that list and driven
 * by touch controls, so the game sees an ordinary gamepad. Left side: floating stick; right side: drag = camera (right
 * stick); buttons A/B/X/Y, LB/LT/RB/RT, L3/R3, d-pad, View, Menu. In menus (pointer not locked) a tap on empty screen
 * passes through as a mouse click at that spot. The pad hides itself while a real controller is connected and can be
 * toggled with the 🎮 button. Off entirely with TouchControls = NO; LookSpeed (default 1) scales the camera. */
static GCController *g_vpad;
static IMP g_origControllers, g_origCurrent;
static BOOL g_realPad;               /* a real controller is connected: the virtual one is withdrawn from the game */
static NSArray *ms_controllers(id self, SEL _cmd) {
    NSArray *a = ((NSArray *(*)(id, SEL))g_origControllers)(self, _cmd);
    return g_vpad && !g_realPad ? [a ?: @[] arrayByAddingObject:g_vpad] : a;
}
static GCController *ms_current(id self, SEL _cmd) {
    GCController *c = ((GCController *(*)(id, SEL))g_origCurrent)(self, _cmd); return c ?: g_realPad ? nil : g_vpad;
}
static GCExtendedGamepad *g_pad;     /* our own handle, so the hooks below only see the game's calls */
static IMP g_origPhys;
static id ms_physicalInputProfile(GCController *self, SEL _cmd) {
    id r = ((id (*)(id, SEL))g_origPhys)(self, _cmd);
    static BOOL seen; if (self == g_vpad && !seen) { seen = YES; MSLogf(@"touch pad: the game is reading the virtual controller (physicalInputProfile, %@)", r == g_pad ? @"same object" : NSStringFromClass([r class])); }
    return r;
}
/* The game only knows Xbox / DualShock 4 / DualSense controllers (it picks button glyphs and layouts by
 * productCategory). The snapshot controller's own category is unknown to it and corrupted memory on the next screen,
 * so it reports itself as an Xbox controller. Real third-party pads (EasySMX, 8BitDo, MFi: "HID", "MFi", "Generic")
 * are just as unknown - tester's EasySMX M10 often did nothing in the start menu - so they are Xbox pads too.
 * RealPadCategory = NO leaves them alone. */
static IMP g_origCategory, g_origVendor;
static NSString *ms_productCategory(GCController *self, SEL _cmd) {
    if (self == g_vpad) return GCProductCategoryXboxOne;
    NSString *c = ((NSString *(*)(id, SEL))g_origCategory)(self, _cmd);
    static int spoof = -1; if (spoof < 0) spoof = MSCfgD(@"RealPadCategory", 1) != 0;
    if (!spoof || self.isSnapshot || !self.extendedGamepad || [c isEqualToString:GCProductCategoryXboxOne] ||
        [c isEqualToString:GCProductCategoryDualShock4] || [c isEqualToString:GCProductCategoryDualSense]) return c;
    static NSString *said; if (![said isEqualToString:c]) { said = c; MSLogf(@"controller: '%@' (%@) is shown to the game as an Xbox controller", self.vendorName, c); }
    return GCProductCategoryXboxOne;
}
static NSString *ms_vendorName(GCController *self, SEL _cmd) {
    if (self == g_vpad) return @"Xbox Wireless Controller";
    return ((NSString *(*)(id, SEL))g_origVendor)(self, _cmd);
}
static IMP g_origExtGamepad;
static id ms_extendedGamepad(GCController *self, SEL _cmd) {
    static BOOL seen; if (self == g_vpad && !seen) { seen = YES; MSLogf(@"touch pad: the game is reading the virtual controller (extendedGamepad)"); }
    return ((id (*)(id, SEL))g_origExtGamepad)(self, _cmd);
}
/* The game reads gamepads through callbacks (setValueChangedHandler: on the gamepad / its elements), not by polling.
 * Setting a value on a snapshot controller doesn't run those callbacks, so the on-screen controller was invisible to
 * the game. The handlers it installs on the virtual pad are kept here, and every change the touch controls make runs
 * them (unless GameController already did within 30 ms). */
static NSMapTable *g_padHandlers, *g_padFired;           /* element -> game's handler, element -> last time it ran */
static BOOL g_realHandlerSeen;                            /* the game has hooked up a real controller (set a handler on it) */
static BOOL MSIsPadObject(id o) {
    if (!g_pad || !o) return NO;
    if (o == g_pad) return YES;
    for (GCControllerElement *e in g_pad.allElements) {
        if (e == o) return YES;
        if ([e isKindOfClass:GCControllerDirectionPad.class]) {
            GCControllerDirectionPad *d = (GCControllerDirectionPad *)e;
            if (o == d.xAxis || o == d.yAxis || o == d.up || o == d.down || o == d.left || o == d.right) return YES;
        }
    }
    return NO;
}
/* how long a real controller's input took to reach the game: from GameController's timestamp of the event to the
   moment the game's callback runs (main thread, start of a frame). Logged every 30 s with the low-latency numbers. */
static __weak GCExtendedGamepad *g_realGP;
static long long g_ptN; static double g_ptSum, g_ptMax;
static void MSPadTiming(void) {
    GCExtendedGamepad *g = g_realGP; if (!g) return;
    double ts = g.lastEventTimestamp;                 /* seconds since 1970 on iOS 27, not CACurrentMediaTime's clock */
    double d = (ts > 1e8 ? NSDate.date.timeIntervalSince1970 : CACurrentMediaTime()) - ts;
    static int said; if (!said++) MSLogf(@"controller: first input reached the game %.1f ms after the controller sent it (%@ thread)", d * 1000, NSThread.isMainThread ? @"main" : @"other");
    if (d < 0 || d > 2) return;
    g_ptN++; g_ptSum += d; if (d > g_ptMax) g_ptMax = d;
}
static void MSInputReport(void) {                     /* main thread */
    static double rep; double now = CACurrentMediaTime();
    if (now - rep < 30) return;
    if (rep > 0 && g_llFrames) MSLogf(@"low latency: %lld frames, waited before reading input in %.0f%% (avg %.1f ms, max %.1f ms, %lld hit the limit), frame %.1f ms",
                                      g_llFrames, 100.0 * g_llWaited / g_llFrames, g_llWaited ? 1000 * g_llWaitSum / g_llWaited : 0, 1000 * g_llWaitMax, g_llTimeouts, 1000 * g_drawIv);
    if (rep > 0 && g_llFrames) MSLogf(@"low latency: waited for the GPU in %lld frames (avg %.1f ms)", g_llGpuWaited, g_llGpuWaited ? 1000 * g_llGpuWaitSum / g_llGpuWaited : 0);
    g_llGpuWaited = 0; g_llGpuWaitSum = 0;
    if (rep > 0 && g_ptN) MSLogf(@"controller: %lld inputs, reached the game avg %.1f ms (max %.1f ms) after the controller sent them",
                                 g_ptN, 1000 * g_ptSum / g_ptN, 1000 * g_ptMax);
    rep = now; g_llFrames = g_llWaited = g_llTimeouts = 0; g_llWaitSum = g_llWaitMax = 0; g_ptN = 0; g_ptSum = g_ptMax = 0;
}
static IMP g_origSetVCH[4]; static Class g_vchClass[4], g_vchHooked[4];
static void ms_setValueChangedHandler(id self, SEL _cmd, id handler) {
    IMP orig = NULL;
    for (int i = 0; i < 4; i++) if (g_vchHooked[i] && [self isKindOfClass:g_vchHooked[i]]) { orig = g_origSetVCH[i]; break; }
    if (handler && !MSIsPadObject(self)) g_realHandlerSeen = YES;
    static int n; if (n++ < 40) MSLogf(@"game set a gamepad handler on %@%@", NSStringFromClass([self class]), MSIsPadObject(self) ? @" (on-screen controller)" : @"");
    id h = handler;
    if (handler && MSIsPadObject(self)) {
        id real = [handler copy];
        @synchronized (g_padHandlers) { [g_padHandlers setObject:real forKey:self]; }
        __weak id weakSelf = self;
        if ([self isKindOfClass:GCControllerButtonInput.class])
            h = ^(GCControllerButtonInput *b, float v, BOOL p) { @synchronized (g_padHandlers) { [g_padFired setObject:@(CACurrentMediaTime()) forKey:weakSelf]; } ((void (^)(id, float, BOOL))real)(b, v, p); };
        else if ([self isKindOfClass:GCControllerDirectionPad.class])
            h = ^(GCControllerDirectionPad *d, float x, float y) { @synchronized (g_padHandlers) { [g_padFired setObject:@(CACurrentMediaTime()) forKey:weakSelf]; } ((void (^)(id, float, float))real)(d, x, y); };
        else if ([self isKindOfClass:GCControllerAxisInput.class])
            h = ^(GCControllerAxisInput *a, float v) { @synchronized (g_padHandlers) { [g_padFired setObject:@(CACurrentMediaTime()) forKey:weakSelf]; } ((void (^)(id, float))real)(a, v); };
        else
            h = ^(id g, GCControllerElement *el) { @synchronized (g_padHandlers) { [g_padFired setObject:@(CACurrentMediaTime()) forKey:weakSelf]; } ((void (^)(id, id))real)(g, el); };
    } else if (handler && MSCfgD(@"PadTiming", 0) != 0) {        /* a real controller: measure, change nothing (PadTiming = YES) */
        id real = [handler copy];
        if ([self isKindOfClass:GCControllerButtonInput.class])
            h = ^(GCControllerButtonInput *b, float v, BOOL p) { MSPadTiming(); ((void (^)(id, float, BOOL))real)(b, v, p); };
        else if ([self isKindOfClass:GCControllerDirectionPad.class])
            h = ^(GCControllerDirectionPad *d, float x, float y) { MSPadTiming(); ((void (^)(id, float, float))real)(d, x, y); };
        else if ([self isKindOfClass:GCControllerAxisInput.class])
            h = ^(GCControllerAxisInput *a, float v) { MSPadTiming(); ((void (^)(id, float))real)(a, v); };
    }
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, h);
}
static void MSHookGamepadHandlers(void) {
    g_padHandlers = [NSMapTable weakToStrongObjectsMapTable]; g_padFired = [NSMapTable weakToStrongObjectsMapTable];
    /* the concrete classes the virtual pad uses (private subclasses may override the setter); real controllers' objects
       of the same classes just pass through */
    id objs[4] = { g_pad, g_pad.buttonA, g_pad.dpad, g_pad.dpad.xAxis };
    for (int i = 0; i < 4; i++) {
        if (!objs[i]) continue;
        Class c = object_getClass(objs[i]);
        Method m = class_getInstanceMethod(c, @selector(setValueChangedHandler:)); if (!m) continue;
        IMP old = method_getImplementation(m);
        if (old == (IMP)ms_setValueChangedHandler) continue;
        if (!class_addMethod(c, @selector(setValueChangedHandler:), (IMP)ms_setValueChangedHandler, method_getTypeEncoding(m))) method_setImplementation(m, (IMP)ms_setValueChangedHandler);
        g_origSetVCH[i] = old; g_vchHooked[i] = c;
        MSLogf(@"touch pad: watching gamepad handlers on %@", NSStringFromClass(c));
    }
}
/* run the game's handlers for one element of the virtual pad right away (touch handlers run on the main thread, where
   GameController would deliver them too). It used to wait 30 ms + a run-loop turn to avoid doubles: that was the stick lag.
   If GameController also calls them for the snapshot, the game just sees the same value twice. */
static void MSPadRun(GCControllerElement *x) {
    id h; @synchronized (g_padHandlers) { h = [g_padHandlers objectForKey:x]; } if (!h) return;
    if ([x isKindOfClass:GCControllerButtonInput.class]) { GCControllerButtonInput *b = (id)x; ((void (^)(id, float, BOOL))h)(b, b.value, b.isPressed); }
    else if ([x isKindOfClass:GCControllerDirectionPad.class]) { GCControllerDirectionPad *d = (id)x; ((void (^)(id, float, float))h)(d, d.xAxis.value, d.yAxis.value); }
    else if ([x isKindOfClass:GCControllerAxisInput.class]) { GCControllerAxisInput *a = (id)x; ((void (^)(id, float))h)(a, a.value); }
}
static void MSPadNotify(GCControllerElement *el) {
    if (!el || !g_padHandlers) return;
    if (![NSThread isMainThread]) { MSMainAsync(^{ MSPadNotify(el); }); return; }
    MSPadRun(el);
    if ([el isKindOfClass:GCControllerDirectionPad.class]) { MSPadRun(((GCControllerDirectionPad *)el).xAxis); MSPadRun(((GCControllerDirectionPad *)el).yAxis); }
    for (GCControllerElement *c = el.collection; c; c = c.collection) MSPadRun(c);
    id gh; @synchronized (g_padHandlers) { gh = [g_padHandlers objectForKey:g_pad]; }
    if (gh) ((void (^)(id, id))gh)(g_pad, el);
}
static void MSPadSetButton(GCControllerButtonInput *b, float v) { if (!b) return; if (b.value == v) return; [b setValue:v]; MSPadNotify(b); }
static void MSPadSetStick(GCControllerDirectionPad *d, float x, float y) {
    if (!d) return; float ox = d.xAxis.value, oy = d.yAxis.value; [d setValueForXAxis:x yAxis:y];
    if (ox != x || oy != y) MSPadNotify(d);
}
/* once per game frame: finger speed over the last frame -> right stick. Smoothed (the touch samples and the game's frames
   don't line up), with a response curve so slow swipes still turn (the game squares small stick values), and it eases
   back to centre when the finger stops or lifts. LookSpeed scales it (default 1; full deflection at ~650 pt/s). */
/* the start screen's Look sensitivity slider (NSUserDefaults CyPortLookSensitivity, 0.25-4, default 1.5) */
static double MSLookSensitivity(void) {
    double v = [NSUserDefaults.standardUserDefaults doubleForKey:@"CyPortLookSensitivity"];
    return v >= 0.25 && v <= 4 ? v : 1.5;
}
static void MSLookFlushStick(double dt) {
    static float vx, vy; static double full = 0, curve = 0;
    if (!g_pad) return;
    if (!full) { id ls = MSConfig()[@"LookSpeed"]; double sp = ls ? [ls doubleValue] : 1; if (sp <= 0) sp = 1; full = 650 / (sp * MSLookSensitivity());
             MSLogf(@"look sensitivity %.2fx", MSLookSensitivity()); curve = MSCfgD(@"LookCurve", 0.6); }
    if (dt < 1 / 240.0) dt = 1 / 240.0; if (dt > 0.1) dt = 0.1;
    os_unfair_lock_lock(&g_lookLock); CGPoint d = g_lookPending; g_lookPending = CGPointZero; os_unfair_lock_unlock(&g_lookLock);
    BOOL fingerMoving = g_lookFingerAt && CACurrentMediaTime() - g_lookFingerAt < 0.06;
    float rx = d.x / dt / full, ry = -d.y / dt / full;
    if (fingerMoving || d.x || d.y) { vx = vx * 0.2f + rx * 0.8f; vy = vy * 0.2f + ry * 0.8f; }   /* light smoothing, quick response */
    else { vx *= 0.35f; vy *= 0.35f; if (fabsf(vx) < 0.03f && fabsf(vy) < 0.03f) vx = vy = 0; }   /* finger still / lifted: quick ease out */
    float m = hypotf(vx, vy), outx = 0, outy = 0;
    if (m > 0.001f) { float c = powf(fminf(m, 1), curve); outx = vx / m * c; outy = vy / m * c; }
    MSPadSetStick(g_pad.rightThumbstick, outx, outy);
}
static BOOL MSRealControllerConnected(void) {
    NSArray *all = g_origControllers ? ((NSArray *(*)(id, SEL))g_origControllers)(GCController.class, @selector(controllers)) : GCController.controllers;
    for (GCController *c in all) if (!c.isSnapshot) return YES;
    return NO;
}
typedef enum { MSCtlButton, MSCtlToggle } MSCtlKind;
@interface MSCtl : NSObject
@property MSCtlKind kind; @property CGPoint center; @property CGFloat r; @property(copy) NSString *label;
@property(weak) GCControllerButtonInput *button; @property int dpadX, dpadY; @property NSInteger key; @property(strong) CAShapeLayer *shape; @property(strong) CATextLayer *text;
@property(weak) UITouch *touch;
@end
@implementation MSCtl @end

@interface MSPadView : UIView @end
@implementation MSPadView {
    NSMutableArray<MSCtl *> *_ctls; BOOL _hiddenByUser, _shown; CADisplayLink *_link; CGSize _laidOut;
    UITouch *_moveTouch, *_lookTouch; CGPoint _moveOrigin, _lookLast; CGVector _lookAccum; double _lookT, _lookMoved; float _lookX, _lookY;
    CAShapeLayer *_stickBase, *_stickKnob; float _lookSpeed;
    CGPoint _lHome, _rHome; UITouch *_rTouch; CAShapeLayer *_rBase, *_rKnob; int _wasd;
    double _stickT0; CGPoint _stickP0; CGFloat _stickMax; int _lookMouse;
}
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f]; if (!self) return nil;
    self.multipleTouchEnabled = YES; self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    id ls = MSConfig()[@"LookSpeed"]; _lookSpeed = ls ? [ls floatValue] : 1; if (_lookSpeed <= 0) _lookSpeed = 1;
    _ctls = [NSMutableArray array];
    GCExtendedGamepad *g = g_pad;
    struct { __unsafe_unretained NSString *l; __unsafe_unretained GCControllerButtonInput *b; int dx, dy; NSInteger key; } d[] = {
        { @"A", g.buttonA }, { @"B", g.buttonB }, { @"X", g.buttonX }, { @"Y", g.buttonY },
        { @"LB", g.leftShoulder }, { @"LT", g.leftTrigger }, { @"RB", g.rightShoulder }, { @"RT", g.rightTrigger },
        { @"L3", g.leftThumbstickButton }, { @"R3", g.rightThumbstickButton },
        { @"▲", nil, 0, 1, g ? 0 : (NSInteger)GCKeyCodeUpArrow }, { @"▼", nil, 0, -1, g ? 0 : (NSInteger)GCKeyCodeDownArrow },
        { @"◀", nil, -1, 0, g ? 0 : (NSInteger)GCKeyCodeLeftArrow }, { @"▶", nil, 1, 0, g ? 0 : (NSInteger)GCKeyCodeRightArrow },
        { @"⧉", g.buttonOptions }, { @"≡", g.buttonMenu },
        { @"Esc", nil, 0, 0, (NSInteger)GCKeyCodeEscape }, { @"Space", nil, 0, 0, (NSInteger)GCKeyCodeSpacebar }, { @"Enter", nil, 0, 0, (NSInteger)GCKeyCodeReturnOrEnter },
    };
    for (size_t i = 0; i < sizeof d / sizeof *d; i++) {
        if (!d[i].b && !d[i].dx && !d[i].dy && !d[i].key) continue;      /* no virtual controller: keyboard keys only */
        MSCtl *c = [MSCtl new]; c.kind = MSCtlButton; c.label = d[i].l; c.button = d[i].b; c.dpadX = d[i].dx; c.dpadY = d[i].dy; c.key = d[i].key; [_ctls addObject:c];
    }
    MSCtl *t = [MSCtl new]; t.kind = MSCtlToggle; t.label = @"🎮"; [_ctls addObject:t];
    for (MSCtl *c in _ctls) {
        c.shape = [CAShapeLayer layer]; c.shape.lineWidth = 1.5; [self.layer addSublayer:c.shape];
        c.text = [CATextLayer layer]; c.text.contentsScale = UIScreen.mainScreen.scale; c.text.alignmentMode = kCAAlignmentCenter;
        c.text.foregroundColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor; c.text.font = (__bridge CFTypeRef)[UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        [self.layer addSublayer:c.text];
    }
    _stickBase = [CAShapeLayer layer]; _stickKnob = [CAShapeLayer layer];
    _rBase = [CAShapeLayer layer]; _rKnob = [CAShapeLayer layer];
    for (CAShapeLayer *l in @[ _stickBase, _stickKnob, _rBase, _rKnob ]) [self.layer addSublayer:l];
    for (CAShapeLayer *l in @[ _stickBase, _rBase ]) { l.fillColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor; l.strokeColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor; l.lineWidth = 2; }
    for (CAShapeLayer *l in @[ _stickKnob, _rKnob ]) l.fillColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    if (!g_pad) { [_rBase removeFromSuperlayer]; [_rKnob removeFromSuperlayer]; _rHome = CGPointMake(-1000, -1000); }
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(msTick:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(15, 30, 30);   /* runs on the game's thread: 30 Hz is plenty for the pad */
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.hidden = YES;
    return self;
}
- (void)msLayout {
    CGSize S = self.bounds.size; if (CGSizeEqualToSize(S, _laidOut)) return; _laidOut = S;
    UIEdgeInsets in = self.safeAreaInsets; CGFloat L = MAX(in.left, 16), R = S.width - MAX(in.right, 16), H = S.height - MAX(in.bottom, 8), T = MAX(in.top, 8);
    NSDictionary *pos = @{
        @"A": @[ @(R - 85), @(H - 40), @27 ],  @"B": @[ @(R - 35), @(H - 90), @27 ],  @"X": @[ @(R - 135), @(H - 90), @27 ], @"Y": @[ @(R - 85), @(H - 140), @27 ],
        @"RT": @[ @(R - 40), @(T + 40), @30 ], @"RB": @[ @(R - 115), @(T + 34), @24 ],
        @"LT": @[ @(L + 40), @(T + 40), @30 ], @"LB": @[ @(L + 115), @(T + 34), @24 ],
        @"L3": @[ @(L + 24), @(H - 24), @20 ], @"R3": @[ @(R - 170), @(H - 22), @20 ],
        @"▲": @[ @(L + 190), @(T + 22), @16 ], @"▼": @[ @(L + 190), @(T + 86), @16 ], @"◀": @[ @(L + 158), @(T + 54), @16 ], @"▶": @[ @(L + 222), @(T + 54), @16 ],
        @"⧉": @[ @(S.width / 2 - 55), @(T + 20), @17 ], @"≡": @[ @(S.width / 2 + 55), @(T + 20), @17 ], @"🎮": @[ @(S.width / 2), @(T + 20), @17 ],
        @"Esc": @[ @(S.width / 2 - 120), @(T + 20), @19 ], @"Space": @[ @(S.width / 2 + 120), @(T + 20), @21 ], @"Enter": @[ @(S.width / 2 + 175), @(T + 20), @21 ],
    };
    _lHome = CGPointMake(L + 115, H - 105); _rHome = CGPointMake(-1000, -1000);   /* no right stick: swipe on the right half to look */
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (MSCtl *c in _ctls) {
        NSArray *p = pos[c.label]; c.center = CGPointMake([p[0] doubleValue], [p[1] doubleValue]); c.r = [p[2] doubleValue];
        c.shape.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.center.x - c.r, c.center.y - c.r, 2 * c.r, 2 * c.r)].CGPath;
        CGFloat fs = c.label.length > 2 ? 9 : c.r < 20 ? 11 : 14; c.text.fontSize = fs; c.text.frame = CGRectMake(c.center.x - c.r, c.center.y - fs * 0.62, 2 * c.r, fs * 1.3);
        c.text.string = c.label; [self msPaint:c];
    }
    [self msDrawStick:_stickBase knob:_stickKnob at:_lHome offset:CGPointZero r:60];
    _rBase.hidden = _rKnob.hidden = YES;
    [CATransaction commit];
}
- (void)msDrawStick:(CAShapeLayer *)b knob:(CAShapeLayer *)k at:(CGPoint)p offset:(CGPoint)o r:(CGFloat)r {
    b.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(p.x - r, p.y - r, 2 * r, 2 * r)].CGPath;
    k.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(p.x + o.x - 24, p.y + o.y - 24, 48, 48)].CGPath;
    b.hidden = k.hidden = _hiddenByUser;
}
- (BOOL)msNear:(CGPoint)p to:(CGPoint)c r:(CGFloat)r { CGFloat dx = p.x - c.x, dy = p.y - c.y; return dx * dx + dy * dy <= r * r; }
- (void)msPaint:(MSCtl *)c {
    BOOL on = c.touch != nil, hide = c.kind != MSCtlToggle && _hiddenByUser;
    c.shape.hidden = c.text.hidden = hide;
    c.shape.fillColor = [UIColor colorWithWhite:1 alpha:on ? 0.45 : 0.12].CGColor;
    c.shape.strokeColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    if (c.kind == MSCtlToggle) c.shape.opacity = c.text.opacity = _hiddenByUser ? 0.4 : 1;
}
- (MSCtl *)msCtlAt:(CGPoint)p {
    for (MSCtl *c in _ctls) {
        if (_hiddenByUser && c.kind != MSCtlToggle) continue;
        CGFloat dx = p.x - c.center.x, dy = p.y - c.center.y, r = c.r + 8;
        if (dx * dx + dy * dy <= r * r) return c;
    }
    return nil;
}
/* empty screen: in gameplay it's ours (stick / camera); in menus it falls through to the game as a mouse click */
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    if (self.hidden) return nil;
    if ([self msCtlAt:p]) return self;
    if (_hiddenByUser) return nil;
    /* the drawn sticks always work (the game doesn't reliably lock the pointer or hide the cursor in gameplay); a quick
       tap on one in a menu is passed on to the game as a click, so menu items under them stay usable */
    if ([self msNear:p to:_lHome r:85] || [self msNear:p to:_rHome r:80]) return self;
    return g_pointerLocked ? self : nil;
}
- (void)msSyncDpad {
    int x = 0, y = 0; for (MSCtl *c in _ctls) if (c.touch) { x += c.dpadX; y += c.dpadY; }
    MSPadSetStick(g_pad.dpad, x, y);
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self]; MSCtl *c = [self msCtlAt:p];
        if (c && c.kind == MSCtlToggle) {
            _hiddenByUser = !_hiddenByUser; [CATransaction begin]; [CATransaction setDisableActions:YES];
            for (MSCtl *x in _ctls) [self msPaint:x];
            _stickBase.hidden = _stickKnob.hidden = _rBase.hidden = _rKnob.hidden = _hiddenByUser;
            [CATransaction commit]; continue;
        }
        if (c) {
            c.touch = t; MSPadSetButton(c.button, 1); if (c.dpadX || c.dpadY) [self msSyncDpad]; if (c.key) MSKey((GCKeyCode)c.key, YES);
            [self msPaint:c]; continue;
        }
        if (!_rTouch && [self msNear:p to:_rHome r:80]) { _rTouch = t; _stickT0 = t.timestamp; _stickP0 = p; _stickMax = 0; [self msRightStick:p]; continue; }
        if (p.x < self.bounds.size.width * 0.45) {
            if (_moveTouch) continue;
            _moveTouch = t; _moveOrigin = [self msNear:p to:_lHome r:85] ? _lHome : p;   /* on the stick: centred; elsewhere: it follows the thumb */
            _stickT0 = t.timestamp; _stickP0 = p; _stickMax = 0;
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            [self msDrawStick:_stickBase knob:_stickKnob at:_moveOrigin offset:CGPointZero r:60];
            [CATransaction commit];
            [self msLeftStick:p];
        } else if (!_lookTouch) { _lookTouch = t; _lookLast = p; _lookT = t.timestamp; _lookX = _lookY = 0; }
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self];
        if (t == _moveTouch || t == _rTouch) _stickMax = MAX(_stickMax, hypot(p.x - _stickP0.x, p.y - _stickP0.y));
        if (t == _moveTouch) [self msLeftStick:p];
        else if (t == _rTouch) [self msRightStick:p];
        else if (t == _lookTouch) {
            /* camera: finger speed -> right stick, from the touch's own timestamps (touches arrive once per game
               frame; per-display-frame sampling gave a spike and then zeros = jerky camera); ~700 pt/s is full */
            {   /* camera swipe: finger movement is collected (coalesced touches, full touch rate) and handed to the game once
                   per game frame - as the right stick (default) or as mouse motion (LookMode = mouse) */
                static double scale; if (!scale) scale = MSCfgD(@"LookMouseScale", 2.0) * MSLookSensitivity();
                double k = g_lookStick ? 1 : scale * _lookSpeed;
                CGPoint q = p; NSArray *cs = [e coalescedTouchesForTouch:t]; if (cs.count) q = [cs.lastObject locationInView:self];
                MSLookAdd(CGPointMake((q.x - _lookLast.x) * k, (q.y - _lookLast.y) * k));
                _lookLast = q; _lookT = t.timestamp; _lookMoved = g_lookFingerAt = CACurrentMediaTime();
                continue;
            }
        } else {                                              /* a finger that slid off its button lets go of it */
            for (MSCtl *c in [_ctls copy]) if (c.touch == t && c.kind == MSCtlButton) {
                CGFloat dx = p.x - c.center.x, dy = p.y - c.center.y, r = c.r + 24;
                if (dx * dx + dy * dy > r * r) [self msRelease:c];
            }
        }
    }
}
- (void)msWASD:(int)want {                       /* bit 0 W, 1 A, 2 S, 3 D */
    GCKeyCode keys[4] = { GCKeyCodeKeyW, GCKeyCodeKeyA, GCKeyCodeKeyS, GCKeyCodeKeyD };
    for (int i = 0; i < 4; i++) if (((want ^ _wasd) >> i) & 1) MSKey(keys[i], (want >> i) & 1);
    _wasd = want;
}
- (void)msLeftStick:(CGPoint)p {
    CGFloat dx = p.x - _moveOrigin.x, dy = p.y - _moveOrigin.y, len = hypot(dx, dy), k = len > 60 ? 60 / len : 1;
    MSPadSetStick(g_pad.leftThumbstick, dx * k / 60, -dy * k / 60);
    if (!g_pad) { float x = dx * k / 60, y = -dy * k / 60; [self msWASD:(y > 0.4) | (x < -0.4) << 1 | (y < -0.4) << 2 | (x > 0.4) << 3]; }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [self msDrawStick:_stickBase knob:_stickKnob at:_moveOrigin offset:CGPointMake(dx * k, dy * k) r:60];
    [CATransaction commit];
}
- (void)msRightStick:(CGPoint)p {
    CGFloat dx = p.x - _rHome.x, dy = p.y - _rHome.y, len = hypot(dx, dy), k = len > 55 ? 55 / len : 1;
    MSPadSetStick(g_pad.rightThumbstick, dx * k / 55, -dy * k / 55);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [self msDrawStick:_rBase knob:_rKnob at:_rHome offset:CGPointMake(dx * k, dy * k) r:55];
    [CATransaction commit];
}
- (void)msRelease:(MSCtl *)c { c.touch = nil; MSPadSetButton(c.button, 0); if (c.key) MSKey((GCKeyCode)c.key, NO); if (c.dpadX || c.dpadY) [self msSyncDpad]; [self msPaint:c]; }
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        if ((t == _moveTouch || t == _rTouch) && !g_pointerLocked && t.timestamp - _stickT0 < 0.25 && _stickMax < 12) {
            MSHostView *h = g_hostView; CGPoint q = MSTouchIn(t, h);     /* quick tap on a stick in a menu: a click */
            if (h) [h msClick:q right:NO];
        }
        if (t == _moveTouch) {
            _moveTouch = nil; MSPadSetStick(g_pad.leftThumbstick, 0, 0); [self msWASD:0];
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            [self msDrawStick:_stickBase knob:_stickKnob at:_lHome offset:CGPointZero r:60];
            [CATransaction commit];
        } else if (t == _rTouch) {
            _rTouch = nil; MSPadSetStick(g_pad.rightThumbstick, 0, 0);
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            [self msDrawStick:_rBase knob:_rKnob at:_rHome offset:CGPointZero r:55];
            [CATransaction commit];
        } else if (t == _lookTouch) { _lookTouch = nil; _lookX = _lookY = 0; g_lookFingerAt = 0; }   /* the stick eases back in MSLookFlushStick */
        for (MSCtl *c in _ctls) if (c.touch == t) [self msRelease:c];
    }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self touchesEnded:ts withEvent:e]; }
- (void)msTick:(CADisplayLink *)l {
    BOOL want = g_frames > 60 && !(g_vpad ? g_realPad : MSRealControllerConnected()) && !g_gcmCount;
    if (want != _shown) { _shown = want; self.hidden = !want; if (want) MSLogf(@"touch controls shown"); }
    if (!want) return;
    [self msLayout];
    float op = (g_pointerLocked || g_cursorHidden || _moveTouch || _rTouch) ? 1 : 0.35;    /* sticks dimmed in menus */
    if (_stickBase.opacity != op) { [CATransaction begin]; [CATransaction setDisableActions:YES];
        _stickBase.opacity = _stickKnob.opacity = _rBase.opacity = _rKnob.opacity = op; [CATransaction commit]; }
    /* camera look is driven from touchesMoved; here it only stops when the finger rests */
    double now = CACurrentMediaTime();
    (void)now;
}
@end

@interface MSPadWindow : UIWindow @end
@implementation MSPadWindow       /* only the pad's own touches stay here; everything else reaches the game below */
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { UIView *v = [super hitTest:p withEvent:e]; return v == self || v == self.rootViewController.view ? nil : v; }
@end
@interface MSPadVC : UIViewController @end
@implementation MSPadVC
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
static UIWindow *g_padWin;
/* test aid: AutoKeys = "20:a,40:down,60:tap@650/360,70:scroll@500/250/-400,80:rsdown" runs after the first frames
 * (seconds from then). Keys: space, enter, esc (anything else = esc). Gamepad (virtual controller): a b x y lb rb lt rt
 * menu view l3 r3, up down left right (d-pad), lsup/lsdown/lsleft/lsright and rsup/... (stick held 1.5 s).
 * Touch-as-mouse on the game view: tap@X/Y (points from the top left), scroll@X/Y/D (a finger drag of D points). */
static void MSAutoPadPress(GCControllerButtonInput *b) { MSMainAsync(^{ MSPadSetButton(b, 1); }); usleep(150000); MSMainAsync(^{ MSPadSetButton(b, 0); }); }
static void MSAutoKeys(void) {
    NSString *ak = MSConfig()[@"AutoKeys"];
    if (ak.length) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (g_frames < 60) usleep(200000);
        double t0 = CACurrentMediaTime();
        for (NSString *item in [ak componentsSeparatedByString:@","]) {
            NSRange c = [item rangeOfString:@":"]; if (c.location == NSNotFound) continue;
            double at = [[item substringToIndex:c.location] doubleValue]; NSString *k = [[item substringFromIndex:c.location + 1] lowercaseString];
            while (CACurrentMediaTime() - t0 < at) usleep(100000);
            MSLogf(@"AutoKeys: %@", k);
            GCExtendedGamepad *g = g_pad;
            NSDictionary *btn = g ? @{ @"a": g.buttonA, @"b": g.buttonB, @"x": g.buttonX, @"y": g.buttonY, @"lb": g.leftShoulder, @"rb": g.rightShoulder,
                                       @"lt": g.leftTrigger, @"rt": g.rightTrigger, @"menu": g.buttonMenu, @"view": g.buttonOptions ?: g.buttonMenu,
                                       @"l3": g.leftThumbstickButton ?: g.buttonA, @"r3": g.rightThumbstickButton ?: g.buttonA } : @{};
            if (btn[k]) { MSAutoPadPress(btn[k]); continue; }
            NSDictionary *dir = @{ @"up": @[ @0, @1 ], @"down": @[ @0, @-1 ], @"left": @[ @-1, @0 ], @"right": @[ @1, @0 ] };
            if (g && dir[k]) {
                float x = [dir[k][0] floatValue], y = [dir[k][1] floatValue];
                MSMainAsync(^{ MSPadSetStick(g.dpad, x, y); }); usleep(150000); MSMainAsync(^{ MSPadSetStick(g.dpad, 0, 0); }); continue;
            }
            if (g && k.length > 2 && ([k hasPrefix:@"ls"] || [k hasPrefix:@"rs"]) && dir[[k substringFromIndex:2]]) {
                NSArray *v = dir[[k substringFromIndex:2]]; GCControllerDirectionPad *st = [k hasPrefix:@"ls"] ? g.leftThumbstick : g.rightThumbstick;
                float x = [v[0] floatValue], y = [v[1] floatValue];
                MSMainAsync(^{ MSPadSetStick(st, x, y); }); usleep(1500000); MSMainAsync(^{ MSPadSetStick(st, 0, 0); }); continue;
            }
            if ([k hasPrefix:@"tap@"] || [k hasPrefix:@"scroll@"]) {
                NSArray *n = [[k substringFromIndex:[k rangeOfString:@"@"].location + 1] componentsSeparatedByString:@"/"]; if (n.count < 2) continue;
                CGPoint p = CGPointMake([n[0] doubleValue], [n[1] doubleValue]); double dist = n.count > 2 ? [n[2] doubleValue] : -300;
                BOOL tap = [k hasPrefix:@"tap@"];
                MSMainAsync(^{
                    NSApplication *app = (NSApplication *)NSApp; NSWindow *w = app.keyWindow ?: app.windows.firstObject;
                    MSHostView *h = [w.contentView host] ?: g_hostView; if (!h) { MSLogf(@"AutoKeys: no game view"); return; }
                    MSOpenMouseGate();
                    if (tap) [h msClick:p right:NO];
                    else for (int i = 0; i < 20; i++) [h msScrollBy:CGPointMake(0, dist / 20) at:p];
                });
                continue;
            }
            GCKeyCode code = [k isEqual:@"space"] ? GCKeyCodeSpacebar : [k isEqual:@"enter"] ? GCKeyCodeReturnOrEnter : GCKeyCodeEscape;
            MSMainAsync(^{ MSKey(code, YES); }); usleep(120000); MSMainAsync(^{ MSKey(code, NO); });
        }
    });
}
static void MSTouchPadCreate(UIWindowScene *sc) {                 /* main thread, before the game's main() */
    MSAutoKeys();
    if ([MSConfig()[@"TouchControls"] isEqual:@NO]) return;
    /* The virtual gamepad used to be off: the main-menu crash looked tied to it, but that was the libcurl stub
       (requests never completed). VirtualController = NO gives the keyboard-only pad. */
    if ([MSConfig()[@"VirtualController"] isEqual:@NO]) MSLogf(@"touch pad: keyboard/mouse mode (no virtual controller)");
    else {
        g_vpad = [GCController controllerWithExtendedGamepad];
        g_pad = g_vpad.extendedGamepad;
        if (g_pad) MSHookGamepadHandlers();
        if (!g_pad) { MSLogf(@"touch pad: no virtual controller"); g_vpad = nil; g_vpad = nil; }
        g_vpad.playerIndex = GCControllerPlayerIndex1;
        Method m = class_getClassMethod(GCController.class, @selector(controllers));
        g_origControllers = method_setImplementation(m, (IMP)ms_controllers);
        MSLogf(@"touch pad: snapshot controller category was %@ / vendor %@", g_vpad.productCategory, g_vpad.vendorName);
        Method pc = class_getInstanceMethod(GCController.class, @selector(productCategory));
        if (pc) g_origCategory = method_setImplementation(pc, (IMP)ms_productCategory);
        Method vn = class_getInstanceMethod(GCController.class, @selector(vendorName));
        if (vn) g_origVendor = method_setImplementation(vn, (IMP)ms_vendorName);
        Method eg = class_getInstanceMethod(GCController.class, @selector(extendedGamepad));
        g_origExtGamepad = method_setImplementation(eg, (IMP)ms_extendedGamepad);
        Method pp = class_getInstanceMethod(GCController.class, @selector(physicalInputProfile));
        if (pp) g_origPhys = method_setImplementation(pp, (IMP)ms_physicalInputProfile);
        Method cur = class_getClassMethod(GCController.class, @selector(current));
        if (cur) g_origCurrent = method_setImplementation(cur, (IMP)ms_current);
    }
    g_padWin = sc ? [[MSPadWindow alloc] initWithWindowScene:sc] : [[MSPadWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    g_padWin.windowLevel = UIWindowLevelNormal + 1; g_padWin.backgroundColor = UIColor.clearColor;
    g_padWin.rootViewController = [MSPadVC new]; g_padWin.rootViewController.view.backgroundColor = UIColor.clearColor;
    MSPadView *pv = [[MSPadView alloc] initWithFrame:g_padWin.rootViewController.view.bounds];
    [g_padWin.rootViewController.view addSubview:pv]; g_padWin.hidden = NO;
    /* tell the game a controller arrived once it's running (it also finds it in +controllers); a real controller takes
       over from the virtual one: the game sees the virtual pad disconnect, and connect again when the real one leaves */
    if (g_vpad) {
        g_realPad = MSRealControllerConnected();
        static long long gen;                         /* bumps on every connect/disconnect: a pending "gone" check sees newer news */
        void (^update)(void) = ^{
            BOOL real = MSRealControllerConnected(); if (real == g_realPad) return;
            g_realPad = real;
            for (GCControllerElement *el in g_pad.allElements) if ([el isKindOfClass:GCControllerButtonInput.class]) [(GCControllerButtonInput *)el setValue:0];
            [g_pad.leftThumbstick setValueForXAxis:0 yAxis:0]; [g_pad.rightThumbstick setValueForXAxis:0 yAxis:0]; [g_pad.dpad setValueForXAxis:0 yAxis:0];
            [NSNotificationCenter.defaultCenter postNotificationName:(real ? GCControllerDidDisconnectNotification : GCControllerDidConnectNotification) object:g_vpad];
            MSLogf(real ? @"real controller connected: on-screen controller withdrawn" : @"real controller gone: on-screen controller back");
        };
        for (NSString *n in @[ GCControllerDidConnectNotification, GCControllerDidDisconnectNotification ])
            [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *x) {
                if (x.object == g_vpad) return;
                GCController *c = x.object; MSLogf(@"controller %@: %@ (%@)", [x.name containsString:@"Disconnect"] ? @"disconnected" : @"connected", c.vendorName, c.productCategory);
                BOOL gone = [x.name containsString:@"Disconnect"]; long long my = ++gen;
                if (!gone && c.extendedGamepad) g_realGP = c.extendedGamepad;
                /* connect: withdraw the on-screen pad right now, inside this notification - this observer was added before
                   the game's, so the game sees "virtual pad gone" before "real pad here" and makes the real one active
                   (before, the virtual pad's disconnect came a frame later and sometimes left the game with no pad).
                   disconnect: Bluetooth pads drop out for a second now and then (tester log: gone/back within 1-2 s), so
                   the on-screen pad only comes back if the real one stays away for 2.5 s. */
                if (!gone) { if (NSThread.isMainThread) update(); MSMainAsync(update); return; }   /* 2nd: in case the list didn't have it yet */
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    if (my == gen) MSMainAsync(update);
                });
            }];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (g_frames < 60) usleep(200000);
            sleep(2);
            MSMainAsync(^{
                /* A pad that was already connected when the game started is never picked up: the game only hooks up
                   controllers it gets a connect notification for (tester: stuck at "press space to continue" until
                   the pad was unplugged and plugged in again). Same cure as for the virtual pad: tell it now. */
                if (g_realPad) {
                    MSLogf(@"touch pad: real controller present, virtual one stays out");
                    if (g_realHandlerSeen) return;
                    NSArray *all = ((NSArray *(*)(id, SEL))g_origControllers)(GCController.class, @selector(controllers));
                    for (GCController *c in all) if (!c.isSnapshot && c.extendedGamepad) {
                        g_realGP = c.extendedGamepad;
                        [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:c];
                        MSLogf(@"controller: told the game about %@, connected before it started", c.vendorName);
                    }
                    return;
                }
                [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:g_vpad];
                MSLogf(@"touch pad: virtual controller connected");
            });
        });
    }
    MSLogf(@"touch pad ready (L3=%d R3=%d View=%d)", g_pad.leftThumbstickButton != nil,
           g_pad.rightThumbstickButton != nil, g_pad.buttonOptions != nil);
}

static IMP g_oCBPresent, g_oDrPresent, g_oCBPresentMin, g_oDrPresentMin, g_oCBCommit;
/* GPU busy time: for 1 s every 30 s each committed command buffer reports its GPU start/end; the merged intervals
   say how much of that second the GPU was working (logged as "gpu: busy N%"). GPUSampler = NO turns it off. */
static _Atomic BOOL g_gpuSampling; static os_unfair_lock g_gpuLock = OS_UNFAIR_LOCK_INIT;
static double g_gpuIv[4096][2]; static int g_gpuN;
static char g_mirrorKey; static BOOL g_gpuSamplerOn;
static _Atomic int g_mirrorBusy;
/* render thread, right after the game committed a command buffer that presents: copy its picture to the phone's layer.
   A command buffer on the same queue runs after the game's, so the copy sees the finished frame. Skipped while two
   copies are still on the GPU (never holds the game up). */
static void MSMirrorFrame(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d) {
    CAMetalLayer *ml = g_mirrorLayer; id<MTLTexture> src = d.texture;
    if (!ml || !src || src.framebufferOnly || src.sampleCount != 1 || g_mirrorBusy >= 2) return;
    @try {
        CGSize sz = CGSizeMake(src.width, src.height);
        if (!CGSizeEqualToSize(ml.drawableSize, sz) || ml.pixelFormat != src.pixelFormat) {
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            ml.pixelFormat = src.pixelFormat; ml.drawableSize = sz;
            [CATransaction commit];
            MSLogf(@"TV out: mirroring %lux%lu (pixel format %lu) to the phone", (unsigned long)src.width, (unsigned long)src.height, (unsigned long)src.pixelFormat);
        }
        id<CAMetalDrawable> md = ((id (*)(id, SEL))g_origNextDrawable)(ml, @selector(nextDrawable));
        if (!md || md.texture.width != src.width || md.texture.height != src.height) return;
        id<MTLCommandBuffer> c2 = [cb.commandQueue commandBuffer]; if (!c2) return;
        id<MTLBlitCommandEncoder> b = [c2 blitCommandEncoder]; [b copyFromTexture:src toTexture:md.texture]; [b endEncoding];
        ((void (*)(id, SEL, id))g_oCBPresent)(c2, @selector(presentDrawable:), md);
        g_mirrorBusy++; [c2 addCompletedHandler:^(id<MTLCommandBuffer> x) { g_mirrorBusy--; }];
        [c2 commit];
    } @catch (NSException *e) {
        static int n; if (n++ < 3) MSLogf(@"TV out: mirror failed: %@ - phone stays black", e.reason);
        g_mirrorOn = NO;
    }
}
static void ms_cbCommit(id self, SEL c) {
    id md = nil;
    if (g_mirrorOn && g_oCBPresent && (md = objc_getAssociatedObject(self, &g_mirrorKey)))
        objc_setAssociatedObject(self, &g_mirrorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (g_gpuSampling) {
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> b) {
            CFTimeInterval a = b.GPUStartTime, e = b.GPUEndTime; if (e <= a || a <= 0) return;
            os_unfair_lock_lock(&g_gpuLock); if (g_gpuN < 4096) { g_gpuIv[g_gpuN][0] = a; g_gpuIv[g_gpuN][1] = e; g_gpuN++; } os_unfair_lock_unlock(&g_gpuLock);
        }];
    }
    ((void (*)(id, SEL))g_oCBCommit)(self, c);
    if (md) MSMirrorFrame(self, md);
}
static int MSCmpIv(const void *x, const void *y) { double a = ((const double *)x)[0], b = ((const double *)y)[0]; return a < b ? -1 : a > b; }
static NSString *MSGPUSample(void) {                    /* progress thread: blocks ~1.2 s */
    if (!g_oCBCommit || !g_gpuSamplerOn) return nil;
    os_unfair_lock_lock(&g_gpuLock); g_gpuN = 0; os_unfair_lock_unlock(&g_gpuLock);
    long long f0 = g_frames; double t0 = CACurrentMediaTime(); g_gpuSampling = YES; usleep(1000000); g_gpuSampling = NO;
    double t1 = CACurrentMediaTime(); long long frames = g_frames - f0; usleep(200000);     /* late completions */
    os_unfair_lock_lock(&g_gpuLock); int n = g_gpuN; static double iv[4096][2]; memcpy(iv, g_gpuIv, sizeof(double) * 2 * n); os_unfair_lock_unlock(&g_gpuLock);
    if (!n || !frames) return nil;
    qsort(iv, n, sizeof iv[0], MSCmpIv);
    double busy = 0, cs = iv[0][0], ce = iv[0][1];
    for (int i = 1; i < n; i++) { if (iv[i][0] > ce) { busy += ce - cs; cs = iv[i][0]; ce = iv[i][1]; } else if (iv[i][1] > ce) ce = iv[i][1]; }
    busy += ce - cs;
    return [NSString stringWithFormat:@"gpu: busy %.0f%% of the last second (%.1f ms per frame, %lld frames, %d command buffers)",
            100 * busy / (t1 - t0), 1000 * busy / frames, frames, n];
}
/* 120 Hz. iOS runs the screen at 60 Hz for a Metal layer unless something in the app asks for more with a display
 * link's preferredFrameRateRange (the Info.plist key alone only allows it). The Mac game never asks, so menus stopped
 * at exactly 60 with VSync 120 / Off, and VSync 40 gave 30. The game's present calls say what it wants
 * (afterMinimumDuration = its VSync cap, plain present = uncapped); unless that fits 60 Hz a display link on its own
 * thread asks for 120 Hz, otherwise it is paused (no extra refreshes at 30/60). HighRefresh = NO turns it off. */
@interface MSRefreshTicker : NSObject @end
@implementation MSRefreshTicker
- (void)tick:(CADisplayLink *)l { }
- (void)check:(NSTimer *)t {
    CADisplayLink *l = t.userInfo; double d = g_paceT > 0 ? g_paceT : g_gameMinDur;
    /* 60 Hz only fits caps that divide 60 (60, 30, 20): VSync 40 (25 ms) fell back to 33 ms = 30 FPS. Anything else -
       40, 120, uncapped, a custom Max FPS - gets 120 Hz, where 25 ms is exactly 3 refreshes. */
    int fps = d > 0 ? (int)lround(1 / d) : 0;
    BOOL fits60 = fps > 0 && fps <= 60 && fabs(60.0 / fps - lround(60.0 / fps)) < 0.05;
    BOOL want = d >= 0 && !fits60 && !g_inBackground;
    if (l.paused == !want) return;
    l.paused = !want;
    MSLogf(@"screen: %@ (game cap %@)", want ? @"asking for 120 Hz" : @"back to the normal refresh rate", fps ? [NSString stringWithFormat:@"%d FPS", fps] : @"none");
}
@end
static void MSStartRefreshTicker(void) {
    if ([MSConfig()[@"HighRefresh"] isEqual:@NO] || UIScreen.mainScreen.maximumFramesPerSecond <= 60) return;
    NSThread *th = [[NSThread alloc] initWithBlock:^{
        MSRefreshTicker *k = [MSRefreshTicker new];
        CADisplayLink *l = [CADisplayLink displayLinkWithTarget:k selector:@selector(tick:)];
        NSInteger mx = UIScreen.mainScreen.maximumFramesPerSecond;
        l.preferredFrameRateRange = CAFrameRateRangeMake(80, mx, mx); l.paused = YES;
        [l addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        [NSRunLoop.currentRunLoop addTimer:[NSTimer timerWithTimeInterval:0.5 target:k selector:@selector(check:) userInfo:l repeats:YES] forMode:NSRunLoopCommonModes];
        [NSRunLoop.currentRunLoop run];
    }];
    th.name = @"CyPort.refresh"; th.qualityOfService = NSQualityOfServiceUtility; [th start];
}
/* The game's cap is an exact multiple of the refresh (40 FPS = 25.0 ms = 3 refreshes at 120 Hz); with the usual
   timing jitter some frames just missed it and waited a 4th refresh: VSync 40 showed 37-39 FPS. 2 ms less still lands
   on the same refresh (one refresh is >= 8.3 ms) without missing it. */
static CFTimeInterval MSCapMargin(CFTimeInterval t) {
    static int on = -1; if (on < 0) on = MSCfgD(@"CapMargin", 1) != 0;
    return on && t > 0.004 ? t - 0.002 : t;
}
/* Metal's presentDrawable:afterMinimumDuration: calls the drawable's presentAfterMinimumDuration: itself, so both hooks
   ran for one frame (margin taken twice, log said "cap 43"). The command buffer path marks its drawables. */
static char g_capKey;
/* what the screen really did: for 2 s every 30 s each presented frame reports when it reached the screen; logged as
   "shown: N frames, every 8 ms x a, 17 ms x b, ..." (counts per number of 120 Hz refreshes between frames) */
static _Atomic BOOL g_shownSampling; static os_unfair_lock g_shownLock = OS_UNFAIR_LOCK_INIT;
static double g_shownLast; static int g_shownHist[7];
static void MSShownWatch(id<MTLDrawable> d) {
    static double next; double now = CACurrentMediaTime();
    if (!g_shownSampling) {
        if (now < next || MSCfgD(@"ShownSampler", 1) == 0) return;
        next = now + 30; g_shownSampling = YES; g_shownLast = 0; memset(g_shownHist, 0, sizeof g_shownHist);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                os_unfair_lock_lock(&g_shownLock); int h[7]; memcpy(h, g_shownHist, sizeof h); os_unfair_lock_unlock(&g_shownLock);
                int n = 0; for (int i = 0; i < 7; i++) n += h[i];
                if (n) MSLogf(@"shown: %d frames, every 8 ms x%d, 17 ms x%d, 25 ms x%d, 33 ms x%d, 42 ms x%d, longer x%d (game cap %.1f ms)",
                              n, h[1], h[2], h[3], h[4], h[5], h[6] + h[0], 1000 * (double)g_gameMinDur);
            });
            g_shownSampling = NO;
        });
    }
    if (![(id)d respondsToSelector:@selector(addPresentedHandler:)]) return;
    [d addPresentedHandler:^(id<MTLDrawable> dr) {
        double t = dr.presentedTime; if (t <= 0) return;
        os_unfair_lock_lock(&g_shownLock);
        if (g_shownLast > 0) { long k = lround((t - g_shownLast) * 120); if (k < 0) k = 0; if (k > 6) k = 6; g_shownHist[k]++; }
        g_shownLast = t;
        os_unfair_lock_unlock(&g_shownLock);
    }];
}
static void ms_cbPresentMin(id self, SEL c, id d, CFTimeInterval t) {   /* the game's VSync setting uses this one */
    g_gameMinDur = t; t = MSCapMargin(t); MSLowLatencyTrack(self);
    if (d) objc_setAssociatedObject(d, &g_capKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MSShownWatch(d);
    if (g_mirrorOn) objc_setAssociatedObject(self, &g_mirrorKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    double T = g_paceT; static int said; if (!said++) MSLogf(@"frame pacing: game presents with presentDrawable:afterMinimumDuration: %.4f", (double)g_gameMinDur);
    ((void (*)(id, SEL, id, CFTimeInterval))g_oCBPresentMin)(self, c, d, T > 0 ? MAX(t, T - 0.002) : t);
}
static void ms_drPresentMin(id self, SEL c, CFTimeInterval t) {
    if (objc_getAssociatedObject(self, &g_capKey)) { ((void (*)(id, SEL, CFTimeInterval))g_oDrPresentMin)(self, c, t); return; }
    g_gameMinDur = t; t = MSCapMargin(t); MSShownWatch(self);
    double T = g_paceT; ((void (*)(id, SEL, CFTimeInterval))g_oDrPresentMin)(self, c, T > 0 ? MAX(t, T - 0.002) : t);
}
/* Uncapped (VSync Off): a plain present is treated by iOS as ordinary 60 Hz content - menus sat at exactly 60 while
   VSync 120 (an 8.3 ms cap) ran at 120. So "no cap" is passed on as "every refresh of the fastest screen rate", which
   is all the screen can show anyway. Uncapped = NO keeps the plain present. */
static CFTimeInterval MSUncappedDur(void) {
    static double dur = -1;
    if (dur < 0) { NSInteger mx = UIScreen.mainScreen.maximumFramesPerSecond; dur = MSCfgD(@"Uncapped", 1) != 0 && mx > 60 && ![MSConfig()[@"HighRefresh"] isEqual:@NO] ? 1.0 / mx : 0; }
    return dur;
}
static void ms_cbPresent(id self, SEL c, id d) {                /* -[MTLCommandBuffer presentDrawable:] */
    g_gameMinDur = 0; MSLowLatencyTrack(self);
    if (d) objc_setAssociatedObject(d, &g_capKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MSShownWatch(d);
    if (g_mirrorOn) objc_setAssociatedObject(self, &g_mirrorKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    double T = g_paceT; static int said; if (!said++) MSLogf(@"frame pacing: game presents with presentDrawable:");
    double U = MSUncappedDur();
    if (T > 0 || U > 0) ((void (*)(id, SEL, id, CFTimeInterval))(g_oCBPresentMin ?: class_getMethodImplementation(object_getClass(self), @selector(presentDrawable:afterMinimumDuration:))))(self, @selector(presentDrawable:afterMinimumDuration:), d, T > 0 ? T - 0.002 : MSCapMargin(U));
    else ((void (*)(id, SEL, id))g_oCBPresent)(self, c, d);
}
static void ms_drPresent(id self, SEL c) {                      /* -[CAMetalDrawable present] */
    if (objc_getAssociatedObject(self, &g_capKey)) { ((void (*)(id, SEL))g_oDrPresent)(self, c); return; }
    g_gameMinDur = 0; MSShownWatch(self);
    double T = g_paceT; static int said; if (!said++) MSLogf(@"frame pacing: game presents with [drawable present]");
    double U = MSUncappedDur();
    if (T > 0 || U > 0) ((void (*)(id, SEL, CFTimeInterval))(g_oDrPresentMin ?: class_getMethodImplementation(object_getClass(self), @selector(presentAfterMinimumDuration:))))(self, @selector(presentAfterMinimumDuration:), T > 0 ? T - 0.002 : MSCapMargin(U));
    else ((void (*)(id, SEL))g_oDrPresent)(self, c);
}
static void MSInstallPacing(void) {
    if ([MSConfig()[@"FramePacing"] isEqual:@NO]) { MSLogf(@"frame pacing: off (FramePacing = NO)"); return; }
    Method m = class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable));
    if (m && !g_origNextDrawable) g_origNextDrawable = method_setImplementation(m, (IMP)ms_nextDrawable);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    Method p = cb ? class_getInstanceMethod(object_getClass(cb), @selector(presentDrawable:)) : NULL;
    Method cm = cb ? class_getInstanceMethod(object_getClass(cb), @selector(commit)) : NULL;
    g_gpuSamplerOn = ![MSConfig()[@"GPUSampler"] isEqual:@NO];
    if (cm && !g_oCBCommit && (g_gpuSamplerOn || MSCfgD(@"TVMirror", 1) != 0)) g_oCBCommit = method_setImplementation(cm, (IMP)ms_cbCommit);
    Method pm = cb ? class_getInstanceMethod(object_getClass(cb), @selector(presentDrawable:afterMinimumDuration:)) : NULL;
    if (p && pm && !g_oCBPresent) { g_oCBPresent = method_setImplementation(p, (IMP)ms_cbPresent); g_oCBPresentMin = method_setImplementation(pm, (IMP)ms_cbPresentMin); }
    Class D = NSClassFromString(@"CAMetalDrawable"); Method dp = D ? class_getInstanceMethod(D, @selector(present)) : NULL;
    Method dpm = D ? class_getInstanceMethod(D, @selector(presentAfterMinimumDuration:)) : NULL;
    if (dp && dpm && !g_oDrPresent) { g_oDrPresent = method_setImplementation(dp, (IMP)ms_drPresent); g_oDrPresentMin = method_setImplementation(dpm, (IMP)ms_drPresentMin); }
    MSStartRefreshTicker();
    MSLogf(@"frame pacing hooks: nextDrawable %d, command buffer %@ %d, drawable %d", g_origNextDrawable != NULL, NSStringFromClass(object_getClass(cb)), g_oCBPresent != NULL, g_oDrPresent != NULL);
}
static void MSStatusCreate(void) {                    /* main thread, before the game's main() */
    MSInstallPacing();
    if ([MSConfig()[@"ShowStatus"] isEqual:@NO]) return;
    UIWindowScene *sc = MSAppScene();
    if (!sc) for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.windowScene) { sc = w.windowScene; break; }
    g_statusWin = sc ? [[UIWindow alloc] initWithWindowScene:sc] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    g_statusWin.windowLevel = UIWindowLevelAlert + 5; g_statusWin.userInteractionEnabled = NO;
    g_statusWin.backgroundColor = UIColor.clearColor; g_statusWin.rootViewController = [UIViewController new];
    g_statusWin.rootViewController.view.backgroundColor = UIColor.clearColor;
    CALayer *root = g_statusWin.rootViewController.view.layer; g_stRoot = root;
    UIEdgeInsets si = (sc.windows.firstObject ?: UIApplication.sharedApplication.windows.firstObject).safeAreaInsets;
    g_stPad = MAX(24, MAX(MAX(si.left, si.right), MAX(si.top, si.bottom)) + 12);
    g_stBg = [CALayer layer]; g_stBg.backgroundColor = [UIColor colorWithWhite:0.04 alpha:1].CGColor; [root addSublayer:g_stBg];
    g_stTitle = MSTextLayer(20, NO, UIColor.whiteColor); g_stTitle.string = @"Loading Cyberpunk 2077…"; [g_stBg addSublayer:g_stTitle];
    g_stTrack = [CALayer layer]; g_stTrack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor; g_stTrack.cornerRadius = 4; [g_stBg addSublayer:g_stTrack];
    g_stFill = [CALayer layer]; g_stFill.backgroundColor = [UIColor colorWithRed:0.98 green:0.93 blue:0.0 alpha:1].CGColor; g_stFill.cornerRadius = 4; g_stFill.anchorPoint = CGPointZero; [g_stTrack addSublayer:g_stFill];
    g_stHead = MSTextLayer(13, YES, [UIColor colorWithWhite:1 alpha:0.9]); [g_stBg addSublayer:g_stHead];
    g_stLog = MSTextLayer(10, YES, [UIColor colorWithWhite:1 alpha:0.6]); g_stLog.wrapped = YES; g_stLog.truncationMode = kCATruncationNone; [g_stBg addSublayer:g_stLog];
    g_statusWin.hidden = NO;
    MSTouchPadCreate(sc);
    MSStartReadProgress();
}
/* Engine allocators keep a 64-slot table at the start of each pool object: slot i = 32-bit hash of pthread_self() of
 * the thread that owns per-thread cache i (0x300 bytes each, at +0x100). Lookups compare only that hash. Two live
 * threads with one hash would share an unlocked cache. This watches all pool objects (StaticPoolStorage<...>::storage
 * -> object pointer & ~7) for duplicate hashes and slot use. */
static const uint64_t g_poolStorages[] = {
#include "poolstorages.inc"
};
/* the engine's hash of pthread_self() (CityHash-style; note the low word is shifted in 32 bits) */
static uint32_t MSEngineThreadHash(uint64_t x) {
    const uint64_t K = 0x9ddfea08eb382d69ULL;
    uint64_t hi = x >> 32, v = (uint64_t)(uint32_t)((uint32_t)x << 3) + 8;
    uint64_t a = (v ^ hi) * K;
    uint64_t b = (hi ^ (a >> 47) ^ a) * K;
    return (uint32_t)((b >> 47) ^ b) * 0xeb382d69u;
}
/* which slot of a pool's thread table each live thread maps to; flags two live threads on one slot */
static NSString *MSThreadSlots(uintptr_t storage, const char *name) {
    static intptr_t slide = -1;
    if (slide == -1) for (uint32_t k = 0; k < _dyld_image_count(); k++) { const struct mach_header *h = _dyld_get_image_header(k); if (h->filetype == MH_EXECUTE) { slide = _dyld_get_image_vmaddr_slide(k); break; } }
    uintptr_t obj = *(volatile uintptr_t *)(storage + slide) & ~(uintptr_t)7; if (!obj) return @"";
    volatile uint32_t *t = (volatile uint32_t *)obj; int used = 0; for (int i = 0; i < 64; i++) if (t[i]) used++;
    thread_act_array_t th; mach_msg_type_number_t n = 0; if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) return @"";
    int owner[64]; for (int i = 0; i < 64; i++) owner[i] = -1;
    NSMutableString *m = [NSMutableString stringWithFormat:@"%s: %d slots used;", name, used]; int clash = 0, mapped = 0;
    for (mach_msg_type_number_t k = 0; k < n; k++) {
        pthread_t pt = pthread_from_mach_thread_np(th[k]); if (!pt) continue;
        uint32_t h = MSEngineThreadHash((uint64_t)pt); int slot = -1;
        for (int i = 0; i < 64; i++) if (t[i] == h) { slot = i; break; }
        if (slot < 0) continue; mapped++;
        char nm[64] = ""; pthread_getname_np(pt, nm, sizeof nm);
        if (owner[slot] >= 0) { clash++; [m appendFormat:@" CLASH slot %d: threads %d and %u (%s, pthread %p)", slot, owner[slot], k, nm, pt]; }
        else owner[slot] = (int)k;
    }
    for (mach_msg_type_number_t k = 0; k < n; k++) mach_port_deallocate(mach_task_self(), th[k]);
    vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof *th);
    [m appendFormat:@" %d live threads mapped, %d clashes", mapped, clash];
    return m;
}
static NSString *MSThreadTables(BOOL *dup) {
    static intptr_t slide = -1;
    if (slide == -1) for (uint32_t k = 0; k < _dyld_image_count(); k++) { const struct mach_header *h = _dyld_get_image_header(k); if (h->filetype == MH_EXECUTE) { slide = _dyld_get_image_vmaddr_slide(k); break; } }
    uintptr_t seen[1024]; int ns = 0, maxUsed = 0, tables = 0; *dup = NO; NSMutableString *d = [NSMutableString string];
    for (size_t i = 0; i < sizeof g_poolStorages / sizeof *g_poolStorages; i++) {
        uintptr_t obj = *(volatile uintptr_t *)(g_poolStorages[i] + slide) & ~(uintptr_t)7;
        static int shown; if (shown < 12 && obj) { shown++; MSLogf(@"pool storage %#llx -> %#lx (raw %#lx)", g_poolStorages[i], (unsigned long)obj, (unsigned long)*(volatile uintptr_t *)(g_poolStorages[i] + slide)); }
        if (obj < ((uintptr_t)0x100000000)) continue;
        { vm_address_t ra = obj; vm_size_t rs; vm_region_basic_info_data_64_t vi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t on;
          if (vm_region_64(mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&vi, &cnt, &on) != KERN_SUCCESS || ra > obj || !(vi.protection & VM_PROT_READ)) continue; }
        BOOL dupObj = NO; for (int k = 0; k < ns; k++) if (seen[k] == obj) { dupObj = YES; break; }
        if (dupObj || ns >= 1024) continue; seen[ns++] = obj; tables++;
        volatile uint32_t *t = (volatile uint32_t *)obj; int used = 0;
        for (int a = 0; a < 64; a++) {
            uint32_t h = t[a]; if (!h) continue; used++;
            for (int b = a + 1; b < 64; b++) if (t[b] == h) { *dup = YES; if (d.length < 600) [d appendFormat:@" DUP pool %#lx slots %d,%d hash %#x;", (unsigned long)obj, a, b, h]; }
        }
        if (used > maxUsed) maxUsed = used;
    }
    thread_act_array_t th; mach_msg_type_number_t nth = 0;
    if (task_threads(mach_task_self(), &th, &nth) == KERN_SUCCESS) { for (mach_msg_type_number_t k = 0; k < nth; k++) mach_port_deallocate(mach_task_self(), th[k]); vm_deallocate(mach_task_self(), (vm_address_t)th, nth * sizeof *th); }
    return [NSString stringWithFormat:@"%d pool tables, most slots used %d/64, %u threads%@", tables, maxUsed, nth, d];
}
/* per pool: resident MB and the highest resident offset, to see whether a shrunk pool fills up */
static NSString *MSPoolUsage(void) {
    NSMutableString *m = [NSMutableString string]; static unsigned char *vec; static size_t vecLen;
    for (int i = 0; i < g_npools; i++) {
        MSPool q = g_pools[i]; size_t pages = q.real >> 14;
        if (vecLen < pages) { free(vec); vec = malloc(pages); vecLen = pages; }
        if (mincore((void *)q.base, q.real, (char *)vec) != 0) continue;
        size_t res = 0, hi = 0; for (size_t k = 0; k < pages; k++) if (vec[k] & 1) { res++; hi = k + 1; }
        [m appendFormat:@" [%zuG@%#lx: %zu MB, top %.2f/%.2f GB]", q.asked >> 30, (unsigned long)q.base, res >> 6, (hi << 14) / 1073741824.0, q.real / 1073741824.0];
    }
    return m;
}
static void MSStartReadProgress(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
    MSStartPerfLab();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double t0 = CACurrentMediaTime(), lastCPU = MSCPUSeconds(), lastT = t0, mbps = 0, cpuPct = 0;
        long long b5 = 0, frLast = 0; int quiet = 0; BOOL saved = NO, done = NO; double framesSince = 0, frT = t0, fps = 0;
        double expect = [NSUserDefaults.standardUserDefaults doubleForKey:@"MacShimLoadBytes"]; if (expect < 0.2e9) expect = 4e9;
        for (int tick = 0;; tick++) {
            usleep(500000);
            long long b = g_readBytes, c = g_readCalls, fr = g_frames; double now = CACurrentMediaTime(), idle = g_lastReadAt ? now - g_lastReadAt : now - t0;
            if (tick % 2 == 1) { double cpu = MSCPUSeconds(); cpuPct = (cpu - lastCPU) / (now - lastT) * 100; lastCPU = cpu; lastT = now; }
            double mem = MSFootprintMB();
            if (tick % 2 == 1) { fps = (fr - frLast) / (now - frT); frLast = fr; frT = now; }
            if (tick % 10 == 9) {
                mbps = (b - b5) / 5.0 / 1048576.0;
                if (b != b5 || quiet++ % 6 == 0)
                    MSLogf(@"progress: %.0f s, %.2f GB read in %lld reads, %.1f MB/s, last read %.0f s ago, CPU %.0f%%, memory %.0f MB, %lld frames, %.0f FPS, mouse gate %d, main queue lag %.1f s, thermal %s, yields %lld/s (%lld slept)%@",
                           now - t0, b / 1073741824.0, c, mbps, idle, cpuPct, mem, fr, fps, MSMouseGate(), g_mqAsked > g_mqBeat ? now - g_mqAsked : 0.0, MSThermal(), MSYieldRate(0), MSYieldRate(1),
                           NSProcessInfo.processInfo.lowPowerModeEnabled ? @", LOW POWER MODE" : @"");
                static int diag = -1; if (diag < 0) diag = [MSConfig()[@"Diagnostics"] boolValue];
                if (tick % 60 == 29 && fr > 300) { NSString *g = MSGPUSample(); if (g) MSLogf(@"%@", g); }
                if (tick % 60 == 59 && fr > 60) MSLogf(@"threads (CPU over the last 30 s): %@", MSThreadCPUReport());
                if (tick % 60 == 59 && fr > 60) { NSString *rs = MSRenderWidthReport(); if (rs) MSLogf(@"%@", rs); }
                if (tick % 60 == 59 && fr > 60) { NSString *sp = MSSpinReport(30); if (sp) MSLogf(@"%@", sp); }
                if (g_gcmCount) { static long long lm, lh; static long long lc; MSLogf(@"mouse: %lld motion events, %lld clicks, %lld pointer positions in the last 5 s (%s)", g_gcmMoves - lm, g_gcmClicks - lc, g_gcmHovers - lh, g_pointerLocked ? "gameplay" : "menu"); lm = g_gcmMoves; lh = g_gcmHovers; lc = g_gcmClicks; }
                if (tick % 120 == 99 && fr > 1500) { NSString *ws = MSSampleWorkers(); if (ws) MSLogf(@"worker samples: %@", ws); }
                if (diag && tick % 20 == 19) MSLogf(@"pools:%@", MSPoolUsage());
                if (diag && tick % 20 == 19) MSLogf(@"%@", MSQuarantineStats());
                if (diag && tick % 20 == 19) MSLogf(@"gpu: %lld noCopy buffers %.0f MB, %lld textures over buffers (%lld bad)", g_noCopyN, g_noCopyBytes / 1048576.0, g_bufTexN, g_bufTexBad);
                if (b != b5) quiet = 0;
                b5 = b;
            }
            if (fr > 60 && !framesSince) framesSince = now;
            if (framesSince && !saved && now - framesSince > 5) {      /* the game is drawing: remember how much this load read */
                saved = YES; [NSUserDefaults.standardUserDefaults setDouble:(double)b forKey:@"MacShimLoadBytes"];
                MSLogf(@"game is drawing frames after %.0f s, %.2f GB read", now - t0, b / 1073741824.0);
            }
            if (!g_stBg) continue;
            BOOL compact = framesSince && now - framesSince > 3;
            /* the game draws its own picture: switch to the overlay picked on the start screen right away (it used to wait
               for 20 s without reads, which never happens while the game streams the city - the strip never went away) */
            if (compact) done = YES;
            if (done) {                                                 /* from now on: the overlay picked on the start screen */
                static NSInteger ov = -1; if (ov < 0) ov = MSPref(@"MacShimOverlay", 1);
                if (ov == 0) {                                          /* Off */
                    if (!g_stBg.hidden) { [CATransaction begin]; [CATransaction setDisableActions:YES]; g_stBg.hidden = YES; [CATransaction commit]; [CATransaction flush];
                        MSMainAsync(^{ g_statusWin.hidden = YES; }); }            /* no window left over the game: nothing to composite */
                    continue;
                }
                int pf = g_paceFPS; NSString *fs = pf > 0 && g_paceT > 0 ? [NSString stringWithFormat:@"%.0f/%d FPS", fps, pf] : [NSString stringWithFormat:@"%.0f FPS", fps];
                NSString *f = ov == 2 ? [NSString stringWithFormat:@"%@   %.1f ms   CPU %.0f%%   RAM %.2f GB   %s", fs, fps > 0.5 ? 1000 / fps : 0, cpuPct, mem / 1024, MSThermal()]
                                      : [NSString stringWithFormat:@"%@  %.1f ms   RAM %.1f GB%@", fs, fps > 0.5 ? 1000 / fps : 0, mem / 1024,
                                         NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious ? @"   HOT" : @""];
                CGFloat pw = ov == 2 ? 400 : 210;
                [CATransaction begin]; [CATransaction setDisableActions:YES];
                CGRect R = g_stRoot.bounds;
                g_stBg.frame = CGRectMake(R.size.width / 2 - pw / 2, R.size.height - 24, pw, 20); g_stBg.cornerRadius = 10;
                g_stBg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45].CGColor;
                g_stTitle.hidden = g_stLog.hidden = g_stTrack.hidden = YES;
                g_stHead.frame = CGRectMake(10, 2, pw - 20, 16); g_stHead.alignmentMode = kCAAlignmentCenter; g_stHead.fontSize = 11; g_stHead.string = f;
                [CATransaction commit]; [CATransaction flush];
                continue;
            }
            int el = (int)(now - t0); double frac = MIN(b / expect, 0.97); if (saved) frac = 1;
            NSString *head = [NSString stringWithFormat:@"%d:%02d   %.2f GB read   %.0f MB/s   CPU %.0f%%   RAM %.1f GB   %@",
                              el / 60, el % 60, b / 1073741824.0, mbps, cpuPct, mem / 1024,
                              fr ? [NSString stringWithFormat:@"%.0f FPS", fps] : idle > 30 ? [NSString stringWithFormat:@"no reads for %.0f s", idle] : @""];
            NSMutableArray *lines = [NSMutableArray array];
            os_unfair_lock_lock(&g_tailLock);
            for (int i = MAX(0, g_logTailN - MS_TAIL); i < g_logTailN; i++) [lines addObject:g_logTail[i % MS_TAIL]];
            os_unfair_lock_unlock(&g_tailLock);
            const char *spin[] = { "◐", "◓", "◑", "◒" };
            BOOL busy = cpuPct > 15 || idle < 3;
            NSString *title = [NSString stringWithFormat:@"%s  Loading Cyberpunk 2077…  %.0f%%%@", busy ? spin[tick % 4] : "•", frac * 100,
                               [NSUserDefaults.standardUserDefaults objectForKey:@"MacShimLoadBytes"] ? @"" : @" (estimate)"];
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            CGRect R = g_stRoot.bounds; CGFloat pad = g_stPad;           /* no UIKit off the main thread: insets were read at start */
            CGFloat x = pad, w = R.size.width - 2 * pad; UIEdgeInsets in = UIEdgeInsetsMake(pad - 12, pad, pad - 12, pad);
            if (compact) {                                              /* the game shows its own screen: a thin strip at the bottom */
                g_stBg.frame = CGRectMake(0, R.size.height - 30, R.size.width, 30); g_stBg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5].CGColor;
                g_stTitle.hidden = g_stLog.hidden = YES;
                g_stHead.frame = CGRectMake(x, 2, w, 16); g_stTrack.frame = CGRectMake(x, 21, w, 4);
            } else {
                g_stBg.frame = R;
                CGFloat y = MAX(28, in.top + 12);
                g_stTitle.frame = CGRectMake(x, y, w, 26); g_stTrack.frame = CGRectMake(x, y + 36, w, 8);
                g_stHead.frame = CGRectMake(x, y + 54, w, 18);
                g_stLog.frame = CGRectMake(x, y + 84, w, R.size.height - y - 84 - MAX(16, in.bottom));
                g_stTitle.string = title; g_stLog.string = [lines componentsJoinedByString:@"\n"];
            }
            g_stFill.frame = CGRectMake(0, 0, g_stTrack.bounds.size.width * frac, g_stTrack.bounds.size.height);
            g_stHead.string = head;
            [CATransaction commit]; [CATransaction flush];
        }
    });
    });
}
ssize_t ms_read(int fd, void *buf, size_t n) __asm("_read");
ssize_t ms_read(int fd, void *buf, size_t n) {
    MSIOSyms();
    if (!MSTracked(fd)) {
        ssize_t r = MSReadRobust(fd, buf, n);
        if (r > 0 && fd > 2) { g_readBytes += r; g_readCalls++; g_lastReadAt = CACurrentMediaTime(); }
        return r;
    }
    static size_t chunk; static double rate;               /* bytes per piece, bytes per second (0 = no cap) */
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSDictionary *c = MSConfig();
        long k = [c[@"MaxParallelReads"] longValue]; if (k <= 0) k = 1;
        long kb = [c[@"ReadChunkKB"] longValue]; if (kb <= 0) kb = 1024;
        id mb = c[@"MaxReadMBps"]; double m = mb ? [mb doubleValue] : 120;
        chunk = (size_t)kb << 10; rate = m > 0 ? m * 1048576.0 : 0;
        g_readSlots = dispatch_semaphore_create(k);
        MSStartReadProgress();
        MSLogf(@"game file reads: at most %ld in flight, %ld KB pieces, %@", k, kb, m > 0 ? [NSString stringWithFormat:@"max %.0f MB/s", m] : @"no speed cap");
    });
    size_t done = 0; ssize_t r = 0;
    while (done < n) {
        size_t want = n - done; if (want > chunk) want = chunk;
        dispatch_semaphore_wait(g_readSlots, DISPATCH_TIME_FOREVER);
        double t0 = CACurrentMediaTime();
        r = MSReadRobust(fd, (char *)buf + done, want);
        if (rate > 0 && r > 0) { double wait = (double)r / rate - (CACurrentMediaTime() - t0); if (wait > 0) usleep((useconds_t)(wait * 1e6)); }
        dispatch_semaphore_signal(g_readSlots);
        if (r <= 0) break;
        done += (size_t)r;
        if ((size_t)r < want) break;                       /* end of file */
    }
    if (done) { g_readBytes += (long long)done; g_readCalls++; g_lastReadAt = CACurrentMediaTime(); return (ssize_t)done; }
    return r;
}

/* ---------------------------------------------------------------- log file + crash reports: Files > On My iPhone/iPad > Cyberpunk 2077 > macshim.log */
static int g_logfd = -1;
static void MSLogf(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void MSLogf(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt); NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    /* no fsync per line (it blocks the calling thread, often a game thread): write() survives an app crash, and the
       crash handler syncs itself. ConsoleLog = YES also sends every line to the system log. */
    static int console = -1; if (console < 0) console = [MSConfig()[@"ConsoleLog"] boolValue];
    if (console) NSLog(@"[MacShim] %@", m);
    if (![m hasPrefix:@"progress:"]) MSTailAdd(m);
    if (g_logfd >= 0) { NSString *l = [NSString stringWithFormat:@"%.3f %@\n", CACurrentMediaTime(), m]; const char *c = l.UTF8String; write(g_logfd, c, strlen(c)); }
}
static void MSSignal(int sig);
static void MSWriteHex(const char *label, uintptr_t v) {
    char b[64]; int n = 0; for (const char *c = label; *c; c++) b[n++] = *c;
    b[n++] = '0'; b[n++] = 'x'; char t[17]; int k = 0; do { int d = v & 15; t[k++] = d < 10 ? '0' + d : 'a' + d - 10; v >>= 4; } while (v);
    while (k) b[n++] = t[--k]; b[n++] = ' '; write(g_logfd, b, n);
}
static void MSSigInfo(int sig, siginfo_t *si, void *uc) {
    static _Atomic int once; if (once++) { sleep(2); }            /* first thread writes the details; others wait for it */
    if (g_logfd >= 0 && once == 1) {
        static const char h[] = "\n*** FAULT "; write(g_logfd, h, sizeof h - 1);
        MSWriteHex("sig=", (uintptr_t)sig); MSWriteHex("code=", (uintptr_t)si->si_code); MSWriteHex("addr=", (uintptr_t)si->si_addr);
        ucontext_t *u = uc; if (u && u->uc_mcontext) { MSWriteHex("pc=", (uintptr_t)u->uc_mcontext->__ss.__pc); MSWriteHex("lr=", (uintptr_t)u->uc_mcontext->__ss.__lr); MSWriteHex("sp=", (uintptr_t)u->uc_mcontext->__ss.__sp); }
        vm_address_t a = (vm_address_t)si->si_addr; vm_size_t sz = 0; vm_region_basic_info_data_64_t vi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t on;
        if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&vi, &cnt, &on) == KERN_SUCCESS) {
            MSWriteHex("region=", (uintptr_t)a); MSWriteHex("size=", (uintptr_t)sz); MSWriteHex("prot=", (uintptr_t)vi.protection);
        } else write(g_logfd, "region=none ", 12);
        Dl_info di; if (u && u->uc_mcontext && dladdr((void *)u->uc_mcontext->__ss.__pc, &di)) { MSWriteHex("image_base=", (uintptr_t)di.dli_fbase); }
        uintptr_t fa = (uintptr_t)si->si_addr;
        for (int i = 0; i < g_npools; i++) {
            MSPool q = g_pools[i];
            if (fa >= q.base && fa < q.base + q.real + q.guard) {
                write(g_logfd, fa >= q.base + q.real ? "IN-GUARD-OF-POOL " : "in-pool ", fa >= q.base + q.real ? 17 : 8);
                MSWriteHex("base=", q.base); MSWriteHex("real=", q.real); MSWriteHex("asked=", q.asked);
            }
        }
        if (u && u->uc_mcontext) for (int r = 0; r < 29; r++) { char l[8] = { 'x', '0' + r / 10, '0' + r % 10, '=', 0 }; MSWriteHex(l, u->uc_mcontext->__ss.__x[r]); }
        write(g_logfd, "\n", 1); fsync(g_logfd);
    }
    MSSignal(sig);
}
static void MSSignal(int sig) {
    static const char hdr[] = "\n*** CRASH signal ";
    if (g_logfd >= 0) {
        char num[16]; int n = 0, v = sig; char t[8]; do { t[n++] = '0' + v % 10; v /= 10; } while (v); for (int i = 0; i < n; i++) num[i] = t[n - 1 - i]; num[n] = '\n';
        write(g_logfd, hdr, sizeof hdr - 1); write(g_logfd, num, n + 1);
        void *frames[64]; int c = backtrace(frames, 64); backtrace_symbols_fd(frames, c, g_logfd); fsync(g_logfd);
    }
    signal(sig, SIG_DFL); raise(sig);
}
static void MSException(NSException *e) { MSLogf(@"*** UNCAUGHT EXCEPTION %@: %@\n%@", e.name, e.reason, e.callStackSymbols); }
static void MSOpenLog(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject, *p = [docs stringByAppendingPathComponent:@"macshim.log"];
    NSDictionary *at = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil];
    int flags = O_WRONLY | O_CREAT | O_APPEND; if ([at fileSize] > 512 * 1024) flags |= O_TRUNC;
    g_logfd = open(p.fileSystemRepresentation, flags, 0644);
    {   /* the game's own stdout/stderr (engine log lines, asserts) -> Documents/game_output.log */
        NSString *gp = [docs stringByAppendingPathComponent:@"game_output.log"];
        int gfd = open(gp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644), pp[2];
        if (gfd >= 0 && pipe(pp) == 0) {
            /* through a pipe, so the shim can react to engine messages (GOG Galaxy sign-in failures) */
            setvbuf(stdout, NULL, _IOLBF, 0); dup2(pp[1], 1); dup2(pp[1], 2); close(pp[1]);
            int rfd = pp[0];
            [NSThread detachNewThreadWithBlock:^{
                char buf[4096]; ssize_t n; char line[1024]; size_t ll = 0;
                while ((n = read(rfd, buf, sizeof buf)) > 0) {
                    write(gfd, buf, (size_t)n);
                    for (ssize_t i = 0; i < n; i++) {
                        if (buf[i] == '\n' || ll == sizeof line - 1) { line[ll] = 0; ll = 0; if (strstr(line, "Galaxy authentication failed")) g_galaxyFailures++; }
                        else line[ll++] = buf[i];
                    }
                }
            }];
        } else if (gfd >= 0) { setvbuf(stdout, NULL, _IOLBF, 0); dup2(gfd, 1); dup2(gfd, 2); close(gfd); }
    }
    NSSetUncaughtExceptionHandler(&MSException);
    int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP };
    for (size_t i = 0; i < sizeof sigs / sizeof *sigs; i++) {
        struct sigaction sa = { 0 }; sa.sa_sigaction = MSSigInfo; sa.sa_flags = SA_SIGINFO | SA_ONSTACK; sigemptyset(&sa.sa_mask); sigaction(sigs[i], &sa, NULL);
    }
    MSLogf(@"---- launch: %@ iOS %@ (%@), %.0f MB RAM", UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion, @"MacShim", NSProcessInfo.processInfo.physicalMemory / 1048576.0);
}


/* ---------------------------------------------------------------- macOS-only Metal / QuartzCore / Foundation selectors
 * The renderer uses metal-cpp, so it calls selectors that only exist on macOS directly. They are added at runtime to
 * the real iOS classes, and only when missing. Found by intersecting the game's strings with the declarations marked
 * API_UNAVAILABLE(ios) in the iPhoneOS SDK headers. */
static void MSAdd(Class c, SEL s, IMP imp, const char *types) {
    if (!c || class_respondsToSelector(c, s)) return;
    class_addMethod(c, s, imp, types); MSLogf(@"added macOS-only %s -[%@ %@]", types, NSStringFromClass(c), NSStringFromSelector(s));
}
static BOOL ms_no(id self, SEL _cmd) { return NO; }
static void ms_nop(id self, SEL _cmd) {}
static void ms_nop1(id self, SEL _cmd, id a) {}
static void ms_nopB(id self, SEL _cmd, BOOL a) {}
static void ms_nopRange(id self, SEL _cmd, NSRange r) {}
static void ms_nopU(id self, SEL _cmd, NSUInteger u) {}
static void ms_nopSync3(id self, SEL _cmd, id t, NSUInteger slice, NSUInteger level) {}
static id ms_nil(id self, SEL _cmd) { return nil; }
static id ms_userName(id self, SEL _cmd) { return @"mobile"; }
static void ms_textureBarrier(id self, SEL _cmd) {     /* macOS textureBarrier -> iOS memory barrier between fragment passes */
    ((void (*)(id, SEL, NSUInteger, NSUInteger, NSUInteger))objc_msgSend)(self, @selector(memoryBarrierWithScope:afterStages:beforeStages:),
        MTLBarrierScopeTextures, MTLRenderStageFragment, MTLRenderStageFragment);
}
/* macOS-only MTLStorageModeManaged (resource option 1<<4) does not exist on iOS: rewrite it to Shared and count it */
static IMP g_oBufLen, g_oBufBytes, g_oTex, g_oHeapTex, g_oHeapBuf;
static _Atomic int g_managedSeen;
static NSUInteger MSFixOpts(NSUInteger o, const char *what) {
    if ((o & MTLResourceStorageModeMask) == (1u << MTLResourceStorageModeShift)) {
        if (g_managedSeen++ < 5) MSLogf(@"Metal: %s asked for Managed storage -> Shared", what);
        o = (o & ~MTLResourceStorageModeMask) | MTLResourceStorageModeShared;
    }
    return o;
}
static void MSFixDesc(id d, const char *what) {
    if ([d respondsToSelector:@selector(storageMode)] && [(MTLTextureDescriptor *)d storageMode] == 1) {
        if (g_managedSeen++ < 5) MSLogf(@"Metal: %s asked for Managed storage -> Shared", what);
        [(MTLTextureDescriptor *)d setStorageMode:MTLStorageModeShared];
    }
}
static id ms_bufLen(id self, SEL c, NSUInteger len, NSUInteger o) { return ((id (*)(id, SEL, NSUInteger, NSUInteger))g_oBufLen)(self, c, len, MSFixOpts(o, "buffer")); }
static id ms_bufBytes(id self, SEL c, const void *p, NSUInteger len, NSUInteger o) { return ((id (*)(id, SEL, const void *, NSUInteger, NSUInteger))g_oBufBytes)(self, c, p, len, MSFixOpts(o, "buffer(bytes)")); }
static id ms_tex(id self, SEL c, MTLTextureDescriptor *d) { MSFixDesc(d, "texture"); return ((id (*)(id, SEL, id))g_oTex)(self, c, d); }
static id ms_heapBuf(id self, SEL c, NSUInteger len, NSUInteger o) { return ((id (*)(id, SEL, NSUInteger, NSUInteger))g_oHeapBuf)(self, c, len, MSFixOpts(o, "heap buffer")); }
static id ms_heapTex(id self, SEL c, MTLTextureDescriptor *d) { MSFixDesc(d, "heap texture"); return ((id (*)(id, SEL, id))g_oHeapTex)(self, c, d); }
/* GPU memory audit: buffers wrapped around the game's own memory, and textures laid over buffers (a size mistake there
 * lets the GPU write past the buffer into neighbouring engine memory) */
static IMP g_oNoCopy, g_oBufTex;
static id ms_noCopy(id self, SEL c, void *p, NSUInteger len, NSUInteger o, id dealloc) {
    long long n = g_noCopyN++; g_noCopyBytes += (long long)len;
    if (n < 12 || (len & 0x3fff) || ((uintptr_t)p & 0x3fff)) MSLogf(@"Metal: noCopy buffer #%lld %p +%#lx opts %#lx%s", n, p, (unsigned long)len, (unsigned long)o,
        ((len & 0x3fff) || ((uintptr_t)p & 0x3fff)) ? " NOT PAGE ALIGNED" : "");
    return ((id (*)(id, SEL, void *, NSUInteger, NSUInteger, id))g_oNoCopy)(self, c, p, len, o, dealloc);
}
static id ms_bufTex(id self, SEL c, MTLTextureDescriptor *d, NSUInteger off, NSUInteger bpr) {
    long long n = g_bufTexN++;
    id<MTLBuffer> b = self; NSUInteger need = off + bpr * MAX(d.height, 1) * MAX(d.depth, 1) * MAX(d.arrayLength, 1);
    id<MTLDevice> dev = b.device; NSUInteger align = [dev minimumLinearTextureAlignmentForPixelFormat:d.pixelFormat];
    BOOL bad = need > b.length || (align && (off % align)) ;
    if (bad) g_bufTexBad++;
    if (n < 8 || (bad && g_bufTexBad < 20)) MSLogf(@"Metal: texture over buffer #%lld %lux%lux%lu fmt %lu off %lu bpr %lu need %lu buf %lu align %lu%s", n,
        (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.depth, (unsigned long)d.pixelFormat, (unsigned long)off, (unsigned long)bpr,
        (unsigned long)need, (unsigned long)b.length, (unsigned long)align, bad ? " <-- OVERFLOWS / MISALIGNED" : "");
    return ((id (*)(id, SEL, id, NSUInteger, NSUInteger))g_oBufTex)(self, c, d, off, bpr);
}
static void MSAddMacAPIs(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); if (!dev) { MSLogf(@"no Metal device!"); return; }
    Class D = object_getClass(dev);
    { Method m;
      if ((m = class_getInstanceMethod(D, @selector(newBufferWithBytesNoCopy:length:options:deallocator:)))) g_oNoCopy = method_setImplementation(m, (IMP)ms_noCopy);
      id<MTLBuffer> tb = [dev newBufferWithLength:16384 options:MTLResourceStorageModeShared];
      if (tb && (m = class_getInstanceMethod(object_getClass(tb), @selector(newTextureWithDescriptor:offset:bytesPerRow:)))) g_oBufTex = method_setImplementation(m, (IMP)ms_bufTex);
    }
    { Method m;
      if ((m = class_getInstanceMethod(D, @selector(newBufferWithLength:options:)))) g_oBufLen = method_setImplementation(m, (IMP)ms_bufLen);
      if ((m = class_getInstanceMethod(D, @selector(newBufferWithBytes:length:options:)))) g_oBufBytes = method_setImplementation(m, (IMP)ms_bufBytes);
      if ((m = class_getInstanceMethod(D, @selector(newTextureWithDescriptor:)))) g_oTex = method_setImplementation(m, (IMP)ms_tex);
      MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.size = 1 << 16; hd.storageMode = MTLStorageModePrivate;
      id<MTLHeap> h = [dev newHeapWithDescriptor:hd];
      if (h) { Class H = object_getClass(h);
        if ((m = class_getInstanceMethod(H, @selector(newBufferWithLength:options:)))) g_oHeapBuf = method_setImplementation(m, (IMP)ms_heapBuf);
        if ((m = class_getInstanceMethod(H, @selector(newTextureWithDescriptor:)))) g_oHeapTex = method_setImplementation(m, (IMP)ms_heapTex); }
    }
    MSAdd(D, @selector(isDepth24Stencil8PixelFormatSupported), (IMP)ms_no, "B@:");
    MSAdd(D, NSSelectorFromString(@"depth24Stencil8PixelFormatSupported"), (IMP)ms_no, "B@:");
    MSAdd(D, NSSelectorFromString(@"isHeadless"), (IMP)ms_no, "B@:");  MSAdd(D, NSSelectorFromString(@"headless"), (IMP)ms_no, "B@:");
    MSAdd(D, NSSelectorFromString(@"isLowPower"), (IMP)ms_no, "B@:");  MSAdd(D, NSSelectorFromString(@"isRemovable"), (IMP)ms_no, "B@:");
    id<MTLBuffer> buf = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    MSAdd(object_getClass(buf), NSSelectorFromString(@"didModifyRange:"), (IMP)ms_nopRange, "v@:{_NSRange=QQ}");
    id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    MSAdd(object_getClass(bl), NSSelectorFromString(@"synchronizeResource:"), (IMP)ms_nop1, "v@:@");
    MSAdd(object_getClass(bl), NSSelectorFromString(@"synchronizeTexture:slice:level:"), (IMP)ms_nopSync3, "v@:@QQ");
    [bl endEncoding];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    if (re) { MSAdd(object_getClass(re), NSSelectorFromString(@"textureBarrier"), (IMP)ms_textureBarrier, "v@:"); [re endEncoding]; }
    /* parallel render encoders hand out sub-encoders of another class */
    id<MTLParallelRenderCommandEncoder> pe = [cb parallelRenderCommandEncoderWithDescriptor:rp];
    if (pe) { id<MTLRenderCommandEncoder> se = [pe renderCommandEncoder]; if (se) { MSAdd(object_getClass(se), NSSelectorFromString(@"textureBarrier"), (IMP)ms_textureBarrier, "v@:"); [se endEncoding]; } [pe endEncoding]; }
    [cb commit];
    Class L = CAMetalLayer.class, CL = CALayer.class;
    MSAdd(L, NSSelectorFromString(@"setDisplaySyncEnabled:"), (IMP)ms_nopB, "v@:B"); MSAdd(L, NSSelectorFromString(@"displaySyncEnabled"), (IMP)ms_no, "B@:");
    MSAdd(L, NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:"), (IMP)ms_nopB, "v@:B"); MSAdd(L, NSSelectorFromString(@"wantsExtendedDynamicRangeContent"), (IMP)ms_no, "B@:");
    MSAdd(CL, NSSelectorFromString(@"setAutoresizingMask:"), (IMP)ms_nopU, "v@:I"); MSAdd(CL, NSSelectorFromString(@"filter"), (IMP)ms_nil, "@@:");
    Class P = NSProcessInfo.class;
    for (NSString *s in @[ @"disableSuddenTermination", @"enableSuddenTermination" ]) MSAdd(P, NSSelectorFromString(s), (IMP)ms_nop, "v@:");
    for (NSString *s in @[ @"disableAutomaticTermination:", @"enableAutomaticTermination:" ]) MSAdd(P, NSSelectorFromString(s), (IMP)ms_nop1, "v@:@");
    MSAdd(P, NSSelectorFromString(@"setAutomaticTerminationSupportEnabled:"), (IMP)ms_nopB, "v@:B"); MSAdd(P, NSSelectorFromString(@"automaticTerminationSupportEnabled"), (IMP)ms_no, "B@:");
    MSAdd(P, NSSelectorFromString(@"userName"), (IMP)ms_userName, "@@:"); MSAdd(P, NSSelectorFromString(@"fullUserName"), (IMP)ms_userName, "@@:");
}

/* ---------------------------------------------------------------- engine free quarantine
 * Some engine code writes into blocks after freeing them (seen as an empty DynArray header {allocator vtable, 0} in a
 * UI worklist buffer, float records in a freed 24-byte free list, allocations returned inside __DATA_CONST). On the
 * phone the freed block is reused quickly, so the late write corrupts its new owner a few seconds after the main menu
 * loads. tools/ios_retarget.py (patch_free_hook) routes the core Free(allocator, Block&) through a pointer at the end
 * of __DATA; small and medium blocks wait here (FIFO, QuarantineMB, default 256) before the real free runs, so a late
 * write lands in memory nobody owns yet. Off unless Quarantine = YES; QuarantineCheck = YES fills each held block
 * with a pattern and logs any write into it (block size, value, and who freed it) when it is released. */
#define MS_FREE_ENTRY 0x100012cacULL
typedef struct { void *alloc; uintptr_t ptr; uint32_t size, filled; uint64_t t; uintptr_t ra[3]; } MSQEntry;
static MSQEntry *g_q; static size_t g_qCap, g_qHead, g_qCount, g_qBytes, g_qMaxBytes, g_qMaxBlock;
static os_unfair_lock g_qLock = OS_UNFAIR_LOCK_INIT;
static int g_qMode;                                   /* 0 pass-through, 1 quarantine, 2 quarantine + pattern check */
static int (*g_medOwns)(void *medium, uintptr_t p);
static _Atomic long long g_qDeferred, g_qDirty, g_qPassed;
static uint64_t g_qOldestAge;                         /* mach ticks the last released block waited */
__attribute__((used, visibility("hidden"))) uintptr_t g_freeCont;   /* engine Free + 12 */
void ms_free_orig(void *alloc, uint64_t *blk);        /* the replaced prologue, then back into the engine */
__asm__(".text\n.p2align 2\n.private_extern _ms_free_orig\n.globl _ms_free_orig\n_ms_free_orig:\n"
        "  stp x22, x21, [sp, #-0x30]!\n  stp x20, x19, [sp, #0x10]\n  stp x29, x30, [sp, #0x20]\n"
        "  adrp x16, _g_freeCont@PAGE\n  ldr x16, [x16, _g_freeCont@PAGEOFF]\n  br x16\n");
#define MS_QPATTERN 0xF1EEDBADF1EEDBADULL
static double MSTicksToSec(uint64_t t) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)t * tb.numer / tb.denom / 1e9; }
static void MSQRelease(MSQEntry *e) {
    if (e->filled) {
        const uint64_t *w = (const uint64_t *)e->ptr; uint32_t n = e->filled / 8, bad = 0, first = 0; uint64_t val = 0;
        for (uint32_t i = 0; i < n; i++) if (w[i] != MS_QPATTERN) { if (!bad++) { first = i * 8; val = w[i]; } }
        if (bad) {
            long long k = ++g_qDirty;
            if (k <= 300) {
                Dl_info di; NSString *sym = @"";
                if (dladdr((void *)val, &di) && di.dli_fbase) sym = [NSString stringWithFormat:@" (%@)", MSCallerStr((void *)val)];
                MSLogf(@"UAF write into freed block %#lx size %u: %u words changed, first at +%#x = %#llx%@, %.2f s after free; freed from %@ < %@ < %@",
                       (unsigned long)e->ptr, e->size, bad, first, val, sym, MSTicksToSec(mach_absolute_time() - e->t),
                       MSCallerStr((void *)e->ra[0]), MSCallerStr((void *)e->ra[1]), MSCallerStr((void *)e->ra[2]));
            }
        }
    }
    uint64_t blk[2] = { e->ptr, 0 }; ms_free_orig(e->alloc, blk);
}
static void ms_engineFree(void *alloc, uint64_t *blk) {
    uintptr_t p = blk[0];
    if (!p || !g_qMode) { ms_free_orig(alloc, blk); return; }
    const uintptr_t *sr = (const uintptr_t *)((char *)alloc + 0xc900); uint32_t size;
    if (p - sr[0] < sr[1] - sr[0]) size = *(const uint32_t *)((p & ~(uintptr_t)0xffff) + 0x20);          /* small: span header */
    else if (g_medOwns((char *)alloc + 0xcd80, p)) size = (*(const uint32_t *)(p - 8) - 0x10) & ~3u;   /* medium: block header */
    else { g_qPassed++; ms_free_orig(alloc, blk); return; }                                            /* large: free now */
    if (size > g_qMaxBlock) { g_qPassed++; ms_free_orig(alloc, blk); return; }
    blk[1] = size;                                     /* what the real free reports back (allocation stats) */
    MSQEntry e = { alloc, p, size, 0, mach_absolute_time(), { (uintptr_t)__builtin_return_address(0), 0, 0 } };
    if (g_qMode == 2) {
        uintptr_t *fp = __builtin_frame_address(0);
        for (int i = 1; i < 3; i++) {                  /* frame pointers: our caller's caller, ... */
            uintptr_t *nx = (uintptr_t *)fp[0]; if (nx <= fp || (uintptr_t)nx - (uintptr_t)fp > ((uintptr_t)64 << 20) || ((uintptr_t)nx & 7)) break;
            fp = nx; e.ra[i] = fp[1];
        }
        uint32_t fill = size < 65536 ? size & ~7u : 65536; uint64_t *w = (uint64_t *)p;
        for (uint32_t i = 0; i < fill / 8; i++) w[i] = MS_QPATTERN;
        e.filled = fill;
    }
    MSQEntry out[8]; int nout = 0; BOOL queued = NO;
    os_unfair_lock_lock(&g_qLock);
    while (g_qCount && (g_qCount == g_qCap || g_qBytes + size > g_qMaxBytes) && nout < 8) {
        MSQEntry *h = &g_q[g_qHead]; out[nout++] = *h; g_qBytes -= h->size; g_qHead = (g_qHead + 1) % g_qCap; g_qCount--;
        g_qOldestAge = e.t - h->t;
    }
    if (g_qCount < g_qCap) { g_q[(g_qHead + g_qCount) % g_qCap] = e; g_qCount++; g_qBytes += size; queued = YES; }
    os_unfair_lock_unlock(&g_qLock);
    if (queued) g_qDeferred++;
    for (int i = 0; i < nout; i++) MSQRelease(&out[i]);
    if (!queued) MSQRelease(&e);
}
static NSString *MSQuarantineStats(void) {
    if (!g_qMode) return @"quarantine off";
    return [NSString stringWithFormat:@"quarantine: %.0f MB in %zu blocks, oldest held %.1f s, %lld deferred, %lld large passed, %lld UAF writes seen",
            g_qBytes / 1048576.0, g_qCount, MSTicksToSec(g_qOldestAge), (long long)g_qDeferred, (long long)g_qPassed, (long long)g_qDirty];
}
static void MSInstallFreeHook(void) {
    const struct mach_header_64 *mh = NULL; intptr_t slide = 0;
    for (uint32_t k = 0; k < _dyld_image_count(); k++) {
        const struct mach_header *h = _dyld_get_image_header(k);
        if (h->filetype == MH_EXECUTE) { mh = (const struct mach_header_64 *)h; slide = _dyld_get_image_vmaddr_slide(k); break; }
    }
    if (!mh) return;
    uintptr_t slot = 0; const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize))
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, "__DATA"))
            slot = ((const struct segment_command_64 *)lc)->vmaddr + ((const struct segment_command_64 *)lc)->vmsize - 0x100 + slide;
    const uint32_t *entry = (const uint32_t *)(MS_FREE_ENTRY + slide);
    if (!slot || (entry[0] & 0x9f00001f) != 0x90000010 || entry[2] != 0xd61f0200) { MSLogf(@"free hook: not in the game binary (rebuild with the current tools/ios_retarget.py)"); return; }
    g_freeCont = MS_FREE_ENTRY + 12 + slide;
    g_medOwns = (int (*)(void *, uintptr_t))(0x10000f434ULL + slide);
    g_qMode = [MSConfig()[@"QuarantineCheck"] boolValue] ? 2 : [MSConfig()[@"Quarantine"] boolValue] ? 1 : 0;   /* opt-in: it didn't explain the menu crash */
    if (g_qMode) {
        g_qMaxBytes = (size_t)(MSCfgD(@"QuarantineMB", 256) * 1048576.0);
        g_qMaxBlock = (size_t)(MSCfgD(@"QuarantineMaxBlockKB", 1024) * 1024.0);
        g_qCap = (size_t)MSCfgD(@"QuarantineEntries", 2000000);
        g_q = kmmap(NULL, g_qCap * sizeof *g_q, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (g_q == MAP_FAILED) { g_q = NULL; g_qMode = 0; }
    }
    *(volatile uintptr_t *)slot = (uintptr_t)ms_engineFree;
    MSLogf(@"free hook installed (slot %#lx): %@", (unsigned long)(slot - slide),
           g_qMode ? [NSString stringWithFormat:@"quarantine %.0f MB / %zu blocks, blocks up to %zu KB%@", g_qMaxBytes / 1048576.0, g_qCap, g_qMaxBlock >> 10, g_qMode == 2 ? @", pattern check ON" : @""] : @"pass-through");
}

/* ---------------------------------------------------------------- output (drawable) resolution
 * GameWindowDelegate setLayerResolution:heigh:hdrMode: is how the engine sizes the CAMetalLayer it presents to; the
 * Resolution option only sets what it renders before upscaling. Logged with the caller to see where the engine's
 * output size comes from. */
static IMP g_origSetLayerRes, g_origCreateLayer;
static void ms_setLayerResolution(id self, SEL _cmd, unsigned w, unsigned h, unsigned char hdr) {
    static int n; if (n++ < 10) MSLogf(@"game sets output (drawable) resolution %ux%u (hdr %d) from %@; screen scale %.2f", w, h, hdr, MSBacktraceStr(4),
                                       [NSScreen.mainScreen backingScaleFactor]);
    ((void (*)(id, SEL, unsigned, unsigned, unsigned char))g_origSetLayerRes)(self, _cmd, w, h, hdr);
    if (g_settingsPoke) g_settingsPoke();                          /* graphics settings applied in the game's menu */
}
static void ms_createMetalLayer(id self, SEL _cmd, unsigned w, unsigned h) {
    MSLogf(@"game creates its Metal layer %ux%u from %@", w, h, MSBacktraceStr(4));
    ((void (*)(id, SEL, unsigned, unsigned))g_origCreateLayer)(self, _cmd, w, h);
}
static void MSHookGameWindow(void) {
    Class c = objc_getClass("GameWindowDelegate"); if (!c) return;
    Method m = class_getInstanceMethod(c, sel_registerName("setLayerResolution:heigh:hdrMode:"));
    if (m) g_origSetLayerRes = method_setImplementation(m, (IMP)ms_setLayerResolution);
    Method k = class_getInstanceMethod(c, sel_registerName("createMetalLayerWithWidth:height:"));
    if (k) g_origCreateLayer = method_setImplementation(k, (IMP)ms_createMetalLayer);
    MSLogf(@"output resolution hooks: %d %d (method types %s / %s)", m != NULL, k != NULL, m ? method_getTypeEncoding(m) : "-", k ? method_getTypeEncoding(k) : "-");
}

static IMP g_origEngineStart;
static BOOL ms_engineStart(id self, SEL _cmd, NSError **err) {
    @synchronized (g_audioEngines) { [g_audioEngines addObject:self]; }
    return ((BOOL (*)(id, SEL, NSError **))g_origEngineStart)(self, _cmd, err);
}
static void MSInstallBackgroundFreeze(void) {
    g_audioEngines = [NSHashTable weakObjectsHashTable];
    Class c = NSClassFromString(@"AVAudioEngine");
    Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(@"startAndReturnError:")) : NULL;
    if (m) g_origEngineStart = method_setImplementation(m, (IMP)ms_engineStart);
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        if ([MSConfig()[@"BackgroundFreeze"] isEqual:@NO]) return;
        g_inBackground = YES;
        NSArray *es; @synchronized (g_audioEngines) { es = g_audioEngines.allObjects; }
        for (id e in es) ((void (*)(id, SEL))objc_msgSend)(e, NSSelectorFromString(@"pause"));
        MSLogf(@"background: %lu audio engine(s) paused", (unsigned long)es.count);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        if (!g_inBackground) return;
        NSArray *es; @synchronized (g_audioEngines) { es = g_audioEngines.allObjects; }
        for (id e in es) { NSError *er = nil;
            if (!((BOOL (*)(id, SEL, NSError **))objc_msgSend)(e, NSSelectorFromString(@"startAndReturnError:"), &er)) MSLogf(@"foreground: audio engine restart failed: %@", er); }
        g_inBackground = NO;
    }];
}

__attribute__((constructor)) static void MSInit(void) {
    @autoreleasepool {
        MSOpenLog();
        MSInstallFreeHook();
        MSInstallBackgroundFreeze();
        if (getenv("MACSHIM_PROBE_VA")) MSProbeVA();
        NSFileManager *fm = NSFileManager.defaultManager; NSString *internal = MSInternalRoot();
        [fm createDirectoryAtPath:internal withIntermediateDirectories:YES attributes:nil error:nil];     /* shows up in Files > On My iPad/iPhone */
        NSString *root = MSDataRoot();
        if (root) {
            NSString *exe = [root stringByAppendingPathComponent:@"Cyberpunk2077.app/Contents/MacOS"], *ph = [exe stringByAppendingPathComponent:@"Cyberpunk2077"];
            if (![fm fileExistsAtPath:ph]) {            /* realpath() on the pretend executable must succeed */
                [fm createDirectoryAtPath:exe withIntermediateDirectories:YES attributes:nil error:nil];
                [@"" writeToFile:ph atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            if (!g_external) for (NSString *d in @[ @"r6/cache", @"r6/config" ]) [fm createDirectoryAtPath:[root stringByAppendingPathComponent:d] withIntermediateDirectories:YES attributes:nil error:nil];
            chdir(root.fileSystemRepresentation);
            MSLogf(@"game folder (%@): %@", g_external ? @"external" : @"internal", root);
        } else MSLogf(@"no game folder yet - setup screen will appear when the game starts");
        MSAddMacAPIs();
        MSHookGameWindow();
        [NSApplication sharedApplication];
        MSMainAsync(^{
            if (GCKeyboard.coalescedKeyboard) MSAttachKeyboard(GCKeyboard.coalescedKeyboard);
            [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { MSAttachKeyboard(n.object); }];
            for (GCMouse *m in GCMouse.mice) MSAttachMouse(m);
            [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { MSAttachMouse(n.object); }];
            [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidDisconnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
                if (g_gcmCount > 0) g_gcmCount--; MSLogf(@"mouse disconnected");
                MSMainAsync(^{                               /* never leave a button held */
                    MSHostView *h = g_hostView; if (!h) return;
                    if (g_gcmRight) { g_gcmRight = NO; [h msButton:NO right:YES at:MSGCMouseAt(h)]; }
                    if (g_leftBy == 2) MSLeftPress(2, NO);
                });
            }];
        });
    }
}

/* ---------------------------------------------------------------- test aid: BlockNetwork = YES makes internet
 * connections and DNS lookups fail (local/unix sockets untouched), to see whether the online menu code is involved. */
#include <netdb.h>
#include <sys/socket.h>
static BOOL MSBlockNet(void) { static int v = -1; if (v < 0) v = [MSConfig()[@"BlockNetwork"] boolValue]; return v; }
static int ms_connect(int s, const struct sockaddr *a, socklen_t l) {
    if (MSBlockNet() && a && (a->sa_family == AF_INET || a->sa_family == AF_INET6)) {
        static _Atomic int n; if (n++ < 3) MSLogf(@"BlockNetwork: refused a connection");
        errno = ENETUNREACH; return -1;
    }
    return connect(s, a, l);
}
static int ms_getaddrinfo(const char *h, const char *sv, const struct addrinfo *hi, struct addrinfo **res) {
    if (MSBlockNet()) { static _Atomic int n; if (n++ < 5) MSLogf(@"BlockNetwork: refused lookup of %s", h ?: "?"); return EAI_FAIL; }
    return getaddrinfo(h, sv, hi, res);
}
__attribute__((used, section("__DATA,__interpose"))) static struct { const void *replacement, *original; } g_interpose[] = {
    { (const void *)ms_connect, (const void *)connect }, { (const void *)ms_getaddrinfo, (const void *)getaddrinfo },
};

/* ---------------------------------------------------------------- audio graph (rerouted from AudioToolbox)
 * Logs what iOS asks of the game's render callback (frames per call, buffer layout) - iOS IO buffers differ from
 * macOS - and NoAudio = YES keeps the graph stopped. */
#include <AudioToolbox/AudioToolbox.h>
static AURenderCallbackStruct g_gameRender;
static _Atomic uint32_t g_maxFrames; static _Atomic int g_renderCalls;
static OSStatus ms_render(void *ref, AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *io) {
    if (frames > g_maxFrames) {
        g_maxFrames = frames;
        MSLogf(@"audio render: %u frames, %u buffers, buffer0 %u bytes x %u ch (call %d)", frames, io ? io->mNumberBuffers : 0,
               io && io->mNumberBuffers ? io->mBuffers[0].mDataByteSize : 0, io && io->mNumberBuffers ? io->mBuffers[0].mNumberChannels : 0, g_renderCalls);
    }
    g_renderCalls++;
    return g_gameRender.inputProc(g_gameRender.inputProcRefCon, fl, ts, bus, frames, io);
}
static void *MSAudioToolbox(const char *sym) {
    static void *h; if (!h) h = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
    return h ? dlsym(h, sym) : NULL;
}
OSStatus ms_AUGraphSetNodeInputCallback(AUGraph g, AUNode n, UInt32 in, const AURenderCallbackStruct *cb) __asm("_AUGraphSetNodeInputCallback");
OSStatus ms_AUGraphSetNodeInputCallback(AUGraph g, AUNode n, UInt32 in, const AURenderCallbackStruct *cb) {
    static OSStatus (*real)(AUGraph, AUNode, UInt32, const AURenderCallbackStruct *); if (!real) real = MSAudioToolbox("AUGraphSetNodeInputCallback");
    MSLogf(@"audio: game render callback on node %d input %u", (int)n, in);
    if (!cb || !cb->inputProc) return real(g, n, in, cb);
    g_gameRender = *cb; AURenderCallbackStruct w = { ms_render, NULL };
    return real(g, n, in, &w);
}
OSStatus ms_AUGraphStart(AUGraph g) __asm("_AUGraphStart");
OSStatus ms_AUGraphStart(AUGraph g) {
    static OSStatus (*real)(AUGraph); if (!real) real = MSAudioToolbox("AUGraphStart");
    if ([MSConfig()[@"NoAudio"] boolValue]) { MSLogf(@"audio: AUGraphStart skipped (NoAudio)"); return noErr; }
    OSStatus r = real(g); MSLogf(@"audio: AUGraphStart -> %d", (int)r); return r;
}

/* ---------------------------------------------------------------- CPU count (CPUCount setting) for sysconf / sysctl /
 * NSProcessInfo, matching sysctlbyname above */
#include <sys/sysctl.h>
static int MSCPUCount(void) { static int v = -1; if (v < 0) v = [MSConfig()[@"CPUCount"] intValue]; return v; }
long ms_sysconf(int name) __asm("_sysconf");
long ms_sysconf(int name) {
    static long (*real)(int); if (!real) real = (long (*)(int))dlsym(RTLD_NEXT, "sysconf");
    if (MSCPUCount() > 0 && (name == _SC_NPROCESSORS_ONLN || name == _SC_NPROCESSORS_CONF)) return MSCPUCount();
    return real(name);
}
int ms_sysctl(int *mib, u_int n, void *oldp, size_t *oldlenp, void *newp, size_t newlen) __asm("_sysctl");
int ms_sysctl(int *mib, u_int n, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    static int (*real)(int *, u_int, void *, size_t *, void *, size_t); if (!real) real = dlsym(RTLD_NEXT, "sysctl");
    if (MSCPUCount() > 0 && n == 2 && mib[0] == CTL_HW && (mib[1] == HW_NCPU || mib[1] == HW_AVAILCPU) && !newp && oldp && oldlenp && *oldlenp >= sizeof(int)) {
        int v = MSCPUCount(); memcpy(oldp, &v, sizeof v); *oldlenp = sizeof v; return 0;
    }
    return real(mib, n, oldp, oldlenp, newp, newlen);
}
static NSUInteger ms_procCount(id self, SEL _cmd) { return (NSUInteger)MSCPUCount(); }
__attribute__((constructor)) static void MSInstallCPUCount(void) {
    if (MSCPUCount() <= 0) return;
    Class P = NSProcessInfo.class;
    method_setImplementation(class_getInstanceMethod(P, @selector(processorCount)), (IMP)ms_procCount);
    method_setImplementation(class_getInstanceMethod(P, @selector(activeProcessorCount)), (IMP)ms_procCount);
}

/* ---------------------------------------------------------------- online services (GOG Galaxy)
 * When the main menu opens, libGameServicesGOG signs in to GOG Galaxy. There is no Galaxy client on iOS, so ~15 s later
 * Galaxy reports "authentication failed", and the game's handling of that corrupts memory and crashes (traced
 * 2026-10-12: every crash came right after that message; the engine then asserted on a trashed queue in its
 * allocator). Galaxy only delivers results inside galaxy::api::ProcessData(), so the shim makes that a no-op: the
 * sign-in just stays pending and the game plays offline. GalaxyProcessData = YES restores it. GameServices = NO
 * refuses the services library entirely (the game then crashes on a null service - kept only as a test switch). */
void *ms_dlopen(const char *path, int mode) __asm("_dlopen");
void *ms_dlopen(const char *path, int mode) {
    static void *(*real)(const char *, int); if (!real) real = (void *(*)(const char *, int))dlsym(RTLD_NEXT, "dlopen");
    if (path && strstr(path, "libGameServices") && [MSConfig()[@"GameServices"] isEqual:@NO]) {
        MSLogf(@"dlopen %s -> refused (GameServices = NO)", path); return NULL;
    }
    return real(path, mode);
}
static void ms_galaxyProcessData(void) {
    static void (*real)(void); static int allow = -1;
    if (allow < 0) {
        allow = [MSConfig()[@"GalaxyProcessData"] boolValue];
        void *h = dlopen("@rpath/libGalaxy.dylib", RTLD_LAZY | RTLD_NOLOAD); if (!h) h = dlopen("@rpath/libGalaxy.dylib", RTLD_LAZY);
        real = h ? (void (*)(void))dlsym(h, "_ZN6galaxy3api11ProcessDataEv") : NULL;
        MSLogf(@"GOG Galaxy: ProcessData wrapper active (real %p)", real);
    }
    /* the first sign-in (startup screen) may fail normally - the "press space" screen waits for it; after that
       nothing more is delivered, so the main menu's sign-in never reports the failure that crashes the game */
    static BOOL said;
    BOOL hold = [MSConfig()[@"GalaxyHoldResults"] boolValue];        /* old approach, kept as a test switch */
    if (real && (allow || !hold || g_galaxyFailures == 0)) real();
    else if (!said) { said = YES; MSLogf(@"GOG Galaxy: holding back further results"); }
}

/* libGameServicesGOG doesn't link the shim, so its import of galaxy::api::ProcessData is redirected at load time:
   its GOT slot holding libGalaxy's ProcessData is pointed at ms_galaxyProcessData. */
#include <mach-o/getsect.h>
static void MSPatchGalaxy(const struct mach_header *mh, intptr_t slide) {
    Dl_info di; if (!dladdr(mh, &di) || !di.dli_fname || !strstr(di.dli_fname, "libGameServicesGOG")) return;
    void *h = dlopen("@rpath/libGalaxy.dylib", RTLD_LAZY | RTLD_NOLOAD);
    void *real = h ? dlsym(h, "_ZN6galaxy3api11ProcessDataEv") : NULL;
    if (!real) { MSLogf(@"GOG Galaxy: ProcessData not found - not patched"); return; }
    int patched = 0;
    const char *segs[][2] = { { "__DATA_CONST", "__got" }, { "__DATA", "__got" }, { "__DATA", "__la_symbol_ptr" }, { "__AUTH_CONST", "__auth_got" } };
    for (size_t k = 0; k < sizeof segs / sizeof *segs; k++) {
        unsigned long sz = 0; uint8_t *sec = getsectiondata((const struct mach_header_64 *)mh, segs[k][0], segs[k][1], &sz);
        if (!sec) continue;
        for (unsigned long o = 0; o + 8 <= sz; o += 8) {
            void **slot = (void **)(sec + o);
            if (*slot != real) continue;
            vm_address_t pg = (vm_address_t)slot & ~(vm_address_t)0x3fff;
            vm_protect(mach_task_self(), pg, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            *slot = (void *)ms_galaxyProcessData; patched++;
            vm_protect(mach_task_self(), pg, 0x4000, FALSE, VM_PROT_READ);
        }
    }
    MSLogf(@"GOG Galaxy: patched %d ProcessData import(s) in %s", patched, strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname);
    /* GameServicesGOG::AuthListener: OnAuthFailure tells the game "sign-in failed", and the game's handling of that on
       the main menu corrupts memory and crashes (no Galaxy client on iOS, so it always fails). Its vtable slot is
       pointed at OnAuthSuccess, so the game hears "signed in" and goes on to the menu. Offsets are for this exact
       libGameServicesGOG.dylib and are checked against the code before patching. GalaxyFakeSignIn = NO turns it off. */
    if (![MSConfig()[@"GalaxyFakeSignIn"] isEqual:@NO]) {
        uintptr_t base = (uintptr_t)mh, ok = base + 0x1f58, fail = base + 0x1fdc;
        const uint32_t *ci = (const uint32_t *)ok, *cf = (const uint32_t *)fail;
        if (ci[0] != 0xd100c3ff || cf[0] != 0xd100c3ff || cf[4] != 0xf9400408) { MSLogf(@"GOG Galaxy: unexpected auth listener code - fake sign-in not applied"); return; }
        int n = 0; unsigned long sz = 0;
        uint8_t *sec = getsectiondata((const struct mach_header_64 *)mh, "__DATA_CONST", "__const", &sz);
        for (unsigned long o = 0; sec && o + 8 <= sz; o += 8) {
            uintptr_t *slot = (uintptr_t *)(sec + o);
            if (*slot != fail) continue;
            vm_address_t pg = (vm_address_t)slot & ~(vm_address_t)0x3fff;
            vm_protect(mach_task_self(), pg, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            *slot = ok; n++;
            vm_protect(mach_task_self(), pg, 0x4000, FALSE, VM_PROT_READ);
        }
        MSLogf(@"GOG Galaxy: sign-in failure -> success (%d vtable slot(s) patched)", n);
    }
}
__attribute__((constructor)) static void MSInstallGalaxyPatch(void) { _dyld_register_func_for_add_image(MSPatchGalaxy); }

/* ---------------------------------------------------------------- Bink video (rerouted from libBink2MacArm64) */
static void *MSBink(const char *sym) {
    static void *h; if (!h) h = dlopen("@rpath/libBink2MacArm64.dylib", RTLD_LAZY | RTLD_NOLOAD); if (!h) h = dlopen("@rpath/libBink2MacArm64.dylib", RTLD_LAZY);
    return h ? dlsym(h, sym) : NULL;
}
void *ms_BinkOpenWithOptions(const char *name, const void *opts, unsigned flags) __asm("_BinkOpenWithOptions");
void *ms_BinkOpenWithOptions(const char *name, const void *opts, unsigned flags) {
    static void *(*real)(const char *, const void *, unsigned); if (!real) real = MSBink("BinkOpenWithOptions");
    BOOL nv = [MSConfig()[@"NoVideo"] boolValue];
    void *r = nv ? NULL : real(name, opts, flags);
    MSLogf(@"Bink open %s flags %#x -> %p%s", name ? name : "(null)", flags, r, nv ? " (NoVideo)" : "");
    return r;
}
int ms_BinkStartAsyncThread(int thread, const void *param) __asm("_BinkStartAsyncThread");
int ms_BinkStartAsyncThread(int thread, const void *param) {
    static int (*real)(int, const void *); if (!real) real = MSBink("BinkStartAsyncThread");
    int r = real(thread, param); MSLogf(@"Bink async thread %d -> %d", thread, r); return r;
}

static unsigned long long ms_physMem(id self, SEL _cmd) { return (unsigned long long)([MSConfig()[@"MemSizeGB"] doubleValue] * 1073741824.0); }
__attribute__((constructor)) static void MSInstallMemSize(void) {
    if ([MSConfig()[@"MemSizeGB"] doubleValue] <= 0) return;
    method_setImplementation(class_getInstanceMethod(NSProcessInfo.class, @selector(physicalMemory)), (IMP)ms_physMem);
}
/* frame decoding: NoBinkDecode = YES skips it (frames stay as they are) - test for Bink writing past its buffers */
int ms_BinkDoFrameAsyncMulti(void *bink, unsigned *threads, int n) __asm("_BinkDoFrameAsyncMulti");
int ms_BinkDoFrameAsyncMulti(void *bink, unsigned *threads, int n) {
    static int (*real)(void *, unsigned *, int); if (!real) real = MSBink("BinkDoFrameAsyncMulti");
    static int skip = -1; if (skip < 0) skip = [MSConfig()[@"NoBinkDecode"] boolValue];
    static _Atomic int calls; if (calls++ < 3) MSLogf(@"Bink decode %p on %d thread(s)%s", bink, n, skip ? " - skipped (NoBinkDecode)" : "");
    return skip ? 1 : real(bink, threads, n);
}
int ms_BinkDoFrameAsyncWait(void *bink, int us) __asm("_BinkDoFrameAsyncWait");
int ms_BinkDoFrameAsyncWait(void *bink, int us) {
    static int (*real)(void *, int); if (!real) real = MSBink("BinkDoFrameAsyncWait");
    static int skip = -1; if (skip < 0) skip = [MSConfig()[@"NoBinkDecode"] boolValue];
    return skip ? 1 : real(bink, us);
}
/* BINKFRAMEBUFFERS: log what the game hands Bink to decode into */
void ms_BinkGetFrameBuffersInfo(void *bink, void *fb) __asm("_BinkGetFrameBuffersInfo");
void ms_BinkGetFrameBuffersInfo(void *bink, void *fb) {
    static void (*real)(void *, void *); if (!real) real = MSBink("BinkGetFrameBuffersInfo");
    real(bink, fb);
    const uint32_t *w = fb; MSLogf(@"Bink frame buffers info %p: %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x", bink,
        w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11]);
}
void ms_BinkRegisterFrameBuffers(void *bink, void *fb) __asm("_BinkRegisterFrameBuffers");
void ms_BinkRegisterFrameBuffers(void *bink, void *fb) {
    static void (*real)(void *, void *); if (!real) real = MSBink("BinkRegisterFrameBuffers");
    const uint64_t *q = fb; MSLogf(@"Bink register buffers %p: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx", bink, q[0], q[1], q[2], q[3], q[4], q[5], q[6], q[7]);
    real(bink, fb);
}

/* ---------------------------------------------------------------- engine HTTP (NSURLSession): every URL is logged;
 * BlockNetwork = YES sends requests to a closed local port so they fail at once, like a phone without internet */
static IMP g_oDataTask, g_oUploadTask;
static NSURLRequest *MSNetRequest(NSURLRequest *r, const char *kind) {
    BOOL block = [MSConfig()[@"BlockNetwork"] boolValue];
    MSLogf(@"http %s %@ %@%s", kind, r.HTTPMethod, r.URL.absoluteString, block ? " (blocked)" : "");
    if (!block) return r;
    NSMutableURLRequest *m = [r mutableCopy]; m.URL = [NSURL URLWithString:@"http://127.0.0.1:9/blocked"]; m.timeoutInterval = 5; return m;
}
static id ms_dataTask(id self, SEL c, NSURLRequest *r, id done) { return ((id (*)(id, SEL, id, id))g_oDataTask)(self, c, MSNetRequest(r, "data"), done); }
static id ms_uploadTask(id self, SEL c, NSURLRequest *r, NSURL *f, id done) { return ((id (*)(id, SEL, id, id, id))g_oUploadTask)(self, c, MSNetRequest(r, "upload"), f, done); }
__attribute__((constructor)) static void MSInstallURLSession(void) {
    Class C = object_getClass([NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]);
    Method m;
    if ((m = class_getInstanceMethod(C, @selector(dataTaskWithRequest:completionHandler:)))) g_oDataTask = method_setImplementation(m, (IMP)ms_dataTask);
    if ((m = class_getInstanceMethod(C, @selector(uploadTaskWithRequest:fromFile:completionHandler:)))) g_oUploadTask = method_setImplementation(m, (IMP)ms_uploadTask);
}
