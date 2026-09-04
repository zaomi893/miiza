#!/usr/bin/env bash
# make + ccache 构建 OnePlus common GKI（学习 oplus_sm8850 仓库的缓存机制，6min 级快速构建）。
#
# 与 bazel/Kleaf 相比：make 直接编译 + ccache 编译缓存（GitHub Actions cache 恢复），
# 时间劫持(fakestat/faketime)固定文件时间戳，保证 ccache 跨构建稳定命中。
#
# 产物：artifacts/Image（OnePlus common GKI，含 sched_ext = 风驰可用 + KernelSU root = ReSukiSU）
# 依赖：
#   - source/kernel_platform/common  由 assemble.sh 克隆的 OnePlus common 源码
#   - kernel_workspace/{clang19,rust,build-tools}  由 fastbuild.yml 下载的 Clang19/rust 工具链
#   - lib/{ccache-x86-64,libfakestat.so,libfaketimeMT.so}  本仓库自带
set -euo pipefail

WORKDIR="$PWD"
COMMON="source/kernel_platform/common"
TOOLS="$WORKDIR/kernel_workspace"
CLANG_DIR="$TOOLS/clang19/bin"
mkdir -p artifacts logs

# ---- 工具链 ----
export PATH="$TOOLS/build-tools/bin:$PATH"
export PATH="$CLANG_DIR:$PATH"
export PATH="$TOOLS/rust/bin:$PATH"
export PATH="$WORKDIR/lib:$PATH"   # ccache 二进制
export RUSTC="rustc"
export BINDGEN="bindgen"
export CC="clang"
export LIBCLANG_PATH="$TOOLS/clang19/lib"

cd "$COMMON"

# ---- ccache 配置（学习方法来自 oplus_sm8850）----
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache_6.12.23}"
mkdir -p "$CCACHE_DIR"
printf 'sloppiness = file_stat_matches,include_file_ctime,include_file_mtime,pch_defines,file_macro,time_macros\n' > "$CCACHE_DIR/ccache.conf"
export CCACHE_COMPILERCHECK="none"
export CCACHE_BASEDIR="$WORKDIR"
export CCACHE_NOHASHDIR="true"
export CCACHE_MAXSIZE="3G"
export CCACHE_IS_KERNEL_COMPILING="true"
ccache -M 3G >/dev/null 2>&1 || true

# ---- 时间劫持：固定时间戳 -> ccache 跨构建命中 ----
KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(date -u +'%a %b %-d %H:%M:%S UTC %Y')}"
export KBUILD_BUILD_TIMESTAMP
FAKE_TS="$(date -u -d "$KBUILD_BUILD_TIMESTAMP" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u +'%Y-%m-%d %H:%M:%S')"
export FAKESTAT="$FAKE_TS"
export FAKETIME="@$FAKE_TS"
chmod 777 "$WORKDIR/lib/"*.so 2>/dev/null || true
PRELOAD_LIBS="$WORKDIR/lib/libfakestat.so $WORKDIR/lib/libfaketimeMT.so"
REAL_CLANG_PATH="$CLANG_DIR/clang"

cat > fake-env <<EOF
#!/bin/bash
export LD_PRELOAD="$PRELOAD_LIBS"
exec "\$@"
EOF
cat > cc-wrapper <<EOF
#!/bin/bash
export FAKESTAT="$FAKESTAT"
export FAKETIME="$FAKETIME"
export CCACHE_PREFIX="$PWD/fake-env"
exec ccache "$REAL_CLANG_PATH" "\$@"
EOF
cat > ld-wrapper <<EOF
#!/bin/bash
export LD_PRELOAD="$PRELOAD_LIBS"
export FAKESTAT="$FAKESTAT"
export FAKETIME="$FAKETIME"
exec "$CLANG_DIR/ld.lld" "\$@"
EOF
chmod +x fake-env cc-wrapper ld-wrapper

# ---- localversion：注入官方 boot.img 内核版本（最大兼容）----
KERNEL_NAME="${KERNEL_NAME:-android16-5-gb2a876903b49-ab14541642-4k}"
sed -i "s/-4k/-$KERNEL_NAME/g" arch/arm64/configs/gki_defconfig
grep -q '^CONFIG_LOCALVERSION_AUTO' arch/arm64/configs/gki_defconfig || echo 'CONFIG_LOCALVERSION_AUTO=n' >> arch/arm64/configs/gki_defconfig

