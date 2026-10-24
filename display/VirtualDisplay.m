#import "display/VirtualDisplay.h"
#import <CoreGraphics/CoreGraphics.h>
#import <unistd.h>
#define RDP_LOG_COMPONENT "display"
#include "logging/RDPLog.h"

#if MACOS_RDP_VIRTUAL_DISPLAY
/* The private initializers, declared so ARC sees them as the init family: an
 * init consumes its receiver and, when it fails, releases it and returns nil.
 * Called through performSelector:/NSInvocation instead, ARC released the
 * receiver once more after a failed init — a crash in objc_release whenever
 * macOS refused to create the display (as it does while a previous one with
 * the same serial number is still around). */
@protocol RDPVirtualDisplayModeInit
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end
@protocol RDPVirtualDisplayInit
- (instancetype)initWithDescriptor:(id)descriptor;
@end
#endif

@interface VirtualDisplay ()
@property (nonatomic, assign) CGDirectDisplayID did;
@property (nonatomic, assign) uint32_t w;
@property (nonatomic, assign) uint32_t h;
@property (nonatomic, assign) BOOL created;
@property (nonatomic, assign) BOOL hidpi;
/* Bumped by every mode change, so a background switch to an older one stops. */
@property (atomic, assign) uint64_t modeGeneration;

#if MACOS_RDP_VIRTUAL_DISPLAY
/* Opaque pointers so the compiler doesn't need CGVirtualDisplay headers here.
 * CGVirtualDisplay and its private VirtualDisplayListener thread keep using the
 * descriptor/mode/settings objects AFTER applySettings: returns, so all of them
 * must be retained for the display's whole lifetime — otherwise they dealloc when
 * createVirtualDisplay returns and the listener thread crashes on freed memory. */
@property (nonatomic, strong) id vdObject;
@property (nonatomic, strong) id vdDescriptor;
@property (nonatomic, strong) id vdMode;
@property (nonatomic, strong) id vdSettings;
#endif
@end

@implementation VirtualDisplay

- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height {
    return [self initWithWidth:width height:height hiDPI:NO];
}

- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height hiDPI:(BOOL)hiDPI {
    if ((self = [super init])) {
        _w = width;
        _h = height;
        _hidpi = hiDPI;
    }
    return self;
}

- (BOOL)hiDPI { return _hidpi; }

- (BOOL)isVirtual {
#if MACOS_RDP_VIRTUAL_DISPLAY
    return _vdObject != nil;
#else
    return NO;
#endif
}

static VirtualDisplay *gReusable;

+ (nullable VirtualDisplay *)reusable {
    @synchronized(self) { return gReusable; }
}

+ (void)setReusable:(nullable VirtualDisplay *)display {
    @synchronized(self) { gReusable = display; }
}

- (CGDirectDisplayID)displayID { return _did; }
- (uint32_t)width              { return _w; }
- (uint32_t)height             { return _h; }

- (BOOL)create {
    if (_created) return YES;

#if MACOS_RDP_VIRTUAL_DISPLAY
    [self createVirtualDisplay];
#else
    /* Default: capture the main display. Physical display is undisturbed
       because RDP sessions run in a separate window-server context when
       the daemon is launched as a login item for a specific user. */
    _did = CGMainDisplayID();
    rdp_info("using main display %u (%ux%u) — build with MACOS_RDP_VIRTUAL_DISPLAY=1 "
             "for a dedicated virtual display (requires Apple entitlement)", _did, _w, _h);
#endif

    _created = YES;
    return YES;
}

- (void)destroy {
    if (!_created) return;
#if MACOS_RDP_VIRTUAL_DISPLAY
    /* Release in reverse dependency order: drop the display first (stops its
     * listener thread), then the settings/mode/descriptor it referenced. */
    BOOL hadDisplay = _vdObject != nil;
    _vdObject     = nil;
    _vdSettings   = nil;
    _vdMode       = nil;
    _vdDescriptor = nil;
    /* macOS removes the display asynchronously, and one whose process exits
     * before it is gone lingers for minutes, refusing any new display with its
     * serial number. Wait here for it to go: the daemon restarts right after
     * releasing its display (see RDPServer). */
    if (hadDisplay && _did) {
        BOOL gone = NO;
        for (int i = 0; i < 50 && !gone; i++) {
            CGDirectDisplayID online[16];
            uint32_t count = 0;
            gone = YES;
            if (CGGetOnlineDisplayList(16, online, &count) == kCGErrorSuccess)
                for (uint32_t k = 0; k < count; k++) if (online[k] == _did) gone = NO;
            if (!gone) usleep(100000);
        }
        if (gone) rdp_verbose("virtual display %u removed", _did);
        else      rdp_error("virtual display %u still registered 5s after release", _did);
    }
#endif
    _did = 0;
    _created = NO;
    rdp_verbose("display released");
}

