#!/usr/bin/env bash
set -euo pipefail
cd source/kernel_platform
mkdir -p ../../artifacts ../../logs
BAZEL_CACHE_ARGS=()
if [[ -n "${BAZEL_REPOSITORY_CACHE:-}" ]]; then
  mkdir -p "$BAZEL_REPOSITORY_CACHE"
  BAZEL_CACHE_ARGS+=(--repository_cache="$BAZEL_REPOSITORY_CACHE")
fi
if [[ -n "${BAZEL_DISK_CACHE:-}" ]]; then
  mkdir -p "$BAZEL_DISK_CACHE"
  BAZEL_CACHE_ARGS+=(--disk_cache="$BAZEL_DISK_CACHE")
fi
bazel() {
  local command="$1"
  shift
  # repository_cache is a command option, not a Bazel startup option.
  ./tools/bazel "$command" "${BAZEL_CACHE_ARGS[@]}" "$@"
}
# Bazel label patterns do not support shell-style * wildcards. Query the package,
# retain the Canoe labels for diagnostics, then build the public perf dist rule.
bazel query '//msm-kernel:all' 2>&1 | tee ../../logs/bazel-targets-all.log | grep -E '^//msm-kernel:canoe' | tee ../../logs/bazel-targets.log
TARGET=//msm-kernel:canoe_perf_dist
bazel query "$TARGET" >/dev/null
echo "Building $TARGET" | tee ../../logs/build-status.txt
bazel run "$TARGET" -- --dist_dir "$PWD/../../artifacts" 2>&1 | tee ../../logs/build.log
find ../../artifacts -type f -printf '%P\n' | sort | tee ../../logs/artifacts.txt
