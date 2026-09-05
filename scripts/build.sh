#!/usr/bin/env bash
set -euo pipefail

# OnePlus 15 stock-compatible custom GKI build.
# The stock HMBIRD II implementation stays in vendor_dlkm. This script only
# replaces boot/Image and deliberately builds the exact ACK commit recorded in
# the supplied stock boot image.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${COMMON:-$ROOT/source/kernel_platform/common}"
TOOLS="${TOOLS:-$ROOT/kernel_workspace}"
OUT="${OUT:-$COMMON/out}"
ARTIFACTS="$ROOT/artifacts"
LOGS="$ROOT/logs"

STOCK_COMMIT="${STOCK_COMMIT:-b2a876903b495c444a94b16f50d1463ffe953957}"
STOCK_RELEASE="${STOCK_RELEASE:-6.12.23-android16-5-gb2a876903b49-ab14541642-4k}"
LOCAL_SUFFIX="${STOCK_RELEASE#6.12.23}"
KSU_TYPE="${KSU_TYPE:-resukisu}"

die() { echo "error: $*" >&2; exit 1; }
require_file() { [[ -f "$1" ]] || die "missing $1"; }
require_config() { grep -qx "$1" "$OUT/.config" || die "required config missing: $1"; }

require_file "$COMMON/Makefile"
[[ "$(git -C "$COMMON" rev-parse HEAD)" == "$STOCK_COMMIT" ]] ||
  die "source is not the stock ACK commit $STOCK_COMMIT"

mkdir -p "$ARTIFACTS" "$LOGS" "$OUT"
rm -f "$ARTIFACTS/Image" "$ARTIFACTS/config" "$ARTIFACTS/System.map"

export PATH="$TOOLS/build-tools/bin:$TOOLS/clang19/bin:$TOOLS/rust/bin:$ROOT/lib:$PATH"
export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1
export CC=clang HOSTCC=clang LD=ld.lld HOSTLD=ld.lld
export AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump
export READELF=llvm-readelf STRIP=llvm-strip RUSTC=rustc BINDGEN=bindgen
export LIBCLANG_PATH="$TOOLS/clang19/lib"
export KBUILD_BUILD_USER=kleaf KBUILD_BUILD_HOST=build-host
export KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP="Fri Dec  5 02:05:55 UTC 2025"
# scripts/setlocalversion appends '+' to an untagged ACK checkout unless the
# make-time LOCALVERSION variable is explicitly present.  The stock suffix is
# already supplied through CONFIG_LOCALVERSION below, so keep the make-time
# value deliberately empty to reproduce the exact stock UTS release.
export LOCALVERSION=""

if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$ROOT/.ccache}"
  export CCACHE_BASEDIR="$ROOT" CCACHE_NOHASHDIR=true CCACHE_COMPILERCHECK=none
  mkdir -p "$CCACHE_DIR"
  CC_CMD="ccache clang"
else
  CC_CMD=clang
fi

cd "$COMMON"

case "$KSU_TYPE" in
  none)
    echo "Building without KernelSU"
    ;;
  resukisu)
    echo "Integrating ReSukiSU"
    curl --fail --location --retry 3 --silent --show-error \
      https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh |
      bash -s main
    [[ -d drivers/kernelsu || -d KernelSU ]] || die "ReSukiSU setup did not install kernel sources"
    ;;
  *)
    die "unsupported KSU_TYPE=$KSU_TYPE (use resukisu or none)"
    ;;
esac

# Kleaf's stock GKI target trims exports to the union of the base and vendor
# KMI lists. Reproduce that behavior for the faster Make/ccache build.
KMI_LIST="$OUT/abi_symbollist.raw"
awk '
  /^\[abi_symbol_list\]$/ { next }
  /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ {
    gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print
  }
' gki/aarch64/symbols/* | LC_ALL=C sort -u > "$KMI_LIST"
grep -qx '__tracepoint_android_vh_scx_restore_flags' "$KMI_LIST" ||
  die "stock HMBIRD KMI hook is absent from the pinned source"

make O="$OUT" CC="$CC_CMD" gki_defconfig

scripts/config --file "$OUT/.config" --set-str LOCALVERSION "$LOCAL_SUFFIX"
scripts/config --file "$OUT/.config" --disable LOCALVERSION_AUTO
scripts/config --file "$OUT/.config" --enable SCHED_CLASS_EXT
scripts/config --file "$OUT/.config" --enable BPF
scripts/config --file "$OUT/.config" --enable BPF_SYSCALL
scripts/config --file "$OUT/.config" --enable BPF_JIT
scripts/config --file "$OUT/.config" --enable BPF_JIT_ALWAYS_ON
scripts/config --file "$OUT/.config" --enable IKCONFIG
scripts/config --file "$OUT/.config" --enable IKCONFIG_PROC
scripts/config --file "$OUT/.config" --enable ANDROID_VENDOR_HOOKS
scripts/config --file "$OUT/.config" --enable MODVERSIONS
scripts/config --file "$OUT/.config" --enable DEBUG_INFO_BTF
scripts/config --file "$OUT/.config" --enable DEBUG_INFO_BTF_MODULES
scripts/config --file "$OUT/.config" --enable CFI_CLANG
scripts/config --file "$OUT/.config" --enable LTO_NONE
scripts/config --file "$OUT/.config" --disable LTO_CLANG_THIN
scripts/config --file "$OUT/.config" --disable LTO_CLANG_FULL
scripts/config --file "$OUT/.config" --enable TRIM_UNUSED_KSYMS
scripts/config --file "$OUT/.config" --set-str UNUSED_KSYMS_WHITELIST "$KMI_LIST"
if [[ "$KSU_TYPE" != none ]]; then
  scripts/config --file "$OUT/.config" --enable KSU
fi

make O="$OUT" CC="$CC_CMD" olddefconfig

for cfg in \
  CONFIG_SCHED_CLASS_EXT=y CONFIG_BPF=y CONFIG_BPF_SYSCALL=y \
  CONFIG_BPF_JIT=y CONFIG_BPF_JIT_ALWAYS_ON=y CONFIG_IKCONFIG=y \
  CONFIG_ANDROID_VENDOR_HOOKS=y \
  CONFIG_MODVERSIONS=y CONFIG_TRIM_UNUSED_KSYMS=y \
  CONFIG_DEBUG_INFO_BTF=y CONFIG_DEBUG_INFO_BTF_MODULES=y \
  CONFIG_CFI_CLANG=y CONFIG_LTO_NONE=y; do
  require_config "$cfg"
done

echo "Building stock-compatible GKI $STOCK_RELEASE"
make -j"$(nproc --all)" O="$OUT" CC="$CC_CMD" Image vmlinux 2>&1 | tee "$LOGS/build.log"

require_file "$OUT/arch/arm64/boot/Image"
require_file "$OUT/System.map"
require_file "$OUT/Module.symvers"
require_file "$OUT/vmlinux"

cp "$OUT/arch/arm64/boot/Image" "$ARTIFACTS/Image"
cp "$OUT/.config" "$ARTIFACTS/config"
cp "$OUT/System.map" "$ARTIFACTS/System.map"

bash "$ROOT/scripts/verify_image.sh" "$ARTIFACTS/Image" "$OUT" | tee "$LOGS/compatibility.txt"
echo "Image ready: $ARTIFACTS/Image"