# ---- 集成 ReSukiSU (KernelSU root)，保留风驰(sched_ext 在 defconfig 默认开启)----
# ReSukiSU 的 Kbuild 检查 $(KSU_SRC)/../.git（必须保留 git 仓库，直接 cp 复制代码会报
# "You should use ReSukiSU as a git submodule instead of copying code"），
# 故用 symlink 方式（ReSukiSU setup.sh 原版）：drivers/kernelsu -> ../KernelSU/kernel，KernelSU/ 保留 .git。
if [[ ! -d KernelSU ]]; then
  echo "clone ReSukiSU ..."
  git clone https://github.com/ReSukiSU/ReSukiSU KernelSU 2>&1 | tail -1 || true
fi
if [[ -d KernelSU/kernel ]]; then
  rm -f drivers/kernelsu
  ln -sf ../KernelSU/kernel drivers/kernelsu
  grep -q "kernelsu" drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
  grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig
  grep -q '^CONFIG_KSU=y' arch/arm64/configs/gki_defconfig || echo 'CONFIG_KSU=y' >> arch/arm64/configs/gki_defconfig
  echo "ReSukiSU 已集成（symlink -> KernelSU/kernel）"
else
  echo "警告: ReSukiSU 集成失败，将构建无 root 内核" >&2
fi

# ---- 自定义配置（学习 oplus_sm8850 仓库）----
APPLY_LZ4="${APPLY_LZ4:-y}"        # lz4 1.10.0 + zstd 1.5.7 补丁
APPLY_LZ4KD="${APPLY_LZ4KD:-n}"    # lz4kd 补丁（与 lz4/zstd 二选一）
APPLY_NET="${APPLY_NET:-y}"        # 网络功能增强（ipset/iptables 支持）
APPLY_BBR="${APPLY_BBR:-n}"        # BBR 等拥塞控制算法（n/y/default）
APPLY_CVE="${APPLY_CVE:-y}"        # CVE-2026-43499 rtmutex 修复
APPLY_SUSFS="${APPLY_SUSFS:-n}"    # susfs 隐藏增强（依赖 KSU，官方 common 有适配风险）
DEFCONFIG=arch/arm64/configs/gki_defconfig
PATCH_OK() { patch --batch --forward --no-backup-if-mismatch -p1 -F 3 < "$1" 2>/dev/null || true; }

# lz4 1.10.0 & zstd 1.5.7 补丁（过滤 fs/f2fs，避免与 f2fs 冲突）
if [[ "$APPLY_LZ4" == "y" ]]; then
  echo "应用 lz4 1.10.0 + zstd 1.5.7 补丁..."
  awk '/^diff --git / { skip = (index($0, "diff --git a/fs/f2fs/Makefile " ) == 1 || index($0, "diff --git a/fs/f2fs/compress.c " ) == 1) } !skip' "$WORKDIR/zram_patch/001-lz4.patch" > /tmp/001-lz4.f.patch
  PATCH_OK /tmp/001-lz4.f.patch
  PATCH_OK "$WORKDIR/zram_patch/002-zstd.patch"
fi
# lz4kd 补丁
if [[ "$APPLY_LZ4KD" == "y" ]]; then
  echo "应用 lz4kd 补丁..."
  PATCH_OK "$WORKDIR/other_patch/lz4kd.patch"
  echo 'CONFIG_ZSMALLOC=y' >> "$DEFCONFIG"
  echo 'CONFIG_CRYPTO_LZ4HC=y' >> "$DEFCONFIG"
  echo 'CONFIG_CRYPTO_LZ4K=y' >> "$DEFCONFIG"
  echo 'CONFIG_CRYPTO_LZ4KD=y' >> "$DEFCONFIG"
  echo 'CONFIG_CRYPTO_842=y' >> "$DEFCONFIG"
  echo 'CONFIG_ZRAM_BACKEND_LZ4HC=y' >> "$DEFCONFIG"
  echo 'CONFIG_ZRAM_BACKEND_LZ4K=y' >> "$DEFCONFIG"
  echo 'CONFIG_ZRAM_BACKEND_LZ4KD=y' >> "$DEFCONFIG"
  echo 'CONFIG_ZRAM_BACKEND_842=y' >> "$DEFCONFIG"
