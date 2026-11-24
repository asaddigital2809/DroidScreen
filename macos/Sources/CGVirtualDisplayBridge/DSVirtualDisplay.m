//
//  DSVirtualDisplay.m
//
//  See DSVirtualDisplay.h and CGVirtualDisplayPrivate.h.
//
//  Every private class is looked up with NSClassFromString() and every optional selector is
//  checked with -respondsToSelector:, and all private calls run inside @try so that an
//  Objective-C exception becomes an NSError instead of terminating the process.
//

#import "DSVirtualDisplay.h"
#import "CGVirtualDisplayPrivate.h"

#if !__has_feature(objc_arc)
#error "CGVirtualDisplayBridge must be compiled with ARC"
#endif

NSErrorDomain const DSVirtualDisplayErrorDomain = @"com.droidscreen.virtualdisplay";

static NSString *const kDescriptorClassName = @"CGVirtualDisplayDescriptor";
static NSString *const kModeClassName = @"CGVirtualDisplayMode";
static NSString *const kSettingsClassName = @"CGVirtualDisplaySettings";
static NSString *const kDisplayClassName = @"CGVirtualDisplay";

static NSError *DSMakeError(DSVirtualDisplayError code, NSString *message) {
    return [NSError errorWithDomain:DSVirtualDisplayErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

static void DSSetError(NSError **outError, DSVirtualDisplayError code, NSString *message) {
    if (outError) {
        *outError = DSMakeError(code, message);
    }
}

#pragma mark - DSVirtualDisplayMode

@implementation DSVirtualDisplayMode

- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _refreshRate = refreshRate;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%lux%lu@%.2f", (unsigned long)_width, (unsigned long)_height, _refreshRate];
}

@end

#pragma mark - DSVirtualDisplayDescriptor

@implementation DSVirtualDisplayDescriptor

- (instancetype)init {
    self = [super init];
    if (self) {
        _name = @"DroidScreen";
        _maxPixelsWide = 1920;
        _maxPixelsHigh = 1080;
        _sizeInMillimeters = CGSizeMake(0, 0);
    }
    return self;
}

@end

#pragma mark - DSVirtualDisplay

@implementation DSVirtualDisplay {
    CGVirtualDisplay *_display; // strong; releasing it removes the display
}

/// Returns a list of "Class" / "Class -selector" strings that are required but missing.
+ (NSArray<NSString *> *)missingRequirements {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];

    void (^check)(NSString *, NSArray<NSString *> *) = ^(NSString *className, NSArray<NSString *> *selectors) {
        Class cls = NSClassFromString(className);
        if (cls == Nil) {
            [missing addObject:className];
            return;
        }
        for (NSString *sel in selectors) {
            if (![cls instancesRespondToSelector:NSSelectorFromString(sel)]) {
                [missing addObject:[NSString stringWithFormat:@"%@ -%@", className, sel]];
            }
        }
    };

    check(kDescriptorClassName, @[
        @"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setSizeInMillimeters:",
        @"setVendorID:", @"setProductID:", @"setSerialNum:", @"setTerminationHandler:",
    ]);
    Class descriptorClass = NSClassFromString(kDescriptorClassName);
    if (descriptorClass != Nil &&
        ![descriptorClass instancesRespondToSelector:@selector(setDispatchQueue:)] &&
        ![descriptorClass instancesRespondToSelector:@selector(setQueue:)]) {
        [missing addObject:@"CGVirtualDisplayDescriptor -setDispatchQueue: / -setQueue:"];
    }
    check(kModeClassName, @[ @"initWithWidth:height:refreshRate:" ]);
    check(kSettingsClassName, @[ @"setModes:", @"setHiDPI:" ]);
    check(kDisplayClassName, @[ @"initWithDescriptor:", @"applySettings:", @"displayID" ]);
    return missing;
}

+ (BOOL)isAPIAvailable {
    return [self missingRequirements].count == 0;
}

+ (NSString *)apiAvailabilityReport {
    NSMutableString *report = [NSMutableString string];
    for (NSString *name in @[ kDescriptorClassName, kModeClassName, kSettingsClassName, kDisplayClassName ]) {
        [report appendFormat:@"%@: %@\n", name, NSClassFromString(name) != Nil ? @"present" : @"MISSING"];
    }
    NSArray<NSString *> *missing = [self missingRequirements];
    if (missing.count == 0) {
        [report appendString:@"All required selectors present."];
    } else {
        [report appendFormat:@"Missing: %@", [missing componentsJoinedByString:@", "]];
    }
    return report;
}

