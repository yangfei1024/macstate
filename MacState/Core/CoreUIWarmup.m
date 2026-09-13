#import "CoreUIWarmup.h"
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <sys/wait.h>
#import <unistd.h>

/// 单次探测的超时（秒）。子进程若因驱动问题死锁，按崩溃处理。
static const NSTimeInterval kProbeTimeout = 2.0;
/// 探测次数：崩溃是概率性的，多测几次降低"坏机器侥幸通过"的概率。
static const int kProbeRuns = 3;

/// CoreUI 扁平化的直通实现：返回输入 shape 图（+1），完全不经过
/// CoreImage（Metal / OpenCL 代码零执行），从根上消除崩溃面。
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
    NSLog(@"MacState CoreUI: passthrough flatten engaged (native CI is broken)");
}

/// 在子进程里跑一次原生 sharedCIContext；返回是否按"会崩"处理。
static BOOL ProbeOnceCrashes(Class cls, SEL sel) {
    pid_t pid = fork();
    if (pid == 0) {
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [cls performSelector:sel];
            #pragma clang diagnostic pop
        } @catch (NSException *e) {
            NSLog(@"MacState CoreUI probe: child exception %@ (unsafe)", e.name);
        }
        _exit(0);
    }
    BOOL crashed = NO;
    NSTimeInterval waited = 0;
    int status = 0;
    while (waited < kProbeTimeout) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) {
            crashed = WIFSIGNALED(status) ||
                      (WIFEXITED(status) && WEXITSTATUS(status) != 0);
            break;
        }
        if (r < 0) break;
        usleep(20000); // 20ms
        waited += 0.02;
    }
    if (waited >= kProbeTimeout) {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        crashed = YES;
    }
    return crashed;
}

/// NSNumber 遥测兼容层：坏驱动的遥测代码会把栈上的 NSNumber 标签指针
/// 误当 CFString 调用（length / _getCString:maxLength:encoding: /
/// characterAtIndex:），走 ObjC 转发必崩。补 3 个占位方法让调用变成
/// 无害返回。合法代码不会对 NSNumber 调这些 NSString 选择器（原本必崩），
/// 因此不影响任何正常路径。必须在所有探测之前启用。
static BOOL TelemetryCompat_getCString(id self, SEL _cmd, char *buf, NSUInteger max, NSUInteger enc) {
    if (buf && max > 0) { buf[0] = '?'; buf[1] = '\0'; }
    return YES;
}

static unsigned short TelemetryCompat_charAtIndex(id self, SEL _cmd, NSUInteger index) {
    return 63;
}

static void EngageTelemetryCompat(void) {
    Class cls = [NSNumber class];
    if (!class_getInstanceMethod(cls, @selector(length))) {
        class_addMethod(cls, @selector(length),
            imp_implementationWithBlock(^NSUInteger(id self){ return 4; }), "I@:");
    }
    if (!class_getInstanceMethod(cls, @selector(_getCString:maxLength:encoding:))) {
        class_addMethod(cls, @selector(_getCString:maxLength:encoding:),
            (IMP)TelemetryCompat_getCString, "B@:^*QQ");
    }
    if (!class_getInstanceMethod(cls, @selector(characterAtIndex:))) {
        class_addMethod(cls, @selector(characterAtIndex:),
            (IMP)TelemetryCompat_charAtIndex, "S@:Q");
    }
    NSLog(@"MacState CoreUI: NSNumber telemetry compat engaged");
}

void macstate_prepare_coreui(void) {
    // 最先：让驱动遥测的误调用变成无害返回（覆盖 CoreUI / RenderBox /
    // Core Animation 等所有 Metal 提交路径的同类崩溃）
    EngageTelemetryCompat();

    Class cls = NSClassFromString(@"CUIShapeEffectStack");
    SEL sel = NSSelectorFromString(@"sharedCIContext");
    if (!cls || ![(id)cls respondsToSelector:sel]) return;

    // 测试/支持开关：defaults write com.snail007.macstate ForceSafeCoreUI -bool YES
    // 或环境变量 MACSTATE_FORCE_SAFE_COREUI=1，跳过探测直接启用直通
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"ForceSafeCoreUI"] ||
        getenv("MACSTATE_FORCE_SAFE_COREUI") != NULL) {
        NSLog(@"MacState CoreUI: safe mode forced via switch");
        EngagePassthroughFlatten();
        return;
    }

    for (int i = 0; i < kProbeRuns; i++) {
        if (ProbeOnceCrashes(cls, sel)) {
            NSLog(@"MacState CoreUI: probe %d/%d crashed (native CI broken), "
                  @"engaging safe rendering", i + 1, kProbeRuns);
            EngagePassthroughFlatten();
            return;
        }
    }
    NSLog(@"MacState CoreUI: %d probes passed, native rendering kept", kProbeRuns);
}
