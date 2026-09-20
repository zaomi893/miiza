#!/system/bin/sh
MODDIR=${0%/*}
NMDIR=/data/adb/nomount
LOG="$NMDIR/absorb.log"
[ -f "$NMDIR/disabled" ] && exit 0
ABI=$(getprop ro.product.cpu.abi)
BIN="$MODDIR/bin/$ABI/nomount"
[ -x "$BIN" ] || exit 0
mkdir -p "$NMDIR"
{
    printf 'stage=early time=%s\n' "$(date +%s 2>/dev/null)"
    timeout 60 "$BIN" absorb --early
    printf 'status=%s\n' "$?"
} > "$LOG" 2>&1
exit 0
