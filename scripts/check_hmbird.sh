#!/usr/bin/env bash
set -euo pipefail
cd source
for f in vendor/oplus/kernel/cpu/sched_ext/hmbird_II/hmbird_II.c vendor/oplus/kernel/cpu/sched_ext/hmbird_II/hmbird_II_freqgov.c vendor/oplus/kernel/cpu/sched_ext/hmbird_CameraScene/hmbird_CameraScene.c vendor/oplus/kernel/cpu/sched/sched_assist/sa_hmbird.c kernel_platform/common/include/linux/sched/hmbird.h; do test -f "$f" || { echo "missing: $f"; exit 1; }; done
grep -Rsn 'oplus_bsp_sched_ext' kernel_platform/oplus/bazel vendor/oplus/kernel/cpu | head -30 | tee ../hmbird-targets.txt
echo 'HMBIRD source set is complete.'
