#!/usr/bin/env bash
# 构建一加 15 (SM8850/canoe, Android 16) 自定义内核，产出可刷的 vendor_boot.img。
#
# 为什么内核在 vendor_boot.img（不是 boot.img）：
#   - canoe_perf 的 kernel_images 配置 build_vendor_boot=True、build_boot 未设(默认 False)、
#     build_vendor_kernel_boot=False → 只产出 vendor_boot.img（含厂商内核 Image + vendor
#     ramdisk + DTB），不产出 boot.img。
#   - 官方设备的运行内核就是 vendor_boot.img 里的"厂商内核"（OKI GKI：gki_defconfig +
#     qcom/oplus fragment + WALT，build.config.msm.perf 设 BUILD_BOOT_IMG=1 但 Kleaf 用它生成
#     vendor_boot 里的内核）。boot 分区只是纯 AOSP GKI 合规镜像，不承载运行内核。
#
# 为什么必须用厂商内核(带 WALT)，而不是纯 AOSP GKI：
#   - 风驰内核调速器(HMBIRD II) 是 sched_ext BPF 调度器(hmbird_II + hmbird_II_freqgov)，
#     运行时依赖内核的 WALT 负载统计。WALT 只在厂商内核(msm-kernel)里，纯 AOSP GKI(common)
#     没有。cctv18 的 GKI 分支/用 android_gki_kernel_common 编译的 Image 都不带 WALT——
#     刷这类内核到 vendor_boot 时，风驰模块(sched-walt/sched_assist/sched_ext)虽能加载，
#     但频率治理因缺 WALT 统计而不生效，即"有但不工作"。
#
# 保留官方 vendor_dlkm：风驰链模块在官方 vendor_dlkm，本内核与官方同分支同配置构建，KMI
# 匹配，官方模块直接加载并正常工作。
#
# 为什么只编这个目标：
#   - //msm-kernel:canoe_perf_images 只依赖厂商内核本身，绕开 oplus 模块图：108 个未开源
#     模块缺失不再影响构建（define_oplus_ddk_modules 的目标在加载期被定义但从不被分析）。
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

echo "Building //msm-kernel:canoe_perf_images (vendor_boot.img = 厂商内核/OKI GKI, 含WALT)" | tee ../../logs/build-status.txt
bazel build //msm-kernel:canoe_perf_images 2>&1 | tee ../../logs/build.log

# 厂商内核 vendor_boot.img 位于 canoe_perf_images_boot_images/，默认输出组即包含
VB_IMG="$(find "$PWD/bazel-bin" "$PWD/bazel-out" -name 'vendor_boot.img' -path '*canoe*' 2>/dev/null | head -1)"
if [[ -z "$VB_IMG" || ! -f "$VB_IMG" ]]; then
  echo "error: 未找到 vendor_boot.img 产物，请检查 logs/build.log" >&2
  find "$PWD/bazel-bin" -name '*.img' -path '*canoe*' 2>/dev/null | head -30 || true
  exit 1
fi
cp "$VB_IMG" ../../artifacts/vendor_boot.img
echo "vendor_boot.img (厂商内核/OKI GKI, 含WALT) -> artifacts/vendor_boot.img ($(du -h ../../artifacts/vendor_boot.img | cut -f1))"

# 附加说明产物（便于排查/验证）
DIST_IMG="$(find "$PWD" -name 'init_boot.img' -path '*dist*' 2>/dev/null | head -1)"
if [[ -n "$DIST_IMG" && -f "$DIST_IMG" ]]; then
  cp "$DIST_IMG" ../../artifacts/init_boot.img 2>/dev/null || true
  echo "init_boot.img -> artifacts/init_boot.img (参考)"
fi

find ../../artifacts -type f -printf '%P\n' | sort | tee ../../logs/artifacts.txt