- (void)setResolutionWidth:(uint32_t)width height:(uint32_t)height {
    _w = width;
    _h = height;
    rdp_verbose("resolution set to %ux%u (takes effect on next session)", width, height);
}

#if MACOS_RDP_VIRTUAL_DISPLAY
/* The largest desktop a session may resize to, in pixels. CGVirtualDisplay
 * fixes this at creation, so it is generous; it costs nothing until used. */
static const uint32_t kMaxPixelsWide = 7680;
static const uint32_t kMaxPixelsHigh = 4320;

/* A CGVirtualDisplayMode of w x h (POINTS when the settings are hiDPI). */
static id make_mode(uint32_t w, uint32_t h) {
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (![modeClass instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]) return nil;
    return [(id<RDPVirtualDisplayModeInit>)[modeClass alloc] initWithWidth:w height:h refreshRate:60.0];
}

/* Hands macOS a mode list of just this one mode. */
- (BOOL)applySettingsWidth:(uint32_t)pw height:(uint32_t)ph hiDPI:(BOOL)hiDPI {
    id mode = make_mode(pw, ph);
    if (!mode) { rdp_error("CGVirtualDisplayMode init failed"); return NO; }
    id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    [settings setValue:@[mode] forKey:@"modes"];
    @try { [settings setValue:@(hiDPI ? 1 : 0) forKey:@"hiDPI"]; } @catch (id e) {}

    BOOL applied = NO;
    SEL applySel = @selector(applySettings:);
    /* The invocation is autoreleased and retains its target: without a pool
     * of its own, the session queue's pool kept the CGVirtualDisplay alive
     * after -destroy, and macOS refused the next session's display. */
    @autoreleasepool {
        if ([_vdObject respondsToSelector:applySel]) {
            NSMethodSignature *sig2 = [_vdObject methodSignatureForSelector:applySel];
            NSInvocation *inv2 = [NSInvocation invocationWithMethodSignature:sig2];
            inv2.target = _vdObject; inv2.selector = applySel;
            [inv2 setArgument:&settings atIndex:2];
            [inv2 retainArguments];
            [inv2 invoke];
            [inv2 getReturnValue:&applied];
        }
    }
    _vdMode = mode;
    _vdSettings = settings;
    return applied;
}

/* Waits for the mode pw x ph points at w x h pixels to be offered, and
 * switches to it. Returns whether the display is in that mode now. */
- (BOOL)selectModeWidth:(uint32_t)w height:(uint32_t)h points:(uint32_t)pw :(uint32_t)ph
                timeout:(useconds_t)timeout {
    for (useconds_t waited = 0; waited <= timeout; waited += 100000) {
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(_did);
        BOOL already = cur && CGDisplayModeGetWidth(cur) == pw && CGDisplayModeGetHeight(cur) == ph &&
                       CGDisplayModeGetPixelWidth(cur) == w && CGDisplayModeGetPixelHeight(cur) == h;
        CGDisplayModeRelease(cur);
        if (already) return YES;
        NSDictionary *opts = @{ (__bridge id)kCGDisplayShowDuplicateLowResolutionModes: @YES };
        NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(_did, (__bridge CFDictionaryRef)opts));
        for (id x in modes) {
            CGDisplayModeRef dm = (__bridge CGDisplayModeRef)x;
            if (CGDisplayModeGetWidth(dm) == pw && CGDisplayModeGetHeight(dm) == ph &&
                CGDisplayModeGetPixelWidth(dm) == w && CGDisplayModeGetPixelHeight(dm) == h) {
                CGDisplayConfigRef cfg = NULL;
                if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
                    CGConfigureDisplayWithDisplayMode(cfg, _did, dm, NULL);
                    CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
                }
                break;
            }
        }
        usleep(100000);   /* the mode list, and the switch, apply asynchronously */
    }
    return NO;
}

/* Applies one mode to the virtual display and switches to it. For HiDPI the
 * mode is given in points and macOS offers it backed by twice the pixels; that
 * backed variant has to be selected explicitly, as the display may come up in
 * the 1x one. The new mode list can take seconds to appear, and in the daemon
 * it did not while the session queue waited for it, so after a short wait the
 * switch is left to a background queue: the session goes on at the new size
 * and the display follows as soon as macOS offers the mode. */
