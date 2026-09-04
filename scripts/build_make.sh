#!/usr/bin/env bash
# =============================================================================
# OnePlus 15 (SM8850/canoe) GKI 内核构建脚本
# 学习 oplus_sm8850 仓库的构建写法 + ccache 快速构建机制
#
# 源码：cvhhji/android_kernel_common_oneplus_sm8850 @ oneplus/sm8850_v_16.0.0_oneplus_15
#       （用户 fork，剔除了导致不开机的坏提交，与 oplus_sm8850 同源）
# 工具链：Clang19 (r536225) + Rust + build-tools（cctv18/oneplus_sm8650_toolchain）
# 缓存：ccache + 时间劫持（fakestat/faketime）保证跨构建命中
# 产物：artifacts/Image（含 sched_ext=风驰 + KernelSU=ReSukiSU root）
#
# 自定义功能（环境变量控制，y/n）：
#   APPLY_LZ4=y      lz4 1.10.0 + zstd 1.5.7 补丁
#   APPLY_LZ4KD=n    lz4kd 补丁（与 lz4 二选一）
#   APPLY_NET=y       网络功能增强（ipset/iptables）+ config.patch 隐藏 IP6_NF_NAT
#   APPLY_BBR=n       BBR 等拥塞控制算法（n/y/d=default bbr）
#   APPLY_CVE=y       CVE-2026-43499 rtmutex 修复
#   APPLY_SUSFS=n     susfs 隐藏增强（KSU 配套）
#   APPLY_DROIDSPACES=n  Droidspaces 容器支持（s=标准/e=扩展）
#   APPLY_ADIOS=n     ADIOS IO 调度器
#   APPLY_REKERNEL=n  Re-Kernel 网络
#   APPLY_BBG=n       内核级基带保护
#   USE_PATCH_LINUX=n KPM 补丁（KernelSU Next）
#   KSU_TYPE=resukisu KSU 类型（resukisu/ksunext/ksu/none）
# =============================================================================
set -euo pipefail

# ===== 路径与工具链 =====
WORKDIR="$PWD"
COMMON="source/kernel_platform/common"
TOOLS="$WORKDIR/kernel_workspace"
CLANG_DIR="$TOOLS/clang19/bin"
mkdir -p artifacts logs

export PATH="$TOOLS/build-tools/bin:$PATH"
export PATH="$CLANG_DIR:$PATH"
export PATH="$TOOLS/rust/bin:$PATH"
export PATH="$WORKDIR/lib:$PATH"
export RUSTC="rustc"
export BINDGEN="bindgen"
export CC="clang"
export LIBCLANG_PATH="$TOOLS/clang19/lib"

cd "$COMMON"
DEFCONFIG=arch/arm64/configs/gki_defconfig

# ===== 自定义参数（学习 oplus 写法，环境变量控制）=====
CUSTOM_SUFFIX="${KERNEL_NAME:-android16-5-gb2a876903b49-ab14541642-4k}"
APPLY_LZ4="${APPLY_LZ4:-y}"
APPLY_LZ4KD="${APPLY_LZ4KD:-n}"
APPLY_NET="${APPLY_NET:-y}"
APPLY_BBR="${APPLY_BBR:-n}"
APPLY_CVE="${APPLY_CVE:-y}"
APPLY_SUSFS="${APPLY_SUSFS:-n}"
APPLY_DROIDSPACES="${APPLY_DROIDSPACES:-n}"
APPLY_ADIOS="${APPLY_ADIOS:-n}"
APPLY_REKERNEL="${APPLY_REKERNEL:-n}"
APPLY_BBG="${APPLY_BBG:-n}"
USE_PATCH_LINUX="${USE_PATCH_LINUX:-n}"
KSU_TYPE="${KSU_TYPE:-resukisu}"

PATCH_OK() { patch --batch --forward --no-backup-if-mismatch -p1 -F 3 < "$1" 2>/dev/null || true; }

# ===== ccache 配置（学习 oplus 缓存机制）=====
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache_6.12.23}"
mkdir -p "$CCACHE_DIR"
printf 'sloppiness = file_stat_matches,include_file_ctime,include_file_mtime,pch_defines,file_macro,time_macros\n' > "$CCACHE_DIR/ccache.conf"
export CCACHE_COMPILERCHECK="none"
export CCACHE_BASEDIR="$WORKDIR"
export CCACHE_NOHASHDIR="true"
export CCACHE_MAXSIZE="3G"
export CCACHE_IS_KERNEL_COMPILING="true"
ccache -M 3G >/dev/null 2>&1 || true

