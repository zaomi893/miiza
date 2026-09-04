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
# Boot-only strategy: canoe_perf_images never builds the oplus DDK modules, so
# the proprietary vendor/oplus/kernel/synchronize dep inside the unbuilt
# sched_ext module graph is never resolved and is left exactly as published;
# the working module ships in the official vendor_dlkm we keep on device.
# 风驰内核调速器完整链路校验：WALT(sched-walt) -> sched_assist -> sched_ext(HMBIRD II)
test -f kernel_platform/msm-kernel/kernel/sched/walt/modules.bzl
grep -q 'CONFIG_SCHED_WALT' kernel_platform/msm-kernel/configs/canoe_perf.bzl
grep -q 'hmbird_II_freqgov' vendor/oplus/kernel/cpu/sched_ext/hmbird_II/hmbird_II_freqgov.c
grep -RsnE 'oplus_bsp_sched_(ext|assist)|linux/sched/ext.h|hmbird_II|sched-walt' vendor/oplus/kernel/cpu/oplus_local_modules.bzl vendor/oplus/kernel/cpu/sched_ext kernel_platform/msm-kernel/kernel/sched/walt/modules.bzl | head -80 | tee ../hmbird-targets.txt
echo 'SM8850 风驰内核(HMBIRD II)源码链路完整：sched-walt + oplus_bsp_sched_assist + oplus_bsp_sched_ext(含 hmbird_II_freqgov 调速器)。'
echo '构建目标：厂商内核 vendor_boot.img( canoe_perf_images，带WALT的OKI GKI，该机型运行内核在 vendor_boot 分区，boot 分区是纯GKI合规镜像 )；官方 vendor_dlkm 保留不动，风驰内核调速器由官方 vendor_dlkm 提供。'
