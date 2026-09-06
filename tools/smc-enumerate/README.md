# SMC 全键枚举工具

读取本机 SMC 全部 1164 个键，输出可解码的数值（温度/电压/电流/功率/风扇等）。

## 编译运行

```bash
cd tools/smc-enumerate
swiftc -O main.swift -o /tmp/smc_enum && /tmp/smc_enum
# 结果写入 /tmp/smc_all_keys.txt：key \ type \ size \ value
```

- 无需 root，走 AppleSMC 用户客户端（IOServiceOpen type 0，selector 2）。
- 结构体布局与 `MacState/Core/SMCService.swift` 完全一致。

## 关键坑（2026-09-06 实测，macOS 26.5.1）

内核要求的 `SMCKeyData` 是 **80 字节紧排布局**。Swift 对纯 Swift struct
按声明顺序紧排，`MemoryLayout<SMCKeyData>.stride == 80`，工作正常；
同样的字段在 C 里按自然对齐会得到 84 字节（pLimitData 里的 uint32 被
对齐到 4 字节边界，整体后移），调用全部返回 `kIOReturnNotFound
(0xe00002c2)`，看起来像"系统封禁"，实际是布局错位。用 C 实现时必须
手工按 80 字节紧排（`__attribute__((packed))` + 手工 padding）。

## MacState 复用

`SMCService.readKey(_:)` 已经可以读任意键，例如：

```swift
SMCService.shared.readKey("TPCD")  // PCH 温度
```

传感器键位清单见 `docs/smc-sensors.md`，原始快照见
`docs/smc-all-keys-20260906.txt`。
