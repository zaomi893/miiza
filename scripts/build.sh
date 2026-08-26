#!/usr/bin/env bash
set -euo pipefail
cd source/kernel_platform
mkdir -p ../../artifacts ../../logs
# Bazel label patterns do not support shell-style * wildcards. Query the package,
# retain the Canoe labels for diagnostics, then build the public perf dist rule.
./tools/bazel query '//msm-kernel:all' 2>&1 | tee ../../logs/bazel-targets-all.log | grep -E '^//msm-kernel:canoe' | tee ../../logs/bazel-targets.log
TARGET=//msm-kernel:canoe_perf_dist
./tools/bazel query "$TARGET" >/dev/null
echo "Building $TARGET" | tee ../../logs/build-status.txt
./tools/bazel run "$TARGET" -- --dist_dir "$PWD/../../artifacts" 2>&1 | tee ../../logs/build.log
find ../../artifacts -type f -printf '%P\n' | sort | tee ../../logs/artifacts.txt
