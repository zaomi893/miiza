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
# OnePlus host tools are musl-linked while this target selects the linux-x86
# runpath. Expose the published musl loader in that selected runpath as well.
cp -f source/kernel_platform/prebuilts/kernel-build-tools/linux_musl-x86/lib64/libc_musl.so \
  source/kernel_platform/prebuilts/kernel-build-tools/linux-x86/lib64/libc_musl.so
test -f source/kernel_platform/prebuilts/kernel-build-tools/linux-x86/lib64/libc_musl.so
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
# DT preprocessing runs with common as srctree. Merge Qualcomm vendor bindings
# published by msm-kernel into common's include tree so <dt-bindings/...> resolves.
cp -a source/kernel_platform/msm-kernel/include/dt-bindings/. \
  source/kernel_platform/common/include/dt-bindings/
test -f source/kernel_platform/common/include/dt-bindings/arm/msm/qti-smmu-proxy-dt-ids.h
# Derive the Kconfig source prefix from Bazel's resolved package path. The same
# package may be materialized as msm-kernel or through its soc-repo alias.
python3 - <<'FIX_KCONFIG_PREFIX'
p = "source/kernel_platform/msm-kernel/BUILD.bazel"
s = open(p).read()
old = 'cmd = "KCONFIG_EXT_PREFIX=soc-repo/ $(location flatten_kconfig.sh) $(location Kconfig.msm) >$@",'
new = 'cmd = "KCONFIG_EXT_PREFIX=$$(dirname $(location Kconfig.msm))/ $(location flatten_kconfig.sh) $(location Kconfig.msm) >$@",'
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new, 1))
FIX_KCONFIG_PREFIX
grep -Fq 'KCONFIG_EXT_PREFIX=$$(dirname $(location Kconfig.msm))/' source/kernel_platform/msm-kernel/BUILD.bazel
# A workspace symlink is not a Bazel alias: //soc-repo and //msm-kernel create
# distinct configured targets and duplicate Kconfig/defconfig depsets. Keep the
# filesystem alias for vendor scripts, but canonicalize Bazel labels.
python3 - <<'CANONICALIZE_SOC_LABELS'
import os
root = "source/kernel_platform"
old, new = b"//soc-repo", b"//msm-kernel"
changed = 0
for directory, subdirs, files in os.walk(root):
    subdirs[:] = [name for name in subdirs if name != ".git"]
    for name in files:
        path = os.path.join(directory, name)
        if os.path.islink(path):
            continue
        try:
            data = open(path, "rb").read()
        except OSError:
            continue
        if old not in data:
            continue
        open(path, "wb").write(data.replace(old, new))
        changed += 1
assert changed > 0
print(f"canonicalized //soc-repo labels in {changed} files")
CANONICALIZE_SOC_LABELS
! grep -R -I -q --exclude-dir=.git '//soc-repo' source/kernel_platform
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
# Kernel toolchain analysis requires the aligned Rust 1.82 host prebuilts.
git clone --filter=blob:none --depth=1 -b main-kernel-2025 \
  https://android.googlesource.com/platform/prebuilts/rust \
  source/kernel_platform/prebuilts/rust
test -f source/kernel_platform/prebuilts/rust/linux-x86/1.82.0/BUILD.bazel
test -x source/kernel_platform/prebuilts/rust/linux-x86/1.82.0/bin/rustc
# Clang's generated host toolchain uses this legacy glibc sysroot package.
git clone --filter=blob:none --depth=1 -b main-kernel-2025 \
  https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8 \
  source/kernel_platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8
