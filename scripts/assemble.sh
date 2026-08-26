#!/usr/bin/env bash
set -euo pipefail
B=${BRANCH:-oneplus/sm8850_b_16.0.0_oneplus_15}
git clone --filter=blob:none --depth=1 -b "$B" https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850.git source
rm -rf source/kernel_platform/common source/kernel_platform/msm-kernel
git clone --filter=blob:none --depth=1 -b "$B" https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8850.git source/kernel_platform/common
git clone --filter=blob:none --depth=1 -b "$B" https://github.com/OnePlusOSS/android_kernel_oneplus_sm8850.git source/kernel_platform/msm-kernel
# Kleaf expects prebuilts/build-tools/linux_musl-x86/bin/py3-cmd.
# Clone the build-tools repository at its root, not inside linux_musl-x86.
rm -rf source/kernel_platform/prebuilts/build-tools
git clone --filter=blob:none --depth=1 -b main-kernel-build-2024 https://android.googlesource.com/platform/prebuilts/build-tools source/kernel_platform/prebuilts/build-tools
test -x source/kernel_platform/prebuilts/build-tools/linux_musl-x86/bin/py3-cmd
# Bazel binary used by Kleaf is published separately under kernel/prebuilts.
rm -rf source/kernel_platform/prebuilts/kernel-build-tools
git clone --filter=blob:none --depth=1 -b main-kernel-2025 https://android.googlesource.com/kernel/prebuilts/build-tools source/kernel_platform/prebuilts/kernel-build-tools
test -x source/kernel_platform/prebuilts/kernel-build-tools/bazel/linux-x86_64/bazel
# MODULE.bazel uses Android-tree local_path_override entries. Restore the public AOSP parts.
while read -r path; do
  git clone --filter=blob:none --depth=1 -b main-kernel-2025 "https://android.googlesource.com/platform/${path}" "source/kernel_platform/${path}"
done <<'PATHS'
external/libcap
external/libcap-ng
external/lz4
external/toybox
external/zlib
external/zopfli
external/pigz
external/python/absl-py
external/bazel-contrib-bazel_features
external/bazel-skylib
external/bazelbuild-platforms
external/bazelbuild-rules_cc
external/bazelbuild-rules_license
external/bazelbuild-rules_pkg
external/bazelbuild-rules_python
external/bazelbuild-rules_shell
PATHS
# This dev-only module is absent from the registry selected by OnePlus .bazelrc.
git clone --filter=blob:none --depth=1 -b 0.7.2 https://github.com/bazelbuild/stardoc.git source/kernel_platform/external/stardoc
cat >> source/kernel_platform/MODULE.bazel <<'MODULE'

local_path_override(
    module_name = "stardoc",
    path = "external/stardoc",
)
MODULE
