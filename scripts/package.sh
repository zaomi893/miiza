#!/usr/bin/env bash
# 把自编内核镜像打包成 OnePlus 15 (SM8850/canoe) 可直接刷入的 AnyKernel3 zip。
#
# 刷入内容：
#   - boot        <- artifacts/boot.img        (厂商内核/OKI GKI，含 WALT，风驰调速器可工作)
#   - vendor_boot <- artifacts/vendor_boot.img (同源厂商内核 + vendor ramdisk + DTB，兼容启动布局)
# 保留官方 vendor_dlkm（风驰链 sched-walt/sched_assist/sched_ext 模块在官方 vendor_dlkm 中）。
#
# 为什么这样刷：
#   - 风驰(HMBIRD II) 是 sched_ext BPF 调度器，依赖内核 WALT。官方 boot.img 内核就是带 WALT
#     的厂商内核(OKI GKI)。本产物与官方同分支同配置构建，KMI 匹配 → 官方模块直接加载并工作。
#   - 同时刷 boot 与 vendor_boot 覆盖两种启动布局；两个镜像内都是带 WALT 的厂商内核。
#
# 用法: bash scripts/package.sh [dist_dir=artifacts] [out_zip]
#   示例: bash scripts/package.sh artifacts oneplus15-hmbird2.zip
set -euo pipefail

DIST="${1:-artifacts}"
OUT="${2:-oneplus15-hmbird2-$(date +%Y%m%d).zip}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AK3_URL="https://github.com/cctv18/AnyKernel3"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [[ ! -f "$DIST/boot.img" ]]; then
  echo "error: 缺少 $DIST/boot.img —— 请先跑 ./scripts/build.sh" >&2
  exit 1
fi

echo "==> 拉取 AnyKernel3 (cctv18 分支)"
if ! git clone --quiet --depth=1 "$AK3_URL" "$STAGE/ak3" 2>/dev/null; then
  echo "error: 拉取 $AK3_URL 失败" >&2
  exit 1
fi
cd "$STAGE/ak3"
rm -f Image zImage* dtb* boot.img vendor_boot.img 2>/dev/null || true

cat > anykernel.sh <<'AKEOF'
properties() { '
kernel.string=OnePlus15 SM8850 风驰内核 (厂商内核/OKI GKI, 含WALT; 保留官方 vendor_dlkm)
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
supported.versions=16
'; }
BLOCK=boot
IS_SLOT_DEVICE=auto
NO_MAGISK_CHECK=1
. tools/ak3-core.sh
ui_print "刷入 OnePlus15 风驰内核 (厂商内核, 含 WALT)..."
ui_print "刷 boot + vendor_boot；官方 vendor_dlkm 保留（风驰模块在其中）"
flash_generic boot;
if [ -f vendor_boot.img ]; then
  ui_print "刷 vendor_boot（兼容启动布局）..."
  flash_generic vendor_boot;
fi
sync
AKEOF

cp "$DIST/boot.img" boot.img
if [[ -f "$DIST/vendor_boot.img" ]]; then
  cp "$DIST/vendor_boot.img" vendor_boot.img
fi

chmod a+x anykernel.sh tools/* META-INF/com/google/android/update-binary 2>/dev/null || true

echo "==> 打包 $OUT"
if command -v zip >/dev/null 2>&1; then
  zip -r9 -q "$OUT" .
else
  python3 - "$OUT" <<'PY'
import sys, zipfile, os
out = sys.argv[1]
def add(z, base, rel=""):
    p = os.path.join(base, rel)
    if os.path.isdir(p):
        for name in sorted(os.listdir(p)):
            add(z, base, os.path.join(rel, name) if rel else name)
    else:
        with open(p, "rb") as f:
            data = f.read()
        info = zipfile.ZipInfo(rel, (2026, 1, 1, 0, 0, 0))
        info.external_attr = (0o755 if os.access(p, os.X_OK) else 0o644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, data)
with zipfile.ZipFile(out, "w") as z:
    add(z, ".")
PY
fi
mv "$OUT" "$ROOT/$OUT"
echo "==> 已生成可刷机包: $ROOT/$OUT"
ls -lh "$ROOT/$OUT"
