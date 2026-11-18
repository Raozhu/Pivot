// 私有系统接口声明。这些接口未公开，只能自用或侧载；系统更新后可能需要调整。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: CGVirtualDisplay（CoreGraphics 私有）

@class CGVirtualDisplay;

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic) unsigned int rotation;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic, nullable) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable, CGVirtualDisplay * _Nullable);
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// MARK: IOHIDUserDevice（IOKit 私有，需要 com.apple.developer.hid.virtual.device 权限）

typedef struct CF_BRIDGED_TYPE(id) __IOHIDUserDevice *IOHIDUserDeviceRef;

extern IOHIDUserDeviceRef _Nullable IOHIDUserDeviceCreateWithProperties(CFAllocatorRef _Nullable allocator, CFDictionaryRef properties, IOOptionBits options) CF_RETURNS_RETAINED;
extern void IOHIDUserDeviceSetDispatchQueue(IOHIDUserDeviceRef device, dispatch_queue_t queue);
extern void IOHIDUserDeviceActivate(IOHIDUserDeviceRef device);
extern void IOHIDUserDeviceCancel(IOHIDUserDeviceRef device);
extern IOReturn IOHIDUserDeviceHandleReportWithTimeStamp(IOHIDUserDeviceRef device, uint64_t timestamp, const uint8_t *report, CFIndex reportLength);
extern void IOHIDUserDeviceRegisterGetReportBlock(IOHIDUserDeviceRef device, IOReturn (^block)(uint32_t type, uint32_t reportID, uint8_t *report, CFIndex *reportLength));

// MARK: 窗口服务连接（私有）：允许后台应用隐藏鼠标指针

extern int CGSMainConnectionID(void);
extern CGError CGSSetConnectionProperty(int connection, int target, CFStringRef key, CFTypeRef _Nullable value);

NS_ASSUME_NONNULL_END
