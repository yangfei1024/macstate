# MacBookPro16,1 SMC 传感器清单（2026-09-06 实测）

机型：MacBookPro16,1（i9-9980HK 8C16T，UHD630 + Radeon Pro 5500M，T2）
系统：macOS 26.5.1（Tahoe）
采样时为中等负载：8 核 64–66°C，双风扇约 4700/4350 rpm，室温约 24°C。

SMC 共 1164 个键，841 个返回数值。下表为全部温度键（50 个）与供电电气量。

标注说明：✅ = 社区通用命名（TG Pro / iStat Menus / stats 等一致），
推断 = 按 Apple 命名惯例推断，未在公开清单中确证。

## CPU（11）

| 键 | 采样值 | 含义 |
|---|---|---|
| TC1C–TC8C | 64–66°C | ✅ CPU 核心 1–8（PECI，每核一个） |
| TC0P | 57.2°C | ✅ CPU 近旁 proximity（散热器/供电区侧） |
| TC0E | 66.6°C | ✅ CPU 封装二极管（E） |
| TC0F | 68.4°C | ✅ CPU 封装二极管（F，滤波值） |
| TCSA | 66.0°C | ✅ CPU System Agent（uncore/SA） |
| TCGC | 64.0°C | ✅ CPU 内 iGPU 核心温度（UHD630 die） |
| TCMX | 66.3°C | 推断 CPU 最热核（max） |
| TCXC | 66.3°C | 推断 CPU 复合体 max（与 TCMX 同值） |
| TC0T | −0.08 | 推断 非传感器：PECI 温度偏移/补偿量 |

## GPU（dGPU 5500M 与供电区，7）

| 键 | 采样值 | 含义 |
|---|---|---|
| TGDD | 64.0°C | ✅ GPU die 数字二极管 |
| TGDE | 56.0°C | 推断 GPU 二极管 E |
| TGDF | 65.3°C | 推断 GPU 二极管 F |
| TG0P | 60.2°C | ✅ GPU 近旁 proximity |
| TG1P | 64.1°C | 推断 GPU 第二 proximity |
| TGVP | 61.9°C | 推断 GPU VRM/供电区（V=电压调整器） |
| TGVF | 61.9°C | 推断 GPU VRM 滤波值 |
| TGDT | 0.02 | 未挂载/无效 |

## PCH / 主板 / 内存（5）

| 键 | 采样值 | 含义 |
|---|---|---|
| TPCD | 63.0°C | ✅ PCH die（芯片组，powermetrics 的 "PCH die"） |
| TM0P | 61.3°C | ✅ 内存（DIMM 区）proximity |
| Tm0P | 60.8°C | ✅ 主板 proximity |
| TW0P | 56.4°C | ✅ 无线网卡（WiFi 模组）proximity |
| TTLD / TTRD | 38.4 / 54.5°C | 推断 Thunderbolt/USB-C 左/右控制器 |

## 电池（3）

| 键 | 采样值 | 含义 |
|---|---|---|
| TB0T | 35.4°C | ✅ 电池温度（与 AppleSmartBattery "Temperature"=3086（0.1K）=35.4°C 互证） |
| TB1T | 34.5°C | ✅ 电池电芯温度 2 |
| TB2T | 35.4°C | ✅ 电池电芯温度 3 |

## 外壳 / 掌托 / 风道（14）

| 键 | 采样值 | 含义 |
|---|---|---|
| Ts0P | 36.0°C | ✅ 掌托 proximity（左） |
| Ts1P | 33.0°C | 推断 掌托 proximity（右） |
| Ts0S / Ts1S / Ts2S | 43.9 / 43.3 / 43.3°C | 推断 外壳皮肤（skin）测点 |
| TaLC / TaRC | 39.1 / 48.1°C | 推断 左/右侧接口（USB-C/TB3）区域 |
| Th1H / Th2H | 58.1 / 55.6°C | ✅ 散热器热管区 1/2（H=heatsink） |
| TH0F / TH0X | 42.7 / 42.8°C | 推断 风道/出风区 |
| TH0a / TH0b / TH1a / TH1b | 37.3–42.8°C | 推断 风扇进风区热敏 a/b |
| TA0V | 24.2°C | ✅ 环境空气温度（≈室温） |
| TF0S | 6.8 | 未知辅助量（非典型温度范围，存疑） |

## 供电链路电气量（VRM/电源管理相关，均 'flt '）

温度键之外，供电链路的电压/电流/功率是全的，可用来推 VRM 损耗：

| 键 | 采样值 | 含义 |
|---|---|---|
| VD0R / ID0R | 19.24 V / 3.89 A | ✅ DC-in 适配器输入（19.24×3.89≈74.8W=PDTR，互证） |
| VP0R | 12.56 V | ✅ 12V 主轨 |
| PDTR / PSTR | 74.7 W / 78.1 W | ✅ 供电总功率（Delivery/Supply Total） |
| VCAC | 0.93 V | 推断 CPU Vcore 电压 |
| IC0R | 2.63 A | 推断 CPU 电流 |
| PC0R / PZ0F / PZ0E | 33.0 / 56.9 / 82.0 W | 推断 CPU/功耗域功率（多口径） |
| VG0C / VG1C | 0.73 / 0.78 V | 推断 GPU VDD 电压 |
| IG0R / PG0R | 1.86 A / 23.3 W | GPU 电流/功率（1.86×12.56≈23.4W，互证） |
| IM0C | 3.40 A | 推断 内存电流 |
| IBAC / IBAF | 0.14 / 0.20 A | 推断 电池充/放电电流 |
| PCPC / PCPG / PCPT | 18.2 / 1.4 / 22.9（sp87） | 未确证（PECI 系口径） |

## 风扇（2 个）

| 键 | 采样值 | 含义 |
|---|---|---|
| F0Ac / F1Ac | 4710 / 4347 rpm | ✅ 左/右风扇当前转速 |
| F0Mn/F0Mx/F1Mn/F1Mx | 1836–5616 | ✅ 转速范围 |

## SMC 之外的传感器

- 电池：`ioreg -rn AppleSmartBattery` 的 `Temperature`（0.1K 单位），与 TB0T 一致。
- NVMe SSD（APPLE SSD AP0512N）：SMC 未暴露键；`system_profiler SPNVMeDataType`
  在本机不显示温度，需 `smartctl -a /dev/disk0`（brew install smartmontools）读 SMART。
- iGPU：`sysctl debug.intelfb.temp0-4` 存在但恒为 0（未填充）。

## 结论：VRM / PMIC 覆盖情况

1. **没有** per-phase VRM 结温键，**没有** PMIC（电源管理芯片）结温键——
   T2/SMC 内部监测它们但不通过键值暴露，任何工具（TG Pro/iStat/stats）都读不到。
2. 最接近的代理：TC0P（CPU 供电区近旁）、TGVP/TGVF（GPU VRM 区）、
   Tm0P/TM0P（主板/内存区）、Th1H/Th2H（热管）。
3. VRM 健康可用电气量间接评估：Vcore(VCAC)×电流、输入/输出功率差
   （PDTR − 各域功率）≈ 供电链路损耗。
4. MacState 读数即来自 `SMCService`（本仓库 `Core/SMCService.swift`），
   已有 `readKey(_:)` 可直接扩展显示以上任意键。

## 复现

```bash
cd tools/smc-enumerate && swiftc -O main.swift -o /tmp/smc_enum && /tmp/smc_enum
```

原始全量快照：`docs/smc-all-keys-20260906.txt`（key \ type \ size \ value）。
