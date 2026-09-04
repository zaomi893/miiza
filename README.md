# OnePlus SM8850 HMBIRD II Builder
一加 15（SM8850/canoe）Android 16 **只编 GKI 内核**构建项目：从官方 OnePlus common 分支构建
自定义 **boot 分区内核（Image）**，**保留官方 init_boot / vendor_boot / vendor_dlkm 全部不动**。
风驰内核调速器（HMBIRD II）由 ColorOS 用户态服务运行时加载的 **sched_ext BPF 调度器**，
只需内核提供 `CONFIG_SCHED_CLASS_EXT=y`，官方 boot GKI 即具备。
Actions 中运行 **Build OnePlus 15 HMBIRD kernel**。流程：同步组装官方源码 → 校验风驰内核源码链路 →
Kleaf 构建 `//common:kernel_aarch64`（OnePlus common GKI，含 sched_ext）→ 打包为可刷 boot 的 zip。
## 为什么构建 OnePlus common GKI（不是 msm-kernel 厂商内核）
- **官方 boot.img 就是 OnePlus common 分支构建的 GKI 内核**（版本 `6.12.23-android16-5-gb2a876903b49-ab14541642-4k`，
  Kleaf 构建、无 oplus 标记）。用户刷 cctv18 到 boot 分区会替换运行内核（风驰"有但不工作"），
  证明**运行内核在 boot 分区**。
- 风驰（HMBIRD II）是 sched_ext BPF 调度器，官方 boot GKI（`CONFIG_SCHED_CLASS_EXT=y`）即可运行。
- **纯 AOSP common**（cctv18 GKI 版用 `android_gki_kernel_common`）与官方 GKI 存在 OnePlus 私有
  补丁/版本差异 → 风驰"有但不工作"。用**官方 OnePlus common 分支**（`oneplus/sm8850_b_16.0.0_oneplus_15`）
  构建即可复现官方行为，风驰正常工作。
- 之前的 msm-kernel（`canoe_perf`）路线产出 vendor_boot.img（厂商内核/OKI GKI），与官方 boot.img
  （GKI）不是同一回事，方向已修正。
## 刷入内容
- **boot** ← `artifacts/Image`（OnePlus common GKI 内核，含 sched_ext）
- **保留官方** init_boot（GKI ramdisk）/ vendor_boot / vendor_dlkm（全部不动）
## 构建流程
```
assemble.sh            同步三个官方仓库到统一分支（common + msm-kernel + modules/devicetree）
check_hmbird.sh        校验风驰内核源码链路（sched_ext/hmbird_II_freqgov 齐全）
build.sh               Kleaf 构建 //common:kernel_aarch64 -> artifacts/Image（含 sched_ext）
package.sh             打包 Image -> oneplus15-hmbird2-*.zip（AnyKernel3，只刷 boot 内核）
```
## 刷机（scripts/package.sh）
构建成功后运行 `bash scripts/package.sh artifacts <name>.zip`，产出只刷 **boot 内核(Image)** 的 AnyKernel3 zip。
**不刷 init_boot / vendor_boot / vendor_dlkm**，三者保留官方原厂。
刷入前提：**Bootloader 已解锁**（一加 15 解锁后为 Orange State）。两种方式任选：
- **自定义 Recovery / KernelSU Flasher**：直接刷入生成的 `oneplus15-hmbird2-*.zip`。
- **fastboot 直刷**（等价）：`fastboot flash boot boot.img`（用 artifacts/boot.img）。
## 风险与缺口
- 本内核与官方 boot.img 同源码分支（OnePlus common）同 defconfig，配置等价；但官方 boot.img 为
  较早 commit（`2a876903b49`），本构建使用分支最新 HEAD，代码有后续同步。若遇兼容问题可 checkout
  官方 boot.img 对应 commit 重新构建。
- boot 内核用 AOSP 测试密钥签名（AVB testkey），仅限已解锁 Bootloader 使用。
