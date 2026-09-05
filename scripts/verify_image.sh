#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: verify_image.sh IMAGE [kernel-out]}"
OUT="${2:-}"
EXPECTED="${STOCK_RELEASE:-6.12.23-android16-5-gb2a876903b49-ab14541642-4k}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "INCOMPATIBLE: $*" >&2; exit 1; }
[[ -s "$IMAGE" ]] || die "Image is missing or empty"

version="$(grep -aoE 'Linux version 6\.12\.23-[^ ]+' "$IMAGE" | head -1 || true)"
grep -aFq "Linux version $EXPECTED " "$IMAGE" ||
  die "release mismatch; expected $EXPECTED, got: ${version:-unknown}"

for marker in sched_ext init_sched_ext_class BTF; do
  grep -aFq "$marker" "$IMAGE" || die "Image marker missing: $marker"
done

if [[ -n "$OUT" ]]; then
  [[ -f "$OUT/.config" && -f "$OUT/System.map" && -f "$OUT/Module.symvers" ]] ||
    die "build metadata is incomplete"
  grep -q '[[:space:]]init_sched_ext_class$' "$OUT/System.map" ||
    die "sched_ext class is not linked"
  awk '$2 == "__tracepoint_android_vh_scx_restore_flags" { found = 1 }
       END { exit !found }' "$OUT/Module.symvers" ||
    die "stock HMBIRD restore-flags hook is not exported"

  required="$OUT/oplus-required-symbols"
  exported="$OUT/exported-symbols"
  missing="$OUT/oplus-missing-symbols"
  awk '
    /^\[abi_symbol_list\]$/ { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print
    }
  ' "$ROOT/source/kernel_platform/common/gki/aarch64/symbols/oplus" | LC_ALL=C sort -u > "$required"
  awk '{print $2}' "$OUT/Module.symvers" | LC_ALL=C sort -u > "$exported"
  comm -23 "$required" "$exported" > "$missing"
  [[ ! -s "$missing" ]] || {
    head -40 "$missing" >&2
    die "stock OPlus KMI exports are missing"
  }

  llvm-readelf -S "$OUT/vmlinux" | grep -q '[.]BTF' || die "vmlinux has no BTF section"
fi

echo "PASS: stock release string: $EXPECTED"
echo "PASS: sched_ext, BPF/BTF markers and HMBIRD KMI hook are present"
echo "PASS: official vendor_boot and vendor_dlkm can remain untouched"
