#!/usr/bin/env bash
# 只编内核 boot.img：官方 vendor_dlkm / vendor_boot 保留不动（风驰内核调速器在官方 vendor_dlkm 中）。
#
# 为什么只编内核：
#   - 风驰内核调速器(HMBIRD II) 的 sched-walt/sched_assist/sched_ext 模块都在官方 vendor_dlkm 里，
#     一加 15 出厂自带。本仓库与官方同分支(oneplus/sm8850_b_16.0.0_oneplus_15)同配置构建内核，
#     KMI 匹配，官方模块可直接加载，无需重建 vendor 模块。
#   - 只编 //msm-kernel:canoe_perf_images（内核+boot.img），绕开 oplus 模块图，
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

echo "Building //msm-kernel:canoe_perf_images (kernel + boot.img only)" | tee ../../logs/build-status.txt
bazel build //msm-kernel:canoe_perf_images 2>&1 | tee ../../logs/build.log
# kernel_images 的默认输出组不一定包含 boot.img，必要时显式请求 boot_img 输出组
BOOT_IMG="$(find "$PWD/bazel-bin" "$PWD/bazel-out" -name 'boot.img' -path '*canoe*' 2>/dev/null | head -1)"
if [[ -z "$BOOT_IMG" ]]; then
  echo "boot.img not in default outputs; requesting boot_img output group" | tee -a ../../logs/build.log
  bazel build --output_groups=boot_img //msm-kernel:canoe_perf_images 2>&1 | tee -a ../../logs/build.log
  BOOT_IMG="$(find "$PWD/bazel-bin" "$PWD/bazel-out" -name 'boot.img' -path '*canoe*' 2>/dev/null | head -1)"
fi
if [[ -z "$BOOT_IMG" || ! -f "$BOOT_IMG" ]]; then
  echo "error: 未找到 boot.img 产物，请检查 logs/build.log" >&2
  find "$PWD/bazel-bin" -name '*.img' 2>/dev/null | head -20 || true
  exit 1
fi
cp "$BOOT_IMG" ../../artifacts/boot.img
echo "boot.img 已生成 -> artifacts/boot.img ($(du -h ../../artifacts/boot.img | cut -f1))"
find ../../artifacts -type f -printf '%P\n' | sort | tee ../../logs/artifacts.txt
