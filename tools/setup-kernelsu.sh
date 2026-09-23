#!/usr/bin/env bash
set -euo pipefail

KSU_TYPE="${1:?missing KernelSU type}"
SELF_CONFIG="${2:-false}"
SUSFS_ENABLE="${3:-false}"
WORKSPACE="${GITHUB_WORKSPACE:?missing GITHUB_WORKSPACE}"

write_version() {
  local version="$1"
  printf 'KSUVER=%s\n' "$version" >> "$GITHUB_ENV"
  printf 'ksuver=%s\n' "$version" >> "$GITHUB_OUTPUT"
}

add_absolute_include_paths() {
  local kernel_dir="$1"
  local absolute_dir
  absolute_dir="$(realpath "$kernel_dir")"
  cat >> "$kernel_dir/Kbuild" <<EOF

# The in-tree symlink is evaluated from the output tree on Android 6.12.
# Absolute paths keep local KernelSU headers visible in out-of-tree builds.
ccflags-y += -I$absolute_dir -I$absolute_dir/include
EOF
}

case "$KSU_TYPE" in
  resukisu|sukisu)
    echo "正在配置 ReSukiSU（兼容 SukiSU Ultra 管理器）..."
    curl -fLSs --retry 3 \
      "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/refs/heads/main/kernel/setup.sh" |
      bash -s main
    if [[ "$SELF_CONFIG" == "true" ]]; then
      echo 'CONFIG_KSU_FULL_NAME_FORMAT="%TAG_NAME%-%COMMIT_SHA%"' >> common/arch/arm64/configs/gki_defconfig
    else
      echo 'CONFIG_KSU_FULL_NAME_FORMAT="%TAG_NAME%-%COMMIT_SHA%@ZAOMI"' >> common/arch/arm64/configs/gki_defconfig
    fi
    version="$(( $(git -C KernelSU rev-list --count HEAD) + 30700 ))"
    write_version "$version"
    ;;

  ksunext)
    echo "正在配置 KernelSU Next..."
    curl -fLSs --retry 3 \
      "https://raw.githubusercontent.com/pershoot/KernelSU-Next/refs/heads/dev-susfs/kernel/setup.sh" |
      bash -s dev-susfs
    add_absolute_include_paths KernelSU-Next/kernel
    version="$(( $(git -C KernelSU-Next rev-list --count HEAD) + 30000 ))"
    write_version "$version"
    # Keep .git: current KernelSU Next uses it for build-time version detection.
    cp "$WORKSPACE/other_patch/apk_sign.patch" common/drivers/kernelsu/
    patch -d common/drivers/kernelsu -p2 --batch --forward -F 3 \
      < common/drivers/kernelsu/apk_sign.patch || true
    ;;

  ksu)
    echo "正在配置原版 KernelSU (tiann/KernelSU)..."
    official_ref=main
    if [[ "$SUSFS_ENABLE" == "true" ]]; then
      official_ref=623eba3e092b911a3a7389b7d87622a5835d2f3a
    fi
    curl -fLSs --retry 3 \
      "https://raw.githubusercontent.com/tiann/KernelSU/$official_ref/kernel/setup.sh" |
      bash -s "$official_ref"
    if [[ "$SUSFS_ENABLE" == "true" ]]; then
      test "$(git -C KernelSU rev-parse HEAD)" = "$official_ref"
    fi
    add_absolute_include_paths KernelSU/kernel
    version="$(( $(git -C KernelSU rev-list --count HEAD) + 30000 ))"
    write_version "$version"
    ;;

  kowsu|kowx)
    if [[ "$SUSFS_ENABLE" == "true" ]]; then
      echo "正在配置 KowSU master（启用 SUSFS 内核配置）..."
    else
      echo "正在配置 KowSU master（普通内核配置）..."
    fi
    curl -fLSs --retry 3 \
      "https://raw.githubusercontent.com/${MIGRATED_REPO_OWNER:?MIGRATED_REPO_OWNER is required}/KowSU/refs/heads/master/kernel/setup.sh" |
      bash -s master
    add_absolute_include_paths KernelSU/kernel
    version="$(( $(git -C KernelSU rev-list --count HEAD) + 30000 ))"
    write_version "$version"
    ;;

  none)
    echo "已选择无内置 KernelSU 模式，跳过 KernelSU 配置..."
    write_version 0
    ;;

  *)
    echo "不支持的 KernelSU 类型：$KSU_TYPE" >&2
    exit 2
    ;;
esac
