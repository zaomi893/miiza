# OnePlus SM8850 HMBIRD II Builder
一加 15（SM8850/canoe）Android 16 **只编内核**构建项目：从官方源码构建自定义 boot.img（内核），
**保留官方 vendor_dlkm / vendor_boot 不动**——风驰内核调速器（HMBIRD II）的完整依赖链
（`sched-walt.ko` → `oplus_bsp_sched_assist.ko` → `oplus_bsp_sched_ext.ko`，含 `hmbird_II_freqgov` 频率治理）
就在官方 vendor_dlkm 里，一加 15 出厂自带。本仓库与官方同分支同配置构建内核，KMI 匹配，
官方模块可直接加载，因此**无需重建任何 vendor 模块**。

三个源码仓库必须使用同一分支：`oneplus/sm8850_b_16.0.0_oneplus_15`。

Actions 中运行 **Build OnePlus 15 HMBIRD kernel**。流程：同步组装官方源码 → 校验风驰内核源码链路 →
Kleaf 构建 `//msm-kernel:canoe_perf_images`（内核 + boot.img，绕开 oplus 模块图）→ 打包为可刷 zip。

## 为什么只编内核、不重编 vendor_dlkm（关键决策）
风驰内核调速器（`hmbird_II_freqgov.c`）编译在 `oplus_bsp_sched_ext.ko` 内，依赖链为
`sched-walt.ko`（WALT 调度器，来自 msm-kernel `kernel/sched/walt/`）← `oplus_bsp_sched_assist.ko` ← `oplus_bsp_sched_ext.ko`。
OnePlus common 是纯净 AOSP GKI（`kernel/sched/sched.h` 0 处 WALT 引用、无 walt 目录、gki_defconfig 无 `CONFIG_SCHED_WALT`），
WALT 以独立模块 `sched-walt.ko` 存在于 msm-kernel（`canoe_perf.bzl` 已设 `CONFIG_SCHED_WALT=m`）。

因此**纯 GKI（只编 common + gki_defconfig）物理上无法运行风驰内核**——内核缺 WALT 符号，sched_assist 无法编译/链接。
要保留风驰内核调速器，必须用与官方一致的完整设备内核配置（common + msm-kernel 的 WALT + oplus 调度配置）。

而官方 vendor_dlkm / vendor_boot 本来就在手机上、且已含完整风驰链路。只要：
1. 用 `canoe_perf` 配置（与官方一致）构建内核 → KMI / 内核版本与官方模块匹配；
2. 只刷 boot.img，保留官方 vendor_dlkm / vendor_boot。

风驰内核调速器就能继续工作，且完全绕开"108 个 oplus 模块未开源"的构建阻塞（那是重编 vendor_dlkm 才需要面对的问题）。

## 为什么之前一直失败（2026-09-04 诊断结论，历史背景）
原方案（`canoe_perf_dist` 全量构建）会拉取全部 oplus DDK 模块。OnePlus 公开源码只发布了
`vendor/oplus/kernel/` 的 audio / boot / camera / charger / cpu / device_info 六族，而聚合目标
`kernel_platform/oplus/bazel/oplus_modules.bzl` 仍列出约 130 个 oplus 目标，其中约 108 个指向公开仓库里
**不存在**的包（dfr、dft、mm、network、storage、synchronize、touchpanel、tp、vibrator、wifi、sensor、nfc、ipc、
graphics、hans、power、secure 等）。任何拉取 `*_all_oplus_ddk_modules_files` 的目标都会在 Bazel 分析期以
`no such package` 失败。另一个依赖：`oplus_bsp_sched_ext` 的 ko_deps 依赖专有的
`vendor/oplus/kernel/synchronize:oplus_locking_strategy`。
**这些只影响全量 vendor_dlkm 构建；boot-only 路线（`canoe_perf_images`）不受影响。**

## 构建流程
```
assemble.sh            同步三个官方仓库到统一分支（common + msm-kernel + modules/devicetree）
check_hmbird.sh        校验风驰内核源码链路（WALT/sched_assist/sched_ext/hmbird_II_freqgov 齐全）
build.sh               Kleaf 构建 //msm-kernel:canoe_perf_images -> artifacts/boot.img
package.sh             打包 boot.img -> oneplus15-hmbird2-*.zip（AnyKernel3，只刷 boot）
```

## 刷机（scripts/package.sh）
构建成功后运行 `bash scripts/package.sh artifacts <name>.zip`，产出只刷 **boot.img** 的 AnyKernel3 zip。
**不刷 vendor_dlkm / vendor_boot / dtbo**，全部保留官方原厂（风驰内核调速器在官方 vendor_dlkm 中）。

刷入前提：**Bootloader 已解锁**（一加 15 解锁后为 Orange State）。两种方式任选：
- **自定义 Recovery / KernelSU Flasher**：直接刷入生成的 `oneplus15-hmbird2-*.zip`。
- **fastboot 直刷**（等价）：`fastboot flash boot boot.img`。

## 备用：完整 vendor_dlkm 构建（scripts/trim_public_oplus.py）
如果确需从公开源码重建完整 vendor_dlkm（不依赖官方分区），`scripts/trim_public_oplus.py`
（assemble.sh 末尾自动执行）把模块图裁剪为公开存在的包，移除 synchronize 依赖：
1. `oplus_modules.bzl`：仅保留包目录真实存在的目标，移除 `wifi:wonder`、`dfr:oplus_inject*`、`sensor:pseudo_sensor` 等缺失引用。
2. `oplus_local_modules.bzl`：从 `sched_ext_ko_deps` 移除 `//vendor/oplus/kernel/synchronize:oplus_locking_strategy`
   （经核实为可选运行时钩子，公开源码无符号引用，移除后模块仍可编译链接，仅锁定保护不生效）。
3. `charger/v1、v2/modules.bzl`：移除指向缺失 touchpanel / dft 的引用。
此路线需把 build.sh 目标改回 `//msm-kernel:canoe_perf_dist`。

## 仍未覆盖的缺口
- 内核与官方模块的 KMI 匹配依赖同一分支同一配置；若官方 vendor_dlkm 与所选分支版本不一致，模块可能无法加载。
- boot.img 用 AOSP 测试密钥签名（AVB testkey），仅限已解锁 Bootloader 使用。
- 其余 Kleaf 构建期问题（如 Kconfig 去重、NDK 稀疏检出等）沿用仓库既有补丁。
