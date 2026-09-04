#!/usr/bin/env bash
set -euo pipefail
cd source
req=(
 vendor/oplus/kernel/cpu/sched_ext/hmbird_II/hmbird_II.c
 vendor/oplus/kernel/cpu/sched_ext/hmbird_II/hmbird_II_freqgov.c
 vendor/oplus/kernel/cpu/sched_ext/hmbird_CameraScene/hmbird_CameraScene.c
 vendor/oplus/kernel/cpu/sched/sched_assist/sa_hmbird.c
 kernel_platform/common/include/linux/sched/ext.h
 kernel_platform/common/kernel/sched/ext.c
 vendor/oplus/kernel/cpu/oplus_local_modules.bzl
 kernel_platform/oplus/bazel/oplus_modules.bzl
)
for f in "${req[@]}"; do test -f "$f" || { echo "missing: $f"; exit 1; }; done
grep -q 'name = "oplus_bsp_sched_ext"' vendor/oplus/kernel/cpu/oplus_local_modules.bzl
grep -q 'name = "oplus_bsp_sched_assist"' vendor/oplus/kernel/cpu/oplus_local_modules.bzl
# The proprietary vendor/oplus/kernel/synchronize package is not published by
# OnePlus; the trim step must have removed its dependency from the sched_ext
# module graph (the locking strategy is an optional runtime hook).
if grep -q 'kernel/synchronize' vendor/oplus/kernel/cpu/oplus_local_modules.bzl; then
  echo "error: proprietary //vendor/oplus/kernel/synchronize still referenced" >&2
  exit 1
fi
# 风驰内核调速器完整链路校验：WALT(sched-walt) -> sched_assist -> sched_ext(HMBIRD II)
test -f kernel_platform/msm-kernel/kernel/sched/walt/modules.bzl
grep -q 'CONFIG_SCHED_WALT' kernel_platform/msm-kernel/configs/canoe_perf.bzl
grep -q 'hmbird_II_freqgov' vendor/oplus/kernel/cpu/sched_ext/hmbird_II/hmbird_II_freqgov.c
grep -RsnE 'oplus_bsp_sched_(ext|assist)|linux/sched/ext.h|hmbird_II|sched-walt' vendor/oplus/kernel/cpu/oplus_local_modules.bzl vendor/oplus/kernel/cpu/sched_ext kernel_platform/msm-kernel/kernel/sched/walt/modules.bzl | head -80 | tee ../hmbird-targets.txt
echo 'SM8850 风驰内核(HMBIRD II)源码链路完整：sched-walt + oplus_bsp_sched_assist + oplus_bsp_sched_ext(含 hmbird_II_freqgov 调速器)。'
echo '构建目标：只编内核( canoe_perf_images -> boot.img )；官方 vendor_dlkm/vendor_boot 保留不动，风驰内核调速器由官方 vendor_dlkm 提供。'
