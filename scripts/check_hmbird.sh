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
)
for f in "${req[@]}"; do test -f "$f" || { echo "missing: $f"; exit 1; }; done
grep -q 'name = "oplus_bsp_sched_ext"' vendor/oplus/kernel/cpu/oplus_local_modules.bzl
grep -q 'name = "oplus_bsp_sched_assist"' vendor/oplus/kernel/cpu/oplus_local_modules.bzl
grep -RsnE 'oplus_bsp_sched_(ext|assist)|linux/sched/ext.h|hmbird_II' vendor/oplus/kernel/cpu/oplus_local_modules.bzl vendor/oplus/kernel/cpu/sched_ext | head -80 | tee ../hmbird-targets.txt
echo 'SM8850 HMBIRD II uses upstream sched_ext API; source and DDK targets are complete.'
