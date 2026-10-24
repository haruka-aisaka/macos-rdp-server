#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * VirtualDisplay: manages which CGDirectDisplayID the session captures.
 *
 * Without the com.apple.developer.virtual-display entitlement (which requires
 * an explicit Apple approval), CGVirtualDisplay symbols are not exported from
 * the SDK. We default to CGMainDisplayID() and add the virtual display path
 * behind MACOS_RDP_VIRTUAL_DISPLAY so it compiles only when the entitlement
 * is present and the binary is properly signed.
 */
@interface VirtualDisplay : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
/* Drawn at Retina density: the desktop is width/2 x height/2 points, backed by
 * width x height pixels. width/height are always the PIXEL size the client sees. */
@property (nonatomic, readonly) BOOL hiDPI;
/* NO when creating the virtual display failed and this stands for the main display. */
@property (nonatomic, readonly) BOOL isVirtual;

- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height;
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height hiDPI:(BOOL)hiDPI;
- (BOOL)create;
- (void)destroy;
- (void)setResolutionWidth:(uint32_t)width height:(uint32_t)height;
/* Change a live virtual display's size and density in place (the display id,
 * and so the windows on it, stay). Returns NO when this is the main display
 * fallback or the mode could not be applied. */
- (BOOL)reconfigureWidth:(uint32_t)width height:(uint32_t)height hiDPI:(BOOL)hiDPI;
/* Make this display the main one (menu bar, Dock, new windows), the others to
 * its right. */
- (void)makeMain;

/* The virtual display kept between sessions. macOS brings only the first
 * CGVirtualDisplay a process creates fully online: one created after it was
 * released gets no modes at all (a session showing nothing but a magnified
 * wallpaper). So the first one is kept and resized for every later session,
 * and released only when the daemon restarts after being idle. */
+ (nullable VirtualDisplay *)reusable;
+ (void)setReusable:(nullable VirtualDisplay *)display;

@end

NS_ASSUME_NONNULL_END