fi
# 网络功能增强（ipset / 高级 netfilter）
if [[ "$APPLY_NET" == "y" ]]; then
  echo "启用网络功能增强配置..."
  {
    echo 'CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y'
    echo 'CONFIG_NETFILTER_XT_SET=y'
    echo 'CONFIG_IP_SET=y'
    echo 'CONFIG_IP_SET_MAX=65534'
    echo 'CONFIG_IP_SET_BITMAP_IP=y'
    echo 'CONFIG_IP_SET_BITMAP_IPMAC=y'
    echo 'CONFIG_IP_SET_BITMAP_PORT=y'
    echo 'CONFIG_IP_SET_HASH_IP=y'
    echo 'CONFIG_IP_SET_HASH_IPMARK=y'
    echo 'CONFIG_IP_SET_HASH_IPPORT=y'
    echo 'CONFIG_IP_SET_HASH_IPPORTIP=y'
    echo 'CONFIG_IP_SET_HASH_IPPORTNET=y'
    echo 'CONFIG_IP_SET_HASH_IPMAC=y'
    echo 'CONFIG_IP_SET_HASH_MAC=y'
    echo 'CONFIG_IP_SET_HASH_NETPORTNET=y'
    echo 'CONFIG_IP_SET_HASH_NET=y'
    echo 'CONFIG_IP_SET_HASH_NETNET=y'
    echo 'CONFIG_IP_SET_HASH_NETPORT=y'
    echo 'CONFIG_IP_SET_HASH_NETIFACE=y'
    echo 'CONFIG_IP_SET_LIST_SET=y'
    echo 'CONFIG_IP6_NF_NAT=y'
    echo 'CONFIG_IP6_NF_TARGET_MASQUERADE=y'
  } >> "$DEFCONFIG"
fi
# BBR 等拥塞控制算法
if [[ "$APPLY_BBR" != "n" ]]; then
  echo "添加 BBR 等拥塞控制算法..."
  {
    echo 'CONFIG_TCP_CONG_ADVANCED=y'
    echo 'CONFIG_TCP_CONG_BBR=y'
    echo 'CONFIG_TCP_CONG_CUBIC=y'
    echo 'CONFIG_TCP_CONG_VEGAS=y'
    echo 'CONFIG_TCP_CONG_NV=y'
    echo 'CONFIG_TCP_CONG_WESTWOOD=y'
    echo 'CONFIG_TCP_CONG_HTCP=y'
    echo 'CONFIG_TCP_CONG_BRUTAL=y'
  } >> "$DEFCONFIG"
  if [[ "$APPLY_BBR" == "default" ]]; then
    echo 'CONFIG_DEFAULT_TCP_CONG=bbr' >> "$DEFCONFIG"
  else
    echo 'CONFIG_DEFAULT_TCP_CONG=cubic' >> "$DEFCONFIG"
  fi
fi
# CVE-2026-43499 rtmutex 修复
if [[ "$APPLY_CVE" == "y" ]]; then
  echo "应用 CVE-2026-43499 rtmutex 补丁..."
  PATCH_OK "$WORKDIR/other_patch/cve-2026-43499-rtmutex-6.12.patch"