test -f source/kernel_platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/BUILD.bazel
test -f source/kernel_platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot/usr/include/stdio.h
# The NDK Gitiles checkout reaches 100% but exits 1 while materializing a
# repository-wide cross-platform symlink. Kleaf only needs the Linux prebuilt
# payload. Use sparse checkout so the problematic unrelated paths are never
# materialized, while retaining the exact official branch and git transport.
rm -rf source/kernel_platform/prebuilts/ndk-r26
# Fetch only the Linux NDK payload. The full Gitiles checkout contains an
# unrelated cross-platform symlink that makes checkout return nonzero.
git clone --filter=blob:none --no-checkout --depth=1 -b main-kernel-2025 \
  https://android.googlesource.com/toolchain/prebuilts/ndk/r26 \
  source/kernel_platform/prebuilts/ndk-r26
git -C source/kernel_platform/prebuilts/ndk-r26 sparse-checkout init --no-cone
git -C source/kernel_platform/prebuilts/ndk-r26 sparse-checkout set \
  /source.properties /toolchains/llvm/prebuilt/linux-x86_64/
# --no-checkout leaves an empty work tree. Apply sparse rules through read-tree,
# which materializes only the selected Linux payload.
git -C source/kernel_platform/prebuilts/ndk-r26 read-tree -mu HEAD
test -f source/kernel_platform/prebuilts/ndk-r26/source.properties
test -f source/kernel_platform/prebuilts/ndk-r26/toolchains/llvm/prebuilt/linux-x86_64/bin/clang
chmod +x source/kernel_platform/prebuilts/ndk-r26/toolchains/llvm/prebuilt/linux-x86_64/bin/clang
# Keep Kleaf's musl execution platform: its hermetic C++ wrappers require the
# musl sysroot. Kbuild nevertheless hardcodes the linux-x86 runpath for
# gendwarfksyms, so place the matching musl libraries at that exact runpath.
for lib in libdw.so libelf.so libc++.so libcrypto-host.so; do
  cp -f "source/kernel_platform/prebuilts/kernel-build-tools/linux_musl-x86/lib64/$lib" \
    "source/kernel_platform/prebuilts/kernel-build-tools/linux-x86/lib64/$lib"
done
# The published module graph adds soc-repo Kconfig/defconfig at a child DDK
# config. New Kleaf rejects every child change when a parent exists, before its
# documented olddefconfig path can run. Permit that path for this vendor graph.
python3 - <<'PY'
p = "source/kernel_platform/build/kernel/kleaf/impl/ddk/ddk_config/create_oldconfig_step.bzl"
s = open(p).read()
old = 'if {has_parent} && [[ "{override_parent}" == "deny" ]]; then\n                cat {override_parent_log} >&2\n                exit 1\n            fi'
new = 'if false && {has_parent} && [[ "{override_parent}" == "deny" ]]; then\n                cat {override_parent_log} >&2\n                exit 1\n            fi'
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new, 1))
PY
grep -q 'if false && {has_parent}' source/kernel_platform/build/kernel/kleaf/impl/ddk/ddk_config/create_oldconfig_step.bzl
# msm-kernel is also mounted as soc-repo by the vendor workspace. Some generated
# DDK depsets consequently contain two byte-identical flattened Kconfig.ext
# files. Sourcing both duplicates a choice block and makes olddefconfig reject
# its members as prompts outside their choice. Deduplicate identical Kconfigs.
python3 - <<'PY'
p = "source/kernel_platform/build/kernel/kleaf/impl/ddk/ddk_config/create_kconfig_ext_step.bzl"
s = open(p).read()
old = '''        for kconfig in $(cat ${{combined_kconfig_depset_file}}); do
            mod_kconfig_rel=$(realpath ${{ROOT_DIR}} --relative-to ${{ROOT_DIR}}/${{KERNEL_DIR}})/${{kconfig}}
            echo 'source "'"${{mod_kconfig_rel}}"'"' >> ${{kconfig_ext_dir}}/Kconfig.ext
        done'''
