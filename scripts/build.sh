#!/usr/bin/env bash
# 构建一加 15 (SM8850/canoe, Android 16) 自定义 GKI 内核，产出可刷的 boot 分区内核 Image。
#
# 为什么构建 //common:kernel_aarch64（OnePlus common GKI），而不是 msm-kernel：
#   - 官方 boot.img 就是 OnePlus common 分支（gki_defconfig, CONFIG_SCHED_CLASS_EXT=y）构建
#     的 GKI 内核（官方版本 6.12.23-android16-5-gb2a876903b49-ab14541642-4k，Kleaf 构建，
#     无 oplus 标记）。本构建与官方 boot.img 同源码（同一官方分支）同 defconfig。
#   - 风驰(HMBIRD II) 是 sched_ext BPF 调度器，由 ColorOS 用户态服务运行时加载，只需内核
#     提供 sched_ext(CONFIG_SCHED_CLASS_EXT=y)。官方 boot GKI 具备，故风驰正常。
#   - 纯 AOSP common（cctv18 GKI 版用 android_gki_kernel_common）与官方 GKI 存在 OnePlus
#     私有补丁/版本差异，风驰"有但不工作"。用官方 OnePlus common 分支即可复现官方行为。
#   - 刷 boot 分区内核(Image)，保留官方 init_boot / vendor_boot / vendor_dlkm。
#
# 为什么不走 msm-kernel(canoe_perf)：canoe_perf 是厂商内核(OKI GKI, 含 oplus/WALT)，产物是
# vendor_boot.img，与官方 boot.img(GKI) 不是同一回事；用户设备运行/刷写的是 boot 分区 GKI。
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
  ./tools/bazel "$command" "${BAZEL_CACHE_ARGS[@]}" "$@"
}
# 保留诊断信息（grep 无匹配不阻断构建）
bazel query '//common:all' 2>&1 | tee ../../logs/bazel-targets-all.log | grep -E 'kernel_aarch64' | tee ../../logs/bazel-targets.log || true
echo "Building //common:kernel_aarch64 (OnePlus common GKI, 含 sched_ext = 风驰可用)" | tee ../../logs/build-status.txt
bazel build //common:kernel_aarch64 2>&1 | tee ../../logs/build.log
# 取内核 Image（bazel-bin 是符号链接，普通 find 不跟随，用 find -L 兜底）
IMAGE="$(find -L "$PWD/bazel-bin/common" -type f -name 'Image' -path '*kernel_aarch64*' 2>/dev/null | head -1)"
if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
  echo "error: 未找到 Image 产物，请检查 logs/build.log" >&2
  find -L "$PWD/bazel-bin/common" -maxdepth 4 -type f 2>/dev/null | head -40 || true
  exit 1
fi
cp "$IMAGE" ../../artifacts/Image
echo "Image (OnePlus common GKI, 含 sched_ext) -> artifacts/Image ($(du -h ../../artifacts/Image | cut -f1))"
# 取 GKI boot.img（含 GKI ramdisk，供参考/验证；刷机只用 Image，保留官方 init_boot）
BOOT_IMG="$(find -L "$PWD/bazel-bin/common" -type f -name 'boot.img' -path '*kernel_aarch64*' 2>/dev/null | head -1)"
if [[ -n "$BOOT_IMG" && -f "$BOOT_IMG" ]]; then
  cp "$BOOT_IMG" ../../artifacts/boot.img
  echo "boot.img (参考) -> artifacts/boot.img ($(du -h ../../artifacts/boot.img | cut -f1))"
fi
# 输出内核版本（验证与官方 boot.img 同源/兼容）
if command -v strings >/dev/null 2>&1; then
  VER="$(strings -a "$IMAGE" 2>/dev/null | grep -a -m1 'Linux version' || true)"
  echo "内核版本: $VER" | tee ../../logs/kernel-version.txt
fi
find ../../artifacts -type f -printf '%P\n' | sort | tee ../../logs/artifacts.txt
