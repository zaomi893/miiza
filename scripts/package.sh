#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-$ROOT/artifacts/Image}"
OUTPUT="${2:-$ROOT/oneplus15-stock-hmbird-gki.zip}"
AK3_COMMIT="${AK3_COMMIT:-f1008ba4ef4a6ff9c188a89f40a1d1cc977829f0}"
WORK="$ROOT/ak3_workspace"

[[ -s "$IMAGE" ]] || { echo "error: missing Image: $IMAGE" >&2; exit 1; }
bash "$ROOT/scripts/verify_image.sh" "$IMAGE"

rm -rf "$WORK"
git clone --quiet --no-checkout https://github.com/cvhhji/AnyKernel3.git "$WORK"
git -C "$WORK" checkout --quiet "$AK3_COMMIT"
rm -rf "$WORK/.git"

# Restrict the package to OnePlus 15 identifiers. The package replaces only
# boot/Image; init_boot, vendor_boot and vendor_dlkm are never included.
sed -i 's/^do.devicecheck=.*/do.devicecheck=1/' "$WORK/anykernel.sh"
sed -i 's/^device.name1=.*/device.name1=infiniti/' "$WORK/anykernel.sh"
sed -i 's/^device.name2=.*/device.name2=PLK110/' "$WORK/anykernel.sh"
sed -i 's/^device.name3=.*/device.name3=CPH2745/' "$WORK/anykernel.sh"
sed -i 's/^device.name4=.*/device.name4=CPH2747/' "$WORK/anykernel.sh"
sed -i 's/^device.name5=.*/device.name5=CPH2749/' "$WORK/anykernel.sh"
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