- (BOOL)applyModeWidth:(uint32_t)w height:(uint32_t)h hiDPI:(BOOL)hiDPI {
    uint32_t pw = hiDPI ? w / 2 : w, ph = hiDPI ? h / 2 : h;
    if (![self applySettingsWidth:pw height:ph hiDPI:hiDPI]) {
        rdp_error("applySettings %ux%u%s failed", w, h, hiDPI ? " HiDPI" : "");
        return NO;
    }
    if (!_did) {
        @try { _did = (CGDirectDisplayID)[[_vdObject valueForKey:@"displayID"] unsignedIntValue]; }
        @catch (id e) {}
        if (!_did) { rdp_error("virtual display has no displayID after applySettings"); return NO; }
        usleep(400000);   /* let the new display register before asking for its modes */
    }
    _w = w; _h = h; _hidpi = hiDPI;
    uint64_t generation = ++_modeGeneration;
    if ([self selectModeWidth:w height:h points:pw :ph timeout:1000000]) {
        rdp_info("virtual display %u: %ux%u pixels as %ux%u points", _did, w, h, pw, ph);
        return YES;
    }
    rdp_info("virtual display %u: %ux%u pixels as %ux%u points not offered yet - switching when it is",
             _did, w, h, pw, ph);
    __weak VirtualDisplay *weak = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < 100; i++) {   /* up to ~10 s */
            VirtualDisplay *vd = weak;
            if (!vd || vd->_modeGeneration != generation || !vd->_did) return;   /* superseded */
            if ([vd selectModeWidth:w height:h points:pw :ph timeout:0]) {
                rdp_info("virtual display %u: now %ux%u pixels as %ux%u points", vd->_did, w, h, pw, ph);
                return;
            }
            vd = nil;
            usleep(100000);
        }
        rdp_error("virtual display: %ux%u pixels as %ux%u points was never offered", w, h, pw, ph);
    });
    return YES;
}

- (BOOL)reconfigureWidth:(uint32_t)width height:(uint32_t)height hiDPI:(BOOL)hiDPI {
    if (!_created || !_vdObject) return NO;
    if (width > kMaxPixelsWide || height > kMaxPixelsHigh) {
        rdp_error("resize to %ux%u exceeds the virtual display's %ux%u maximum", width, height,
                  kMaxPixelsWide, kMaxPixelsHigh);
        return NO;
    }
    if (width == _w && height == _h && hiDPI == _hidpi) return YES;
    return [self applyModeWidth:width height:height hiDPI:hiDPI];
}

- (id)descriptorWithClass:(Class)descClass serial:(uint32_t)serial {
    id desc = [[descClass alloc] init];
    [desc setValue:@"RDP Virtual Display" forKey:@"name"];
    [desc setValue:@(MAX(_w, kMaxPixelsWide)) forKey:@"maxPixelsWide"];
    [desc setValue:@(MAX(_h, kMaxPixelsHigh)) forKey:@"maxPixelsHigh"];
    /* The panel's physical size decides what macOS treats as its native
     * density: ~220 ppi reads as a Retina panel, ~100 as a standard one. */
    double dpi = _hidpi ? 220.0 : 100.0;
    CGSize mm = CGSizeMake((_w / dpi) * 25.4, (_h / dpi) * 25.4);
    [desc setValue:[NSValue valueWithBytes:&mm objCType:@encode(CGSize)]
            forKey:@"sizeInMillimeters"];
    @try { [desc setValue:@(0x5244500u) forKey:@"productID"]; } @catch (id e) {}
    @try { [desc setValue:@(0x5244500u) forKey:@"vendorID"];  } @catch (id e) {}
    @try { [desc setValue:@(serial)     forKey:@"serialNum"]; } @catch (id e) {}
    @try { [desc setValue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                   forKey:@"queue"]; } @catch (id e) {}
    return desc;
}

/* Put the virtual display at the global origin (0,0) = main, and the other
 * displays to its right. Only the displays that are active now are moved:
 * CGMainDisplayID() can still name a virtual display that was just released,
 * and configuring that one failed the whole change (rc=1001), leaving the
 * session on a secondary display with no menu bar or windows. */
