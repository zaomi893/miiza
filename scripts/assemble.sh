#!/usr/bin/env bash
set -euo pipefail
B=${BRANCH:-oneplus/sm8850_b_16.0.0_oneplus_15}
git clone --depth=1 -b "$B" https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850.git source
rm -rf source/kernel_platform/common source/kernel_platform/msm-kernel
git clone --depth=1 -b "$B" https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8850.git source/kernel_platform/common
git clone --depth=1 -b "$B" https://github.com/OnePlusOSS/android_kernel_oneplus_sm8850.git source/kernel_platform/msm-kernel
