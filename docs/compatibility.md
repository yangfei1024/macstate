# MacState 兼容性说明：闪退问题、基础模式与传感器枚举

> 本文面向用户与开发者，记录 MacState 在部分机型上闪退的完整排查过程、
> 最终解决方案、"基础模式"的含义，以及温度传感器列表的工作原理。
> 更新：2026-09-14（v1.9.9+）

---

## 一、为什么会在某些机器上闪退？

### 根因：GPU 驱动的"遥测"代码有 bug

macOS 的 Metal 框架在 GPU 驱动提交命令缓冲时会收集**遥测数据**
（`createContextTelemetryDataWithQueueLabelAndCallstack`），这个过程中驱动要
格式化"当前调用栈"。在部分驱动的实现里，它把栈上的一个 `NSNumber` 标签指针
误当成 `CFString` 字符串去调用（`-[__NSCFNumber length]: unrecognized selector`）。

ObjC 异常在穿过 `dispatch_once` 的 C++ 帧（noexcept，不允许异常展开）时
会直接 `std::terminate` → **进程 SIGABRT，任何 `@try` 都接不住**。

触发与否取决于**创建瞬间的调用栈内容**（栈上是否恰好有带标签指针样式的
数值），因此具有随机性——同一台机器"时好时坏"，这也是它难排查的原因。

### 已确认中招的机器/驱动组合（真机实锤）

| 机器 | GPU | 驱动栈 | 崩溃触发面 |
|---|---|---|---|
| 2014 Haswell 台式机（i7-4770HQ） | Iris Pro 5200 | `MetalOld.dylib`（macOS 14.7.8） | CoreUI 首次创建共享 CIContext、SwiftUI RenderBox 提交、Core Animation 合成 flush |
| 2019 MacBook Pro（i9-9980HK） | Radeon Pro 5500M | `AMDRadeonX6000MTLDriver`（macOS 26） | NSPopover 呈现、RenderBox 提交（v1.9.6+ 已消除前两者） |

在这类机器上，CoreImage 的 **Metal 后端和 OpenCL 后端都是坏的**
（软件渲染测试同样 10 秒崩在 OpenCL），CoreImage 这条路彻底走不通。

### 曾经的崩溃入口（App 侧触发点）

| 触发点 | 症状 | 修复版本 |
|---|---|---|
| NSPopover（各菜单栏段的气泡提示、5 秒自动刷新的能耗排行） | 点击菜单后闪退 / 放置一段时间后闪退 | v1.9.6：全部改为 NSPanel 浮窗 |
| SwiftUI 设置面板首次布局（CoreUI 形状扁平化 → 首次创建共享 CIContext） | 点设置闪退 | v1.9.4 预热（后被证伪）→ v1.9.9 直通替换 |
| SwiftUI RenderBox 后台渲染 | 打开历史曲线 / 温度面板数秒内崩 | v1.9.9 NSNumber 兼容层 |
| Core Animation 窗口合成（`CA::OGL::MetalContext::flush`） | 高负载下随机闪退（系统级，App 无法完全避免） | v1.9.9 兼容层大幅降低概率；残余风险见下文 |

---

## 二、四层防线（v1.9.9+ 的解决方案）

### 第 1 层：NSNumber 遥测兼容层（治本）

启动最早期给 `NSNumber` 类补上驱动遥测会误用的 3 个占位方法
（`length` / `_getCString:maxLength:encoding:` / `characterAtIndex:`）。
之后无论哪条路径触发遥测误调用，都变成无害返回而不是异常。

- 合法代码不可能对 NSNumber 调这些 NSString 选择器（原本必崩），
  因此不影响任何正常路径
- 覆盖 CoreUI、RenderBox、Core Animation 等**所有** Metal 提交路径

### 第 2 层：fork 子进程探测

启动时 fork 子进程实测 CoreUI 原生 CIContext 创建（连测 3 次，2 秒死锁看护）：

- 全部通过 ⇒ 不做任何干预，原生渲染（Apple Silicon / 健康 Intel / AMD 机器行为不变）
- 任一次崩溃 ⇒ 启用第 3 层

### 第 3 层：CoreUI 扁平化直通替换

用 method swizzle 把 CoreUI 的
`newFlattenedImageFromShapeCGImage:withScale:cache:` 替换为直通实现
（直接返回输入的 shape 图）。渲染控件时 **CoreImage/Metal/OpenCL 代码零执行**，
崩溃面从根上消失。代价仅是控件装饰特效略有差异，基础外观不变。

### 第 4 层：基础模式降级 + 崩溃自学习

- **MetalOld 机器**（Haswell/Broadwell 核显，CPU model 60/63/69/70/61/71）
  从首次启动即进基础模式——SwiftUI 的 RenderBox 管线在这类机器上无法挽救，
  只能整体禁用
- **崩溃自学习**：若当前版本在本机发生过遥测崩溃（扫描崩溃日志特征），
  下次启动自动降级——未知坏组合最多崩一次，之后永久稳定；每个新版本自动重置
- **探针兜底**：其余机器跑 15 轮真实快照渲染实测（`MacStateRenderProbe`
  子进程，崩了只死子进程）