- (nullable instancetype)initWithDescriptor:(DSVirtualDisplayDescriptor *)descriptor
                                      queue:(dispatch_queue_t)queue
                         terminationHandler:(nullable void (^)(void))terminationHandler
                                      error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    NSArray<NSString *> *missing = [DSVirtualDisplay missingRequirements];
    if (missing.count > 0) {
        DSSetError(error, DSVirtualDisplayErrorAPIUnavailable,
                   [NSString stringWithFormat:@"CGVirtualDisplay API unavailable on this macOS version. Missing: %@",
                                              [missing componentsJoinedByString:@", "]]);
        return nil;
    }
    if (descriptor.maxPixelsWide == 0 || descriptor.maxPixelsHigh == 0) {
        DSSetError(error, DSVirtualDisplayErrorInvalidArgument, @"maxPixelsWide and maxPixelsHigh must be > 0.");
        return nil;
    }

    @try {
        CGVirtualDisplayDescriptor *cgDescriptor = [[NSClassFromString(kDescriptorClassName) alloc] init];
        cgDescriptor.name = descriptor.name;
        cgDescriptor.maxPixelsWide = descriptor.maxPixelsWide;
        cgDescriptor.maxPixelsHigh = descriptor.maxPixelsHigh;
        cgDescriptor.sizeInMillimeters = descriptor.sizeInMillimeters;
        cgDescriptor.vendorID = descriptor.vendorID;
        cgDescriptor.productID = descriptor.productID;
        cgDescriptor.serialNum = descriptor.serialNumber;

        if ([cgDescriptor respondsToSelector:@selector(setDispatchQueue:)]) {
            [cgDescriptor setDispatchQueue:queue];
        } else {
            [cgDescriptor setQueue:queue];
        }

        // sRGB / Rec.709 primaries and D65 white point. Without these some OS releases
        // report an uncalibrated colour space for the display.
        if ([cgDescriptor respondsToSelector:@selector(setRedPrimary:)]) {
            cgDescriptor.redPrimary = CGPointMake(0.6400, 0.3300);
            cgDescriptor.greenPrimary = CGPointMake(0.3000, 0.6000);
            cgDescriptor.bluePrimary = CGPointMake(0.1500, 0.0600);
            cgDescriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        }

        if (terminationHandler) {
            void (^handler)(void) = [terminationHandler copy];
            // Do not capture self: the handler must not keep the display alive.
            cgDescriptor.terminationHandler = ^(id _Nullable sender, CGVirtualDisplay *_Nullable display) {
                handler();
            };
        }

        CGVirtualDisplay *display =
            [(CGVirtualDisplay *)[NSClassFromString(kDisplayClassName) alloc] initWithDescriptor:cgDescriptor];
        if (display == nil || display.displayID == kCGNullDirectDisplay) {
            DSSetError(error, DSVirtualDisplayErrorCreationFailed,
                       @"WindowServer refused to create the virtual display (initWithDescriptor: returned nil or display ID 0).");
            return nil;
        }
        _display = display;
        _displayID = display.displayID;
    } @catch (NSException *exception) {
        DSSetError(error, DSVirtualDisplayErrorException,
                   [NSString stringWithFormat:@"CGVirtualDisplay raised %@: %@", exception.name, exception.reason]);
        return nil;
    }
    return self;
}

- (BOOL)applyModes:(NSArray<DSVirtualDisplayMode *> *)modes hiDPI:(BOOL)hiDPI error:(NSError **)error {
    if (_display == nil) {
        DSSetError(error, DSVirtualDisplayErrorInvalidated, @"The virtual display was already invalidated.");
        return NO;
    }
    if (modes.count == 0) {
        DSSetError(error, DSVirtualDisplayErrorInvalidArgument, @"At least one display mode is required.");
        return NO;
    }

    @try {
        Class modeClass = NSClassFromString(kModeClassName);
        NSMutableArray<CGVirtualDisplayMode *> *cgModes = [NSMutableArray arrayWithCapacity:modes.count];
        for (DSVirtualDisplayMode *mode in modes) {
            CGVirtualDisplayMode *cgMode = [(CGVirtualDisplayMode *)[modeClass alloc] initWithWidth:mode.width
                                                                                             height:mode.height
                                                                                        refreshRate:mode.refreshRate];
            if (cgMode == nil) {
                DSSetError(error, DSVirtualDisplayErrorInvalidArgument,
                           [NSString stringWithFormat:@"CGVirtualDisplayMode rejected %@", mode]);
                return NO;
            }
            [cgModes addObject:cgMode];
        }

        CGVirtualDisplaySettings *settings = [[NSClassFromString(kSettingsClassName) alloc] init];
        settings.modes = cgModes;
        settings.hiDPI = hiDPI ? 1 : 0;

        if (![_display applySettings:settings]) {
            DSSetError(error, DSVirtualDisplayErrorApplySettingsFailed,
                       @"applySettings: returned NO. A mode may exceed maxPixelsWide/maxPixelsHigh.");
            return NO;
        }
    } @catch (NSException *exception) {
        DSSetError(error, DSVirtualDisplayErrorException,
                   [NSString stringWithFormat:@"applySettings: raised %@: %@", exception.name, exception.reason]);
        return NO;
    }
    return YES;
}

- (BOOL)isInvalidated {
    return _display == nil;
}

- (void)invalidate {
    _display = nil;
    _displayID = kCGNullDirectDisplay;
}

@end