# ===== 时间劫持：固定时间戳 -> ccache 跨构建命中 =====
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

# ===== 替换版本后缀（学习 oplus 写法）=====
echo ">>> 替换内核版本后缀..."
for f in scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
done
# 固定 setlocalversion 输出，不受 git 状态影响
for f in scripts/setlocalversion; do
  sed -i "\$s|echo \"\\\$res\"|echo \"-${CUSTOM_SUFFIX}\"|" "$f"
done
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-'${CUSTOM_SUFFIX}'"/' "$DEFCONFIG"
sed -i 's/${scm_version}//' scripts/setlocalversion
grep -q '^CONFIG_LOCALVERSION_AUTO' "$DEFCONFIG" || echo 'CONFIG_LOCALVERSION_AUTO=n' >> "$DEFCONFIG"

# ===== 拉取 KSU（学习 oplus 写法，用官方 setup.sh）=====
echo ">>> 集成 KernelSU..."
if [[ "$KSU_TYPE" == "resukisu" ]]; then
  echo ">>> 拉取 ReSukiSU..."
  curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s main || true
  echo 'CONFIG_KSU_FULL_NAME_FORMAT="%TAG_NAME%-%COMMIT_SHA%@hmbird"' >> "$DEFCONFIG"
elif [[ "$KSU_TYPE" == "ksunext" ]]; then
  echo ">>> 拉取 KernelSU Next..."
  curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/refs/heads/dev-susfs/kernel/setup.sh" | bash -s dev-susfs || true
  cd KernelSU-Next && rm -rf .git && cd ..
  cd drivers/kernelsu
  curl --fail --location --retry 3 "https://raw.githubusercontent.com/cvhhji/oplus_sm8850/main/other_patch/apk_sign.patch" -O || true
  patch -p2 -N -F 3 < apk_sign.patch 2>/dev/null || true
  cd ../..
elif [[ "$KSU_TYPE" == "ksu" ]]; then
  echo ">>> 拉取原版 KernelSU..."
  curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/refs/heads/main/kernel/setup.sh" | bash -s main || true
else
  echo ">>> 无 KSU 模式"
fi

