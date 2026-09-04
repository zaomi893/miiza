#!/usr/bin/env bash
# 把自编 GKI 内核 Image 打包成 OnePlus 15 (SM8850/canoe) 可直接刷入的 AnyKernel3 zip。
#
# 刷入内容：
#   - boot <- artifacts/Image（OnePlus common GKI 内核，含 sched_ext = 风驰可用）
# 保留官方 init_boot / vendor_boot / vendor_dlkm（不改动）。
#
# 为什么刷 boot（不是 vendor_boot）：
#   - 官方 boot.img 就是 GKI 内核（OnePlus common 分支构建），用户刷 cctv18 到 boot 分区
#     会替换运行内核（风驰"有但不工作"），证明运行内核在 boot 分区。
#   - 风驰(HMBIRD II) 是 sched_ext BPF 调度器，由 ColorOS 用户态服务加载，只需内核
#     CONFIG_SCHED_CLASS_EXT=y。本内核用官方 OnePlus common 分支构建，与官方 boot.img 同源，
#     故风驰正常工作。
#   - Android 16 boot v4：boot 分区只放内核(Image)，ramdisk 在 init_boot 分区。AnyKernel3
#     的 flash_boot 从 Image 重建 boot（仅内核），init_boot 保持官方。
#
# 用法: bash scripts/package.sh [dist_dir=artifacts] [out_zip]
#   示例: bash scripts/package.sh artifacts oneplus15-hmbird2.zip
set -euo pipefail
DIST="${1:-artifacts}"
OUT="${2:-oneplus15-hmbird2-$(date +%Y%m%d).zip}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AK3_URL="https://github.com/cvhhji/AnyKernel3"
AK3_BRANCH="master"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
SRC_IMG="$ROOT/$DIST/Image"
if [[ ! -f "$SRC_IMG" ]]; then
  echo "error: 缺少 $DIST/Image —— 请先跑 ./scripts/build.sh" >&2
  exit 1
fi
echo "==> 拉取 AnyKernel3 (cvhhji/AnyKernel3 @ $AK3_BRANCH)"
AK3_CLONE_URL="$AK3_URL"
# 私有仓库需要 token 认证：优先用 GH_TOKEN，其次 GITHUB_TOKEN
if [[ -n "${GH_TOKEN:-}" ]]; then
  AK3_CLONE_URL="https://x-access-token:${GH_TOKEN}@github.com/cvhhji/AnyKernel3"
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AK3_CLONE_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/cvhhji/AnyKernel3"
fi
if ! git clone --quiet --depth=1 --branch "$AK3_BRANCH" "$AK3_CLONE_URL" "$STAGE/ak3" 2>/dev/null; then
  echo "error: 拉取 $AK3_URL 失败（如需认证请设置 GH_TOKEN 环境变量）" >&2
  exit 1
fi
cd "$STAGE/ak3"
rm -rf .git
rm -f Image zImage* dtb* boot.img vendor_boot.img 2>/dev/null || true
# 直接使用 cvhhji/AnyKernel3 仓库自带的 anykernel.sh（BLOCK=boot, split_boot, flash_boot, NO_MAGISK_CHECK=1），不覆盖
cp "$SRC_IMG" Image
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
