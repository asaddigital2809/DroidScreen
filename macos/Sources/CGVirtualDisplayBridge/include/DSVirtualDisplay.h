//
//  DSVirtualDisplay.h
//
//  Public (to Swift) wrapper around CoreGraphics' private CGVirtualDisplay.
//
//  Lifetime rule: the virtual display exists exactly as long as the DSVirtualDisplay object
//  is alive and -invalidate has not been called. When the owning process exits, WindowServer
//  removes the display automatically.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const DSVirtualDisplayErrorDomain;

typedef NS_ERROR_ENUM(DSVirtualDisplayErrorDomain, DSVirtualDisplayError) {
    /// A private class or selector required to create a virtual display is missing on this OS.
    DSVirtualDisplayErrorAPIUnavailable = 1,
    /// -[CGVirtualDisplay initWithDescriptor:] returned nil or display ID 0.
    DSVirtualDisplayErrorCreationFailed = 2,
    /// -[CGVirtualDisplay applySettings:] returned NO.
    DSVirtualDisplayErrorApplySettingsFailed = 3,
    /// A caller-supplied argument was out of range.
    DSVirtualDisplayErrorInvalidArgument = 4,
    /// The private API raised an Objective-C exception (caught and converted).
    DSVirtualDisplayErrorException = 5,
    /// The display was already invalidated.
    DSVirtualDisplayErrorInvalidated = 6,
};

/// One display mode offered to macOS. Width and height are in pixels.
@interface DSVirtualDisplayMode : NSObject
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Identity and physical properties of the virtual display (what an EDID would normally carry).
@interface DSVirtualDisplayDescriptor : NSObject
@property (copy, nonatomic) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
/// macOS remembers arrangement and resolution per (vendorID, productID, serialNumber).
@property (nonatomic) uint32_t serialNumber;
@end

@interface DSVirtualDisplay : NSObject

/// YES when every private class and selector needed for creation exists at runtime.
+ (BOOL)isAPIAvailable;

/// Human-readable list of what was found / missing. Used for diagnostics.
+ (NSString *)apiAvailabilityReport;

/// Creates and registers a virtual display with WindowServer.
/// @param queue Queue on which @c terminationHandler is invoked.
/// @param terminationHandler Called if WindowServer tears the display down on its own.
- (nullable instancetype)initWithDescriptor:(DSVirtualDisplayDescriptor *)descriptor
                                      queue:(dispatch_queue_t)queue
                         terminationHandler:(nullable void (^)(void))terminationHandler
                                      error:(NSError **)error
    NS_SWIFT_NAME(init(descriptor:queue:terminationHandler:));

- (instancetype)init NS_UNAVAILABLE;

/// Publishes the list of modes macOS may use for this display.
/// @param hiDPI When YES, macOS also offers 2x (Retina, "looks like" half-size) variants.
- (BOOL)applyModes:(NSArray<DSVirtualDisplayMode *> *)modes
             hiDPI:(BOOL)hiDPI
             error:(NSError **)error;

/// The CoreGraphics display ID. Valid until -invalidate. 0 after invalidation.
@property (readonly, nonatomic) CGDirectDisplayID displayID;

/// YES after -invalidate.
@property (readonly, nonatomic, getter=isInvalidated) BOOL invalidated;

/// Releases the underlying CGVirtualDisplay. macOS removes the display shortly afterwards.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