# ===== susfs 补丁（学习 oplus）=====
if [[ "$APPLY_SUSFS" == [yY] ]]; then
  echo ">>> 应用 susfs 补丁..."
  if [[ ! -d susfs4ksu ]]; then
    git clone --depth=1 https://github.com/cctv18/susfs4oki.git susfs4ksu -b oki-android16-6.12 2>&1 | tail -1 || true
  fi
  cp susfs4ksu/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch ./ 2>/dev/null || true
  cp susfs4ksu/kernel_patches/fs/* fs/ 2>/dev/null || true
  cp susfs4ksu/kernel_patches/include/linux/* include/linux/ 2>/dev/null || true
  sed -i -E 's/^static inline (bool|void) (susfs_(is|set|clear)_current_proc_(umounted|umounted_for_zygote_next|no_su)\()/static __always_inline \1 \2/' include/linux/susfs_def.h 2>/dev/null || true
  if grep -Eq 'getname_flags\(const char __user \*, int\);' include/linux/fs.h; then
    sed -i 's/getname_flags(filename, lookup_flags, NULL)/getname_flags(filename, lookup_flags)/g' ./50_add_susfs_in_gki-android16-6.12.patch
  fi
  PATCH_OK ./50_add_susfs_in_gki-android16-6.12.patch
fi

# ===== lz4 1.10.0 & zstd 1.5.7 补丁（学习 oplus，从 cctv18 下载）=====
if [[ "$APPLY_LZ4" == [yY] ]]; then
  echo ">>> 应用 lz4 1.10.0 + zstd 1.5.7 补丁..."
  PATCH_BASE="https://raw.githubusercontent.com/cctv18/oppo_oplus_realme_sm8850/main/zram_patch"
  curl --fail --location --retry 3 "$PATCH_BASE/001-lz4.patch" -o 001-lz4.patch || cp "$WORKDIR/zram_patch/001-lz4.patch" 001-lz4.patch
  curl --fail --location --retry 3 "$PATCH_BASE/002-zstd.patch" -o 002-zstd.patch || cp "$WORKDIR/zram_patch/002-zstd.patch" 002-zstd.patch
  awk '/^diff --git / { skip = (index($0, "diff --git a/fs/f2fs/Makefile " ) == 1 || index($0, "diff --git a/fs/f2fs/compress.c " ) == 1) } !skip' 001-lz4.patch > 001-lz4.filtered.patch
  patch --batch --forward --no-backup-if-mismatch -p1 < 001-lz4.filtered.patch 2>/dev/null || true
  patch --batch --forward --no-backup-if-mismatch -p1 < 002-zstd.patch 2>/dev/null || true
  rm -f 001-lz4.patch 002-zstd.patch 001-lz4.filtered.patch
fi

# ===== lz4kd 补丁（学习 oplus）=====
if [[ "$APPLY_LZ4KD" == [yY] ]]; then
  echo ">>> 应用 lz4kd 补丁..."
  curl --fail --location --retry 3 "https://raw.githubusercontent.com/cctv18/oppo_oplus_realme_sm8850/main/other_patch/lz4kd.patch" -o lz4kd.patch || cp "$WORKDIR/other_patch/lz4kd.patch" lz4kd.patch
  PATCH_OK ./lz4kd.patch
  cat >> "$DEFCONFIG" <<EOF
CONFIG_ZSMALLOC=y
CONFIG_CRYPTO_LZ4HC=y
CONFIG_CRYPTO_LZ4K=y
CONFIG_CRYPTO_LZ4KD=y
CONFIG_CRYPTO_842=y
CONFIG_ZRAM_BACKEND_LZ4HC=y
CONFIG_ZRAM_BACKEND_LZ4K=y
CONFIG_ZRAM_BACKEND_LZ4KD=y
CONFIG_ZRAM_BACKEND_842=y
EOF
fi

# ===== 添加 defconfig 配置项（学习 oplus）=====
echo ">>> 添加 defconfig 配置项..."
if [[ "$KSU_TYPE" != "none" ]]; then
  grep -q '^CONFIG_KSU=y' "$DEFCONFIG" || echo 'CONFIG_KSU=y' >> "$DEFCONFIG"
fi
if [[ "$APPLY_SUSFS" == [yY] ]]; then
  cat >> "$DEFCONFIG" <<EOF
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF
else
  grep -q '^CONFIG_KSU_SUSFS=' "$DEFCONFIG" || echo 'CONFIG_KSU_SUSFS=n' >> "$DEFCONFIG"
fi
# Mountify 支持
echo "CONFIG_TMPFS_XATTR=y" >> "$DEFCONFIG"
echo "CONFIG_TMPFS_POSIX_ACL=y" >> "$DEFCONFIG"
# O2 优化
echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y" >> "$DEFCONFIG"
# 禁用 HEADERS_INSTALL（oplus 标配）
if [[ -x scripts/config ]]; then
  scripts/config --file "$DEFCONFIG" --disable HEADERS_INSTALL || true
fi

# ===== CVE-2026-43499 rtmutex 修复（学习 oplus）=====
if [[ "$APPLY_CVE" == [yY] ]]; then
  echo ">>> 应用 CVE-2026-43499 rtmutex 补丁..."
  curl --fail --location --retry 3 "https://raw.githubusercontent.com/cctv18/oppo_oplus_realme_sm8850/main/other_patch/cve-2026-43499-rtmutex-6.12.patch" -o cve.patch || cp "$WORKDIR/other_patch/cve-2026-43499-rtmutex-6.12.patch" cve.patch
  patch -p1 -F 3 < cve.patch 2>/dev/null || true
  rm -f cve.patch
fi

# ===== RUST 配置（学习 oplus）=====
if [[ -x scripts/config ]]; then
  scripts/config --file "$DEFCONFIG" --enable RUST --module ANDROID_BINDER_IPC_RUST || true
fi

# ===== 网络功能增强 + config.patch（学习 oplus）=====
if [[ "$APPLY_NET" == [yY] ]]; then
  echo ">>> 启用网络功能增强..."
  cat >> "$DEFCONFIG" <<EOF
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
EOF
  # config.patch：构建时把内核 config_data 里的 CONFIG_IP6_NF_NAT=y 改成显示 n，
  # 避免 vintf 兼容性检测失败导致开机异常（功能仍启用，仅修改显示值）
  curl --fail --location --retry 3 "https://raw.githubusercontent.com/cctv18/oppo_oplus_realme_sm8850/main/other_patch/config.patch" -o config.patch || cp "$WORKDIR/other_patch/config.patch" config.patch
  PATCH_OK ./config.patch
  rm -f config.patch
fi

# ===== BBR 等拥塞控制算法（学习 oplus）=====
if [[ "$APPLY_BBR" == [yYdD] ]]; then
  echo ">>> 添加 BBR 等拥塞控制算法..."
  cat >> "$DEFCONFIG" <<EOF
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_VEGAS=y
CONFIG_TCP_CONG_NV=y
CONFIG_TCP_CONG_WESTWOOD=y
CONFIG_TCP_CONG_HTCP=y
CONFIG_TCP_CONG_BRUTAL=y
EOF
  if [[ "$APPLY_BBR" == [dD] ]]; then
    echo 'CONFIG_DEFAULT_TCP_CONG=bbr' >> "$DEFCONFIG"
  else
    echo 'CONFIG_DEFAULT_TCP_CONG=cubic' >> "$DEFCONFIG"
  fi
fi

# ===== Droidspaces 容器支持（学习 oplus）=====
if [[ "$APPLY_DROIDSPACES" == [sSeE] ]]; then
  echo ">>> 添加 Droidspaces 容器支持..."
  cat >> "$DEFCONFIG" <<EOF
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_USER_NS=y
CONFIG_SYSVIPC=y
CONFIG_DEVTMPFS=y
CONFIG_NAMESPACES=y
CONFIG_POSIX_MQUEUE=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_NTSYNC=y
EOF
  curl --fail --location --retry 3 "https://raw.githubusercontent.com/cctv18/oppo_oplus_realme_sm8850/main/droidspaces_patch/fix_sysvipc_kabi_a16-6.12.patch" -O || true
  PATCH_OK ./fix_sysvipc_kabi_a16-6.12.patch
  curl --fail --location --retry 3 "https://raw.githubusercontent.com/cctv18/oppo_oplus_realme_sm8850/main/droidspaces_patch/fix_oplus_bsp_midas.patch" -O || true
  PATCH_OK ./fix_oplus_bsp_midas.patch
  curl --fail --location --retry 3 "https://raw.githubusercontent.com/cctv18/oppo_oplus_realme_sm8850/main/droidspaces_patch/ntsync_compat_android16-6.12.patch" -O || true
  PATCH_OK ./ntsync_compat_android16-6.12.patch
  rm -f fix_sysvipc_kabi_a16-6.12.patch fix_oplus_bsp_midas.patch ntsync_compat_android16-6.12.patch
  if [[ "$APPLY_DROIDSPACES" == [eE] ]]; then
    echo "CONFIG_BT_HCIVHCI=y" >> "$DEFCONFIG"
    echo "CONFIG_STATIC_USERMODEHELPER=n" >> "$DEFCONFIG"
  fi
fi

# ===== ADIOS IO 调度器（学习 oplus）=====
if [[ "$APPLY_ADIOS" == [yY] ]]; then
  echo ">>> 启用 ADIOS 调度器..."
  echo "CONFIG_MQ_IOSCHED_ADIOS=y" >> "$DEFCONFIG"
  echo "CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y" >> "$DEFCONFIG"
fi

# ===== Re-Kernel（学习 oplus，源码已在用户 fork common 里）=====
if [[ "$APPLY_REKERNEL" == [yY] ]]; then
  echo ">>> 启用 Re-Kernel..."
  echo "CONFIG_REKERNEL=y" >> "$DEFCONFIG"
  echo "CONFIG_REKERNEL_NETWORK=y" >> "$DEFCONFIG"
fi

# ===== 内核级基带保护（学习 oplus，从 cctv18/Baseband-guard 下载）=====
if [[ "$APPLY_BBG" == [yY] ]]; then
  echo ">>> 启用内核级基带保护..."
  echo "CONFIG_BBG=y" >> "$DEFCONFIG"
  curl -sSL "https://github.com/cctv18/Baseband-guard/raw/master/setup.sh" | bash || true
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig 2>/dev/null || true
fi

# ===== 禁用 defconfig 检查（学习 oplus）=====
echo ">>> 禁用 defconfig 检查..."
sed -i 's/check_defconfig//' build.config.gki 2>/dev/null || true

# ===== 编译环境变量（学习 oplus + ccache）=====
echo ">>> 开始编译内核..."
export PATH="$WORKDIR/clang19/bin:$PATH" 2>/dev/null || true
export CC="$CLANG_DIR/clang"
export HOSTCC="$CLANG_DIR/clang"
export RUSTC="rustc"
export BINDGEN="bindgen"
export LIBCLANG_PATH="$WORKDIR/clang19/lib"
export LLVM=1 LLVM_IAS=1
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export LD=ld.lld HOSTLD=ld.lld AR=llvm-ar NM=llvm-nm AS=clang READELF=llvm-readelf
export OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size STRIP=llvm-strip

KCFLAGS="-no-canonical-prefixes -O2 -pipe -Wno-error -fno-stack-protector -D__ANDROID_COMMON_KERNEL__"
COMMON_REAL_PATH=$(pwd -P)
ROOT_REAL_PATH=$(dirname "$COMMON_REAL_PATH")
KCFLAGS+=" -fdebug-prefix-map=$ROOT_REAL_PATH=. -fmacro-prefix-map=$ROOT_REAL_PATH=. -ffile-prefix-map=$ROOT_REAL_PATH=."
export KCFLAGS

# 注意：不 source _setup_env.sh（Kleaf 脚本，KERNEL_DIR 为空时会 exit 1 终止当前 shell）
# make 构建不需要 Kleaf 环境

# ===== 编译（学习 oplus：gki_defconfig + Image 一步完成；ccache 包装器）=====
make -j"$(nproc --all)" \
    LLVM=1 \
    ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CC="$(pwd)/cc-wrapper" \
    HOSTCC="$CLANG_DIR/clang" \
    LD="$(pwd)/ld-wrapper" \
    HOSTLD=ld.lld \
    RUSTC="rustc" \
    OBJCOPY="llvm-objcopy" \
    O=out \
    gki_defconfig Image 2>&1 | tee "$WORKDIR/logs/build.log"

echo ">>> 内核编译成功！"

# ===== KPM 补丁（可选，学习 oplus）=====
OUT_DIR="$(pwd)/out/arch/arm64/boot"
if [[ "$USE_PATCH_LINUX" == [yY] ]]; then
  echo ">>> 使用 kptools-linux 打 KPM 补丁..."
  cd "$OUT_DIR"
  wget -q "https://github.com/KernelSU-Next/KPatch-Next/releases/latest/download/kptools-linux" || true
  wget -q "https://github.com/KernelSU-Next/KPatch-Next/releases/latest/download/kpimg-linux" || true
  chmod +x ./kptools-linux 2>/dev/null || true
  if [[ -x ./kptools-linux && -f ./kpimg-linux ]]; then
    ./kptools-linux -p -i ./Image -k ./kpimg-linux -o ./oImage
    rm -f Image && mv oImage Image
    echo ">>> KPM 补丁完成"
  fi
  cd - >/dev/null
fi

# ===== 产物验证 =====
IMAGE="$OUT_DIR/Image"
if [[ ! -f "$IMAGE" ]]; then
  echo "error: 未找到 Image 产物" >&2
  exit 1
fi
cp "$IMAGE" "$WORKDIR/artifacts/Image"
echo "Image -> artifacts/Image ($(du -h "$IMAGE" | cut -f1))"
echo "内核版本: $(strings "$IMAGE" | grep -m1 'Linux version 6\.12')"
echo "KernelSU (ReSukiSU root): $(strings "$IMAGE" | grep -ci 'kernelsu' && echo OK || echo MISSING)"
echo "sched_ext (风驰): $(strings "$IMAGE" | grep -c 'sched_ext' && echo OK || echo MISSING)"

# ===== 打包 AnyKernel3（学习 oplus：clone cvhhji/AnyKernel3）=====
echo ">>> 打包 AnyKernel3..."
AK3_DIR="$WORKDIR/ak3_workspace"
rm -rf "$AK3_DIR"
AK3_URL="https://github.com/cvhhji/AnyKernel3"
if [[ -n "${GH_TOKEN:-}" ]]; then
  AK3_URL="https://x-access-token:${GH_TOKEN}@github.com/cvhhji/AnyKernel3"
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AK3_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/cvhhji/AnyKernel3"
fi
git clone --depth=1 "$AK3_URL" "$AK3_DIR"
rm -rf "$AK3_DIR/.git"
cp "$IMAGE" "$AK3_DIR/Image"
# lz4kd 时放入 zram.zip
if [[ "$APPLY_LZ4KD" == [yY] ]]; then
  wget -q "https://raw.githubusercontent.com/cctv18/oppo_oplus_realme_sm8850/refs/heads/main/zram.zip" -O "$AK3_DIR/zram.zip" || true
fi
cd "$AK3_DIR"
ZIP_NAME="oneplus15-hmbird2-$(date +%Y%m%d-%H%M).zip"
zip -r9 -q "$WORKDIR/$ZIP_NAME" .
echo ">>> 打包完成: $WORKDIR/$ZIP_NAME"
ls -lh "$WORKDIR/$ZIP_NAME"
