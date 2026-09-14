#import "CoreUIWarmup.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

#pragma mark - MetalOld 机器识别

/// MetalOld.dylib 服务的老 Intel 核显机器（Haswell / Broadwell）。
/// 用 CPU 型号判定：Haswell = model 60/63/69/70，Broadwell = model 61/71。
/// （IOAccelerator 的 IOClass 字段在这代硬件上不可靠，实测漏检。）
static BOOL IsMetalOldMachine(void) {
    int arm64 = 0;
    size_t sz = sizeof(arm64);
    sysctlbyname("hw.optional.arm64", &arm64, &sz, NULL, 0);
    if (arm64 == 1) return false;

    int model = 0;
    sysctlbyname("machdep.cpu.model", &model, &sz, NULL, 0);
    return (model == 60 || model == 63 || model == 69 || model == 70 ||
            model == 61 || model == 71);
}

#pragma mark - NSNumber 遥测兼容层

/// 坏驱动遥测把栈上的 NSNumber 标签指针误当 CFString 调用（length /
/// _getCString / characterAtIndex / ...）。逐个补方法只能覆盖已知选择器；
/// 改用 ObjC 转发兜底——所有未识别选择器统一转发到一个空 NSString 实例
/// （NSString 天然响应这些方法，返回无害数据），整个崩溃类一次性消失，
/// 覆盖 CoreUI / RenderBox / Core Animation 合成等所有 Metal 提交路径。
static id TelemetryCompat_forwardTarget(id self, SEL _cmd) {
    return @"";
}

static void EngageTelemetryCompat(void) {
    // __NSCFNumber 是公开 NSNumber 的实际实现类（tagged pointer 同样走它）；
    // __NSCFBoolean 是其布尔兄弟。加在实现类上才能拦截实际分发。
    const char *classNames[] = { "__NSCFNumber", "__NSCFBoolean" };
    SEL targetSel = @selector(forwardingTargetForSelector:);
    for (size_t i = 0; i < sizeof(classNames) / sizeof(classNames[0]); i++) {
        Class cls = NSClassFromString(@(classNames[i]));
        if (!cls) continue;
        // 继承自 NSObject 的该方法，在实现类上添加即为覆盖
        class_addMethod(cls, targetSel,
            imp_implementationWithBlock(^id(id self, SEL _cmd) { return @""; }),
            "@@:@");
        NSLog(@"MacState CoreUI: telemetry compat engaged on %s", classNames[i]);
    }
}

#pragma mark - CoreUI 扁平化直通

/// CoreUI 扁平化的直通实现：返回输入 shape 图（+1），完全不经过
/// CoreImage（Metal / OpenCL 代码零执行）。
static CGImageRef PassthroughFlatten(id self, SEL _cmd, CGImageRef shape,
                                     CGFloat scale, BOOL cache) {
    return CGImageRetain(shape);
}

static void EngagePassthroughFlatten(void) {
    Class cls = NSClassFromString(@"CUIShapeEffectStack");
    if (!cls) return;
    Method m = class_getInstanceMethod(
        cls, NSSelectorFromString(@"newFlattenedImageFromShapeCGImage:withScale:cache:"));
    if (!m) return;
    method_setImplementation(m, (IMP)PassthroughFlatten);
    NSLog(@"MacState CoreUI: passthrough flatten engaged");
}

#pragma mark - 入口

void macstate_prepare_coreui(void) {
    // 第一优先：NSNumber 转发兜底（治本，覆盖所有 Metal 提交路径）
    EngageTelemetryCompat();

    // 老驱动机器（Haswell/Broadwell）：CoreUI 原生扁平化仍会执行 CoreImage，
    // 启动即切直通（基础模式机器反正全原生 UI，视觉差异无感）
    if (IsMetalOldMachine()) {
        EngagePassthroughFlatten();
    }
}
