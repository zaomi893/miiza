#!/usr/bin/env bash
set -euo pipefail
cd source/kernel_platform
mkdir -p ../../artifacts ../../logs
./tools/bazel query '//msm-kernel:*canoe*' 2>&1 | tee ../../logs/bazel-targets.log
TARGET=$(./tools/bazel query '//msm-kernel:*canoe*dist*' 2>/dev/null | grep -E 'canoe.*perf.*dist|canoe.*dist' | head -1 || true)
[[ -n "$TARGET" ]] || { echo 'No public canoe dist target found' | tee ../../logs/build-status.txt; exit 2; }
echo "Building $TARGET" | tee ../../logs/build-status.txt
./tools/bazel run "$TARGET" -- --dist_dir "$PWD/../../artifacts" 2>&1 | tee ../../logs/build.log
find ../../artifacts -type f -printf '%P\n' | sort | tee ../../logs/artifacts.txt
