#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-$ROOT/artifacts/Image}"
OUTPUT="${2:-$ROOT/oneplus15-stock-hmbird-gki.zip}"
AK3_COMMIT="${AK3_COMMIT:-020dfeccf9d7e962a48400fc94d3e451df92eead}"
WORK="$ROOT/ak3_workspace"

[[ -s "$IMAGE" ]] || { echo "error: missing Image: $IMAGE" >&2; exit 1; }
bash "$ROOT/scripts/verify_image.sh" "$IMAGE"

rm -rf "$WORK"
git clone --quiet --no-checkout https://github.com/osm0sis/AnyKernel3.git "$WORK"
git -C "$WORK" checkout --quiet "$AK3_COMMIT"
rm -rf "$WORK/.git"

# Replace the upstream example installer completely.  Its sample OMAP block
# path and Tuna ramdisk edits are not valid for a modern OnePlus A/B device.
# This installer touches boot in the active slot only and leaves init_boot,
# vendor_boot and vendor_dlkm (which contains HMBIRD) unchanged.
cat > "$WORK/anykernel.sh" <<'EOF'
### AnyKernel3 Ramdisk Mod Script
## OnePlus 15 stock-HMBIRD GKI

properties() { '
kernel.string=OnePlus 15 stock-HMBIRD GKI by cvhhji
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=infiniti
device.name2=PLK110
device.name3=CPH2745
device.name4=CPH2747
device.name5=CPH2749
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

ui_print "OnePlus 15 stock-HMBIRD GKI";
split_boot;
if [ -f split_img/ramdisk.cpio ]; then
  unpack_ramdisk;
  write_boot;
else
  flash_boot;
fi;
EOF
cp "$IMAGE" "$WORK/Image"

cat > "$WORK/hmbird-stock-baseline.txt" <<'EOF'
OnePlus 15 stock-compatible GKI
Expected kernel: 6.12.23-android16-5-gb2a876903b49-ab14541642-4k
This zip only replaces boot/Image.
Keep the matching official init_boot, vendor_boot and vendor_dlkm installed.
EOF

rm -f "$OUTPUT"
(cd "$WORK" && zip -r9 -q "$OUTPUT" . -x '*.git*')
[[ -s "$OUTPUT" ]] || { echo "error: package was not created" >&2; exit 1; }
echo "Flashable zip: $OUTPUT"
