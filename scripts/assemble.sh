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
git clone --filter=blob:none --depth=1 -b main-kernel-2025 https://android.googlesource.com/platform/prebuilts/build-tools source/kernel_platform/prebuilts/build-tools
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
# Kleaf pins an offline file registry under external/.
git clone --filter=blob:none --depth=1 -b main-kernel-2025 https://android.googlesource.com/platform/external/bazelbuild-bazel-central-registry source/kernel_platform/external/bazelbuild-bazel-central-registry

# This dev-only module is absent from the registry selected by OnePlus .bazelrc.
git clone --filter=blob:none --depth=1 -b 0.7.2 https://github.com/bazelbuild/stardoc.git source/kernel_platform/external/stardoc
cat >> source/kernel_platform/MODULE.bazel <<'MODULE'

local_path_override(
    module_name = "stardoc",
    path = "external/stardoc",
)
MODULE
# Qualcomm target definitions load //build/bazel_common_rules/dist:dist.bzl.
git clone --filter=blob:none --depth=1 -b android16-release https://android.googlesource.com/platform/build/bazel_common_rules source/kernel_platform/build/bazel_common_rules
# Qualcomm's manifest exposes the SoC kernel checkout under both msm-kernel and soc-repo,
# then mounts the separate devicetree project below its arch tree.
rm -rf source/kernel_platform/soc-repo
ln -s msm-kernel source/kernel_platform/soc-repo
mkdir -p source/kernel_platform/msm-kernel/arch/arm64/boot/dts
ln -s ../../../../../qcom/opensource/devicetree source/kernel_platform/msm-kernel/arch/arm64/boot/dts/vendor
test -f source/kernel_platform/soc-repo/target_variants.bzl
test -f source/kernel_platform/soc-repo/arch/arm64/boot/dts/vendor/BUILD.bazel
test -f source/kernel_platform/soc-repo/arch/arm64/boot/dts/vendor/oplus/platform_map.bzl
# Kleaf toolchain extension and common build.config.constants require clang-r536225.
git clone --filter=blob:none --depth=1 -b main-kernel-2025 https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 source/kernel_platform/prebuilts/clang/host/linux-x86
test -f source/kernel_platform/prebuilts/clang/host/linux-x86/kleaf/clang_toolchain_repository.bzl
test -x source/kernel_platform/prebuilts/clang/host/linux-x86/clang-r536225/bin/clang
# OnePlus published workspace_status_stamp.py with Python 3.12 PEP 695 syntax,
# while its pinned hermetic py3-cmd is older. Apply the equivalent portable typing form.
python3 - <<'PY'
p = "source/kernel_platform/build/kernel/kleaf/workspace_status_stamp.py"
s = open(p).read()
old = "from typing import Iterable\n"
new = "from typing import Iterable, TypeVar\n\nT = TypeVar(\"T\")\n"
assert old in s
s = s.replace(old, new, 1)
old = "def load_attribute_from_json[T](json_file: pathlib.Path, attr_name: str, attr_type: type[T]) \\\n"
new = "def load_attribute_from_json(json_file: pathlib.Path, attr_name: str, attr_type: type[T]) \\\n"
assert old in s
s = s.replace(old, new, 1)
open(p, "w").write(s)
PY
grep -q 'T = TypeVar("T")' source/kernel_platform/build/kernel/kleaf/workspace_status_stamp.py
! grep -q 'load_attribute_from_json\[T\]' source/kernel_platform/build/kernel/kleaf/workspace_status_stamp.py
# The published build/kernel/build-tools/sysroot symlink targets an omitted
# proprietary prebuilts/gcc checkout. Point it at AOSP's equivalent musl sysroot.
rm -f source/kernel_platform/build/kernel/build-tools/sysroot
ln -s ../../../prebuilts/build-tools/sysroots/x86_64-unknown-linux-musl \
  source/kernel_platform/build/kernel/build-tools/sysroot
test -f source/kernel_platform/build/kernel/build-tools/sysroot/include/stdio.h
# Kleaf boot_images references the standard Android mkbootimg package.
git clone --filter=blob:none --depth=1 -b main-kernel-2025 \
  https://android.googlesource.com/platform/system/tools/mkbootimg \
  source/kernel_platform/tools/mkbootimg
test -f source/kernel_platform/tools/mkbootimg/BUILD.bazel
test -f source/kernel_platform/tools/mkbootimg/mkbootimg.py
# Kleaf 2025 requires the AOSP bindgen/clang-tools Bazel package.
git clone --filter=blob:none --depth=1 -b main-kernel-2025 \
  https://android.googlesource.com/platform/prebuilts/clang-tools \
  source/kernel_platform/prebuilts/clang-tools
test -f source/kernel_platform/prebuilts/clang-tools/BUILD.bazel
test -x source/kernel_platform/prebuilts/clang-tools/linux-x86/bin/bindgen