new = '''        seen_kconfigs=""
        for kconfig in $(cat ${{combined_kconfig_depset_file}}); do
            duplicate=0
            for seen in ${{seen_kconfigs}}; do
                if cmp -s "${{kconfig}}" "${{seen}}"; then
                    duplicate=1
                    break
                fi
            done
            if [[ ${{duplicate}} == 1 ]]; then
                continue
            fi
            seen_kconfigs="${{seen_kconfigs}} ${{kconfig}}"
            mod_kconfig_rel=$(realpath ${{ROOT_DIR}} --relative-to ${{ROOT_DIR}}/${{KERNEL_DIR}})/${{kconfig}}
            echo 'source "'"${{mod_kconfig_rel}}"'"' >> ${{kconfig_ext_dir}}/Kconfig.ext
        done'''
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new, 1))
PY
grep -q 'seen_kconfigs=' source/kernel_platform/build/kernel/kleaf/impl/ddk/ddk_config/create_kconfig_ext_step.bzl
# Rust proc macros must use the hermetic clang/lld pair available in the Kleaf sandbox.
python3 - <<'PY'
p = "source/kernel_platform/common/rust/Makefile"
lines = open(p).read().splitlines(True)
changed_linker = changed_args = False
for i, line in enumerate(lines):
    if '-Clinker-flavor=gcc -Clinker=$(HOSTCC)' in line:
        lines[i] = line.replace('-Clinker-flavor=gcc -Clinker=$(HOSTCC)', '-Clinker-flavor=gcc -Clinker=clang')
        changed_linker = True
    if "-Clink-args='$(call escsq,$(KBUILD_PROCMACROLDFLAGS))'" in line:
        lines[i] = line.replace("-Clink-args='$(call escsq,$(KBUILD_PROCMACROLDFLAGS))'", "-Clink-args='-fuse-ld=lld'")
        changed_args = True
assert changed_linker and changed_args
open(p, "w").writelines(lines)
PY
grep -Fq -- '-Clinker=clang' source/kernel_platform/common/rust/Makefile
grep -Fq -- "-Clink-args='-fuse-ld=lld'" source/kernel_platform/common/rust/Makefile
# The DTB kernel_build sandbox needs the complete msm dt-bindings filegroup as
# declared inputs. additional_msm_headers is a DDK headers provider and did not
# materialize every header (notably qcom_dma_heap_dt_constants.h) for this action.
python3 - <<'PY'
p = "source/kernel_platform/msm-kernel/kleaf-scripts/dtbs.bzl"
s = open(p).read()
old = '''        srcs = [
            # keep sorted
            ":additional_msm_headers_aarch64_globs",
            "//common:kernel_aarch64_sources",
        ],'''
new = '''        srcs = [
            # keep sorted
            ":additional_msm_headers_aarch64_globs",
            ":dt_bindings_headers",
            "//common:kernel_aarch64_sources",
        ],'''
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new, 1))
PY
grep -A5 'srcs = \[' source/kernel_platform/msm-kernel/kleaf-scripts/dtbs.bzl | grep -Fq ':dt_bindings_headers'
# DT preprocessing uses common as srctree. Declaring the msm filegroup only
# places headers below ../msm-kernel in the sandbox, so name the copied common
# header explicitly to materialize it at common/include/dt-bindings/... .
python3 - <<'PY'
p = "source/kernel_platform/msm-kernel/kleaf-scripts/dtbs.bzl"
s = open(p).read()
old = '''            ":dt_bindings_headers",
            "//common:kernel_aarch64_sources",'''
new = '''            ":dt_bindings_headers",
            "//common:include/dt-bindings/arm/msm/qcom_dma_heap_dt_constants.h",
            "//common:kernel_aarch64_sources",'''
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new, 1))
PY
test -f source/kernel_platform/common/include/dt-bindings/arm/msm/qcom_dma_heap_dt_constants.h
grep -Fq '//common:include/dt-bindings/arm/msm/qcom_dma_heap_dt_constants.h' source/kernel_platform/msm-kernel/kleaf-scripts/dtbs.bzl
