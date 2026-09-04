#!/usr/bin/env bash
# 只编内核：canoe_perf_images 产出的 vendor_boot.img 内含内核 Image（该机型内核在
# vendor_boot 分区，非 boot 分区——kernel_images 配置 build_vendor_boot=True 且无
# boot_img）。官方 vendor_dlkm 保留不动（风驰内核调速器 sched-walt/sched_assist/
# sched_ext 模块在官方 vendor_dlkm 中）。
#
# 为什么只编内核：
#   - 风驰内核调速器(HMBIRD II) 的 sched-walt/sched_assist/sched_ext 模块都在官方
#     vendor_dlkm 里，一加 15 出厂自带。本仓库与官方同分支
#     (oneplus/sm8850_b_16.0.0_oneplus_15)同配置构建内核，KMI 匹配，官方模块可直接
#     加载，无需重建 vendor 模块。
#   - 只编 //msm-kernel:canoe_perf_images（内核+vendor_boot.img），绕开 oplus 模块图，
#     108 个未开源模块缺失的问题不再影响构建。
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

echo "Building //msm-kernel:canoe_perf_images (kernel + vendor_boot.img)" | tee ../../logs/build-status.txt
bazel build //msm-kernel:canoe_perf_images 2>&1 | tee ../../logs/build.log
# 该机型内核在 vendor_boot 分区（build_vendor_boot=True，无 boot_img）。产物位于
# canoe_perf_images_boot_images/vendor_boot.img；默认输出组即包含它。
BOOT_IMG="$(find "$PWD/bazel-bin" "$PWD/bazel-out" -name 'vendor_boot.img' -path '*canoe*' 2>/dev/null | head -1)"
if [[ -z "$BOOT_IMG" ]]; then
  echo "vendor_boot.img not in default outputs; listing available images" | tee -a ../../logs/build.log
  find "$PWD/bazel-bin" -name '*.img' 2>/dev/null | head -30 || true
  exit 1
fi
if [[ ! -f "$BOOT_IMG" ]]; then
  echo "error: 未找到 vendor_boot.img 产物，请检查 logs/build.log" >&2
  exit 1
fi
cp "$BOOT_IMG" ../../artifacts/vendor_boot.img
echo "vendor_boot.img 已生成 -> artifacts/vendor_boot.img ($(du -h ../../artifacts/vendor_boot.img | cut -f1))"
find ../../artifacts -type f -printf '%P\n' | sort | tee ../../logs/artifacts.txt
