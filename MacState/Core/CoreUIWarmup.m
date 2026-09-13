#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// CoreUI 共享 CIContext 预热。
// 部分老 GPU 驱动（macOS 14 Iris Pro 的 MetalOld.dylib 遥测）在"进程运行
// 一段时间后首次创建 CoreUI 共享 CIContext"时会因调用栈里恰好出现
// tagged NSNumber 而抛 unrecognized selector，且异常穿过 dispatch_once 的
// noexcept 帧直接 terminate（@try 接不住）。实测裸进程启动早期创建必然
// 成功；dispatch_once 之后全局复用，后续任何布局都不再触发创建路径。
// 必须在 main 最早处、任何 AppKit/SwiftUI 工作之前调用。
void macstate_warmup_coreui(void) {
    Class cls = NSClassFromString(@"CUIShapeEffectStack");
    if (!cls) return;
    SEL sel = NSSelectorFromString(@"sharedCIContext");
    if (!class_respondsToSelector(object_getClass((id)cls), sel)) return;

    IMP imp = method_getImplementation(class_getClassMethod(cls, sel));
    if (!imp) return;
    id ctx = ((id(*)(id, SEL))imp)((id)cls, sel);
    NSLog(@"MacState CoreUI warmup: %@", ctx ? @"ok" : @"nil");
}