fi
# susfs 隐藏增强（KSU 配套；官方 common 存在 getname_flags ABI 差异，若打补丁失败则跳过不阻断）
if [[ "$APPLY_SUSFS" == "y" && -d drivers/kernelsu ]]; then
  echo "集成 susfs (增强隐藏环境)..."
  if [[ ! -d susfs4ksu ]]; then
    git clone --depth=1 https://github.com/cctv18/susfs4oki.git susfs4ksu -b oki-android16-6.12 2>&1 | tail -1 || true
  fi
  PATCH_FILE="susfs4ksu/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch"
  if [[ -f "$PATCH_FILE" ]]; then
    cp "$PATCH_FILE" ./50_susfs.patch
    cp susfs4ksu/kernel_patches/fs/* fs/ 2>/dev/null || true
    cp susfs4ksu/kernel_patches/include/linux/* include/linux/ 2>/dev/null || true
    sed -i -E 's/^static inline (bool|void) (susfs_(is|set|clear)_current_proc_(umounted|umounted_for_zygote_next|no_su)\()/static __always_inline \1 \2/' include/linux/susfs_def.h 2>/dev/null || true
    if grep -Eq 'getname_flags\(const char __user \*, int\);' include/linux/fs.h; then
      sed -i 's/getname_flags(filename, lookup_flags, NULL)/getname_flags(filename, lookup_flags)/g' ./50_susfs.patch
    fi
    PATCH_OK ./50_susfs.patch
    {
      echo 'CONFIG_KSU_SUSFS=y'
      echo 'CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y'
      echo 'CONFIG_KSU_SUSFS_SUS_PATH=y'
      echo 'CONFIG_KSU_SUSFS_SUS_MOUNT=y'
      echo 'CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y'
      echo 'CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y'
      echo 'CONFIG_KSU_SUSFS_SUS_KSTAT=y'
      echo 'CONFIG_KSU_SUSFS_TRY_UMOUNT=y'
      echo 'CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y'
      echo 'CONFIG_KSU_SUSFS_SPOOF_UNAME=y'
      echo 'CONFIG_KSU_SUSFS_ENABLE_LOG=y'
      echo 'CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y'
      echo 'CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y'
      echo 'CONFIG_KSU_SUSFS_OPEN_REDIRECT=y'
      echo 'CONFIG_KSU_SUSFS_SUS_MAP=y'
    } >> "$DEFCONFIG"
    echo "susfs 配置已添加"
  else
    echo "警告: susfs 补丁文件未找到，跳过" >&2
  fi
fi
echo "CONFIG_TMPFS_XATTR=y" >> "$DEFCONFIG"
echo "CONFIG_TMPFS_POSIX_ACL=y" >> "$DEFCONFIG"   # Mountify 支持
echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y" >> "$DEFCONFIG"  # O2

# ---- 6.12 make 编译核心配置（cctv18 踩坑后的必需项）----
# 路径重映射：Rust gendwarfksyms 无法处理绝对路径，必须重映射为相对路径
COMMON_REAL_PATH="$(pwd -P)"
ROOT_REAL_PATH="$(dirname "$COMMON_REAL_PATH")"
KCFLAGS="-fdebug-prefix-map=$ROOT_REAL_PATH=. -fmacro-prefix-map=$ROOT_REAL_PATH=. -ffile-prefix-map=$ROOT_REAL_PATH=."
KCFLAGS+=" -no-canonical-prefixes -O2 -pipe -Wno-error -fno-stack-protector -D__ANDROID_COMMON_KERNEL__"
export KCFLAGS
export HOSTCC="$CLANG_DIR/clang"
export HOSTLD="$CLANG_DIR/ld.lld"
export LLVM=1 LLVM_IAS=1
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export LD="$CLANG_DIR/ld.lld"
export AR="$CLANG_DIR/llvm-ar" NM="$CLANG_DIR/llvm-nm" AS=clang READELF="$CLANG_DIR/llvm-readelf"
export OBJCOPY="$CLANG_DIR/llvm-objcopy" OBJDUMP="$CLANG_DIR/llvm-objdump" OBJSIZE="$CLANG_DIR/llvm-size"
export STRIP="$CLANG_DIR/llvm-strip"
source ./_setup_env.sh 2>/dev/null || true

echo "=== make gki_defconfig ===" | tee $WORKDIR/logs/make-status.txt
make -j"$(nproc --all)" LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC="$CLANG_DIR/clang" LD="$CLANG_DIR/ld.lld" OBJCOPY="$CLANG_DIR/llvm-objcopy" \
  O=out gki_defconfig 2>&1 | tee $WORKDIR/logs/make-defconfig.log || { echo "defconfig 失败" >&2; exit 1; }

echo "=== make Image (ccache) ===" | tee -a $WORKDIR/logs/make-status.txt
make -j"$(nproc --all)" LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC="$(pwd)/cc-wrapper" LD="$(pwd)/ld-wrapper" OBJCOPY="$CLANG_DIR/llvm-objcopy" \
  O=out Image 2>&1 | tee $WORKDIR/logs/make-build.log || { echo "Image 编译失败" >&2; exit 1; }

# ---- 产物 ----
IMAGE="$(pwd)/out/arch/arm64/boot/Image"
if [[ ! -f "$IMAGE" ]]; then
  echo "error: 未找到 Image 产物" >&2
  exit 1
fi
cp "$IMAGE" "$WORKDIR/artifacts/Image"
echo "Image -> artifacts/Image ($(du -h "$WORKDIR/artifacts/Image" | cut -f1))"
ccache -s 2>&1 | grep -E 'cache hit|Hits|Misses' || true

# ---- 验证 ----
if command -v strings >/dev/null 2>&1; then
  VER="$(strings -a "$WORKDIR/artifacts/Image" 2>/dev/null | grep -a -m1 'Linux version' || true)"
  echo "内核版本: $VER" | tee "$WORKDIR/logs/kernel-version.txt"
  if strings -a "$WORKDIR/artifacts/Image" 2>/dev/null | grep -a -qi 'kernelsu\|ksu_handle'; then
    echo "KernelSU (ReSukiSU root): OK" | tee -a "$WORKDIR/logs/make-status.txt"
  else
    echo "警告: Image 中未检测到 KernelSU 符号" | tee -a "$WORKDIR/logs/make-status.txt"
  fi
  if strings -a "$WORKDIR/artifacts/Image" 2>/dev/null | grep -a -q 'sched_ext'; then
    echo "sched_ext (风驰): OK" | tee -a "$WORKDIR/logs/make-status.txt"
  fi
fi
echo "=== build_make.sh 完成 ==="