- (void)makeMain {
    for (int attempt = 0; attempt < 5; attempt++) {
        if (CGMainDisplayID() == _did) {
            rdp_info("virtual display %u is the main display", _did);
            return;
        }
        CGDirectDisplayID active[16];
        uint32_t count = 0;
        if (CGGetActiveDisplayList(16, active, &count) != kCGErrorSuccess) count = 0;
        CGDisplayConfigRef cfg = NULL;
        CGError rc = CGBeginDisplayConfiguration(&cfg);
        if (rc == kCGErrorSuccess) {
            CGConfigureDisplayOrigin(cfg, _did, 0, 0);
            int32_t x = (int32_t)CGDisplayBounds(_did).size.width;
            for (uint32_t i = 0; i < count; i++) {
                if (active[i] == _did) continue;
                CGConfigureDisplayOrigin(cfg, active[i], x, 0);
                x += (int32_t)CGDisplayBounds(active[i]).size.width;
            }
            rc = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        }
        rdp_info("virtual display %u set as main (%u other display(s) moved aside, rc=%d)",
                 _did, count ? count - 1 : 0, rc);
        usleep(200000);   /* the arrangement applies asynchronously */
    }
    if (CGMainDisplayID() != _did)
        rdp_error("virtual display %u could not be made the main display", _did);
}

- (void)createVirtualDisplay {
    /*
     * Create a CGVirtualDisplay sized exactly to the RDP client (e.g. 3440x1440)
     * so there is no pillarbox/scaling and pointer mapping is 1:1. CGVirtualDisplay
     * is a PRIVATE CoreGraphics API (CGVirtualDisplayDescriptor / *Mode / *Settings),
     * driven here entirely via NSClassFromString + KVC + NSInvocation so a missing
     * class / wrong ABI / thrown exception cleanly falls back to the main display
     * (pillarboxed) instead of crashing the daemon.
     */
    _did = CGMainDisplayID();   /* safe default */
    @try {
        Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class dispClass = NSClassFromString(@"CGVirtualDisplay");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class setClass  = NSClassFromString(@"CGVirtualDisplaySettings");
        if (!descClass || !dispClass || !modeClass || !setClass) {
            rdp_error("CGVirtualDisplay classes unavailable on this macOS — "
                      "using main display (pillarboxed)");
            return;
        }

        /* macOS refuses a second display with the same vendor/product/serial
         * while the previous one is still registered — and one released by a
         * session that ended (or a daemon that died) can linger for minutes.
         * Wait a moment for it once, then take the next serial number. Only a
         * few serials are used, as macOS keeps an arrangement for each. */
        id desc = nil, vd = nil;
        static const uint32_t kSerials[] = { 1, 1, 2, 3, 4 };
        for (size_t i = 0; i < sizeof kSerials / sizeof kSerials[0] && !vd; i++) {
            if (i == 1) usleep(1000000);
            desc = [self descriptorWithClass:descClass serial:kSerials[i]];
            vd = [(id<RDPVirtualDisplayInit>)[dispClass alloc] initWithDescriptor:desc];
            if (!vd)
                rdp_info("CGVirtualDisplay with serial %u refused (a previous one may still be registered)",
                         kSerials[i]);
            else if (kSerials[i] != 1)
                rdp_info("CGVirtualDisplay created with serial %u", kSerials[i]);
        }
        if (!vd) { rdp_error("CGVirtualDisplay init failed — main display"); return; }

        _vdObject     = vd;
        _vdDescriptor = desc;
        _did          = 0;
        BOOL applied = [self applyModeWidth:_w height:_h hiDPI:_hidpi];
        CGDirectDisplayID vdid = applied ? _did : 0;
        if (!applied) { _vdObject = nil; _vdDescriptor = nil; _did = CGMainDisplayID(); }

        if (vdid != 0) {
            /* Retain ALL of these for the display's lifetime — CGVirtualDisplay and
             * its listener thread reference the descriptor (and its queue), the mode,
             * and the settings after this function returns. Letting them dealloc here
             * was a use-after-free that crashed the daemon mid-session. */
            rdp_info("virtual display created: displayID=%u %ux%u%s",
                     _did, _w, _h, _hidpi ? " HiDPI" : "");

            /* Make the virtual display the MAIN display so the menu bar, Dock, and
             * newly-opened windows land ON it. Otherwise apps open on the built-in
             * screen, invisible to the RDP session ("windows never pop up"). */
            [self makeMain];
        } else {
            rdp_error("virtual display has no displayID — main display");
        }
    } @catch (NSException *e) {
        rdp_error("virtual display creation threw (%s) — main display",
                  e.reason.UTF8String ?: "?");
        _did = CGMainDisplayID();
    }
}
#endif

@end