### 手动开关

```bash
# 强制直通渲染（跳过探测，直接启用 CoreUI 安全网）
defaults write com.snail007.macstate ForceSafeCoreUI -bool YES

# 强制基础模式（SwiftUI 界面全部禁用）
defaults write com.snail007.macstate ForceBasicMode -bool YES
```

---

## 三、什么是"基础模式"？

基础模式 = **纯 AppKit 原生渲染的降级 UI**。当兼容性判定认为当前机器的
图形驱动无法安全运行 SwiftUI 时，App 自动切换到这套界面：

| 功能 | 基础模式 | 说明 |
|---|---|---|
| 菜单栏全部指标段 | ✅ 正常 | CPU/核显/网速/独显/内存/电池/限速 |
| 设置面板 | ✅ 原生控件版 | 模块开关 / 功率摘要 / 刷新间隔 / 语言 / 自启动 |
| **历史曲线** | ✅ 原生折线图 | 功率(CPU/GPU/系统)、温度、CPU 负载、限速，1h-3天 |
| **全部温度** | ✅ 原生表格 | 功率摘要头 + 分组温度表（59 键），3 秒刷新 |
| 限速段点击 | ✅ 打开温度+功率面板 | 原生绘制 |
| SwiftUI 完整设置页 | ❌ 不加载 | 基础面板完全替代 |

基础模式的面板全部为纯 AppKit 控件与 NSBezierPath 自绘，
**不经过 CoreImage / Metal / SwiftUI RenderBox**，在坏驱动机器上稳定。

---

## 四、全部温度是每台机器不一样的吗？

**是的，完全动态。** 温度列表不是写死的清单：

1. 打开面板时实时调用 `SMCService.allKeys()` 枚举本机 SMC 的全部键值
   （T2 机型约 1100+ 键，不同机型数量和含义都不同）；
2. 过滤出温度类键（不同机型 30-60 个不等）；
3. 内置目录（`SMCTempCatalog`）只为**已知键**提供中文/英文说明
   （如 TC0E = "CPU 封装 E"、TG0P = "独显近旁"）；
4. 目录里没有的键自动归入"**其他 / 未标注**"分组照常显示实时数值——
   所以在特殊机型或黑苹果上，你也能看到传感器读数，只是名字显示为原始键名。

换言之：换一台 Mac，列表自动变成那台机器自己的传感器集；
已知机型显示友好名称，未知机型显示键名，都不会遗漏。

---

## 五、排查路上踩过的坑（开发者向）

1. **`dispatch_once` 内抛异常无法捕获**：CoreUI 共享 CIContext 走
   `dispatch_once_callout`，C++ 帧是 noexcept 的——`@try`/`@catch` 完全
   无效，直接 terminate。任何"包一层 try"的方案都是自我安慰。
2. **"早期创建"是赌博**：裸进程里创建 CIContext 成功，不代表 App 进程里
   成功（v1.9.4 启动预热在 Iris Pro 机器上启动即崩，有堆栈实锤）。
3. **NSPopover 的呈现层走 RenderBox**：与弹出内容是否 SwiftUI 无关——
   纯 AppKit 内容放在 NSPopover 里照样触发。排查时"换个内容试试"会被误导。
4. **cacheDisplay 截图对 SwiftUI 不忠实**（文字丢失、开关位置失真）；
   `ImageRenderer` 在无窗口上下文时输出全黑。离屏验证优先用真实窗口 +
   AX 树 dump（但 NSPopover 不在 `kAXWindowsAttribute` 列表里）。
5. **fork 后在子进程调 NSUserDefaults / os_log** 可能 SIGSEGV
   （`_os_log_preferences_refresh`），产生与产品无关的崩溃报告噪音——
   探测子进程挂起时要果断 SIGKILL，不能等它自然死。
6. **NSSwitch 在 macOS 26 的实际尺寸是 54×24**，按老经验给 38×22 的
   frame 会把开关裁掉一截。
7. **swiftc 多文件模式下 `main.swift` 顶层语句**只在文件名为 main.swift
   时允许，且传参顺序敏感；`@main` 结构体更稳妥。
8. **swiftc 传入的 .o 目标架构必须与 -target 一致**，否则链接期才报错。
9. **崩溃日志的 `app_version` 自学习过滤**：修复后必须递增版本号，否则
   旧版本的崩溃日志会把新版本也压进基础模式。

---

## 六、复现与验证工具

- 自测环境变量：
  - `MACSTATE_FORCE_BASIC=1` 强制基础模式
  - `MACSTATE_ALLOW_SWIFTUI=1` 跳过黑名单仅用探针
  - `MACSTATE_STRESS_ALL=1` 菜单栏全段轮点压测
  - `MACSTATE_AUTO_CYCLE_SETTINGS=1` 设置面板自动开合
- 独立探针：`MacState.app/Contents/MacOS/MacStateRenderProbe`
  直接运行，输出 `PROBE-OK` 即判定 SwiftUI 安全。
- 崩溃日志：`~/Library/Logs/DiagnosticReports/MacState-*.ips`
  （faultingThread 里的 `getCStringForCFString` 即本文所述驱动遥测特征）。
