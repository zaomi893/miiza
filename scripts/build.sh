#!/usr/bin/env bash
# 构建一加 15 (SM8850/canoe, Android 16) 自定义内核，产出两个可刷镜像：
#   boot.img       —— 厂商内核(带 WALT 的 OKI GKI) 的 boot 镜像，刷入 boot 分区
#   vendor_boot.img—— 同源厂商内核 + vendor ramdisk + DTB，刷入 vendor_boot 分区
#
# 为什么必须用厂商内核(boot.img)，而不是纯 AOSP GKI：
#   - 风驰内核调速器(HMBIRD II) 是 sched_ext BPF 调度器(hmbird_II + hmbird_II_freqgov)，
#     运行时依赖内核的 WALT 负载统计。WALT 只在厂商内核(msm-kernel, build.config.msm.perf
#     + gki_defconfig + qcom/oplus fragment)里，纯 AOSP GKI(common) 没有 → 刷纯 GKI 时
#     风驰模块能加载但频率治理不生效("有但不工作")。
#   - 官方 boot.img 就是带 WALT 的厂商内核(OKI GKI)。cctv18 的 GKI 分支、以及用
#     android_gki_kernel_common(纯 AOSP) 编译的内核都不带 WALT，这就是刷它们风驰失效的原因。
#
# 保留官方 vendor_dlkm：风驰链的 sched-walt/sched_assist/sched_ext 模块在官方 vendor_dlkm，
# 本内核与官方同分支同配置构建，KMI 匹配，官方模块直接加载。
#
# 为什么只编内核目标：
#   - 厂商内核 boot.img 来自 //msm-kernel:canoe_perf_dtb_build 的 gki_artifacts 输出组
#     (build.config.msm.perf 设 BUILD_BOOT_IMG=1)。
#   - vendor_boot.img 来自 //msm-kernel:canoe_perf_images (build_vendor_boot=True)。
#   - 两者都只依赖厂商内核本身，绕开 oplus 模块图：108 个未开源模块缺失不再影响构建
#     (define_oplus_ddk_modules 的目标在加载期被定义但从不被分析)。
set -euo pipefail
cd source/kernel_platform
mkdir -p ../../artifacts ../../logs
BAZEL_CACHE_ARGS=()
if [[ -n "${BAZEL_REPOSITORY_CACHE:-}" ]]; then
  mkdir -p "$BAZEL_REPOSITORY_CACHE"
  BAZEL_CACHE_ARGS+=(--repository_cache="$BAZEL_REPOSITORY_CACHE")
fi
if [[ -n "${BAZEL_DISK_CACHE:-}" ]]; then
  mkdir -p "$BAZEL_DISK_CACHE"
  BAZEL_CACHE_ARGS+=(--disk_cache="$BAZEL_DISK_CACHE")
fi
bazel() {
  local command="$1"
  shift
  # repository_cache is a command option, not a Bazel startup option.
  ./tools/bazel "$command" "${BAZEL_CACHE_ARGS[@]}" "$@"
}

# 保留 Canoe 标签用于诊断
bazel query '//msm-kernel:all' 2>&1 | tee ../../logs/bazel-targets-all.log | grep -E '^//msm-kernel:canoe' | tee ../../logs/bazel-targets.log

# ========== 1) 厂商内核 boot.img (gki_artifacts 输出组) ==========
echo "Building //msm-kernel:canoe_perf_dtb_build --output_groups=gki_artifacts (kernel boot.img)" | tee ../../logs/build-status.txt
bazel build --output_groups=gki_artifacts //msm-kernel:canoe_perf_dtb_build 2>&1 | tee ../../logs/build-boot.log
BOOT_IMG="$(find "$PWD/bazel-bin" "$PWD/bazel-out" -name 'boot.img' -path '*canoe_perf*' 2>/dev/null | head -1)"
if [[ -z "$BOOT_IMG" || ! -f "$BOOT_IMG" ]]; then
  echo "error: gki_artifacts 未产出 boot.img；列出相关产物供排查" >&2
  find "$PWD/bazel-bin" -name 'boot*' 2>/dev/null | head -30 || true
  find "$PWD/bazel-bin" -name '*.img' -path '*canoe*' 2>/dev/null | head -30 || true
  exit 1
fi
cp "$BOOT_IMG" ../../artifacts/boot.img
echo "boot.img (厂商内核/OKI GKI) -> artifacts/boot.img ($(du -h ../../artifacts/boot.img | cut -f1))"

# ========== 2) vendor_boot.img (内核+ramdisk+DTB，兼容启动布局) ==========
echo "Building //msm-kernel:canoe_perf_images (vendor_boot.img)" | tee -a ../../logs/build-status.txt
bazel build //msm-kernel:canoe_perf_images 2>&1 | tee -a ../../logs/build.log
VB_IMG="$(find "$PWD/bazel-bin" "$PWD/bazel-out" -name 'vendor_boot.img' -path '*canoe*' 2>/dev/null | head -1)"
if [[ -z "$VB_IMG" || ! -f "$VB_IMG" ]]; then
  echo "warning: 未找到 vendor_boot.img（不影响 boot.img 主产物）" | tee -a ../../logs/build.log
else
  cp "$VB_IMG" ../../artifacts/vendor_boot.img
  echo "vendor_boot.img -> artifacts/vendor_boot.img ($(du -h ../../artifacts/vendor_boot.img | cut -f1))"
fi

find ../../artifacts -type f -printf '%P\n' | sort | tee ../../logs/artifacts.txt
