//
//  CGVirtualDisplayPrivate.h
//
//  Interface declarations for CoreGraphics' PRIVATE virtual display classes.
//
//  Apple does not publish these classes. The declarations below were reconstructed from
//  the Objective-C runtime metadata of CoreGraphics.framework and match what open-source
//  projects (Chromium's ui/display/mac/test/virtual_display_mac_util.mm, DeskPad) use.
//
//  IMPORTANT
//  - This header is private to the CGVirtualDisplayBridge target. It is NOT exported to Swift.
//  - The classes are used only as static *types*. Instances are always created through
//    NSClassFromString(), so the binary has no link-time dependency on private symbols.
//    If Apple removes or renames a class, +[DSVirtualDisplay isAPIAvailable] returns NO
//    and creation fails with DSVirtualDisplayErrorAPIUnavailable instead of crashing.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable sender, CGVirtualDisplay * _Nullable display);
// The callback queue is exposed under two selector names depending on the OS release.
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (void)setQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
