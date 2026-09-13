#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 规避 CoreUI 渲染管线在部分老 GPU 上的崩溃（点击设置面板闪退）。
///
/// 症状与根因：部分老 Intel 核显（如 Haswell Iris Pro，MetalOld 驱动栈）
/// 上，CoreUI 给控件图层做"形状特效扁平化"时要经 CoreImage 创建
/// Metal CIContext；CoreImage 给 Metal 命令队列 setLabel 会触发驱动遥测
/// 代码，把栈上数据误当 CFString 调用（`-[__NSCFNumber length]`），
/// 异常穿过 dispatch_once 的 C++ 帧无法捕获，进程 SIGABRT。触发与否
/// 取决于创建瞬间的栈内容，具有随机性（同一台机器时好时坏）。
/// 该机的 CoreImage 软件渲染后端同样损坏（OpenCL 驱动崩溃），两条
/// CoreImage 路径都不能用。
///
/// 策略：
/// 1. fork 子进程探测原生 CIContext 创建是否崩溃（崩了只死子进程），
///    连测 3 次以降低漏检概率；带 2 秒超时看防死锁。
/// 2. 探测全部通过 => 不做任何干预，原生渲染（Apple Silicon / 健康
///    Intel / AMD 机器行为完全不变）。
/// 3. 任一次崩溃 => 用直通实现替换 CoreUI 的扁平化方法（返回原始
///    shape 图，不再调用 CoreImage），Metal/OpenCL 代码彻底不执行。
///    代价仅是控件装饰特效略有差异，基础外观不变。
///
/// 手动开关：defaults write com.snail007.macstate ForceSafeCoreUI -bool YES
/// （或环境变量 MACSTATE_FORCE_SAFE_COREUI=1）可跳过探测直接启用直通，
/// 供用户自救与技术支持排查。
///
/// 必须在 AppKit 渲染任何控件之前调用（applicationDidFinishLaunching
/// 最前面）。
void macstate_prepare_coreui(void);

NS_ASSUME_NONNULL_END
