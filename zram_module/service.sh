#!/system/bin/sh

MODDIR=${0%/*}
CONFIG=$MODDIR/zram_config.conf
SYS=/sys/block/zram0

[ -f "$CONFIG" ] || exit 0

tries=0
while [ ! -r "$SYS/comp_algorithm" ] && [ "$tries" -lt 60 ]; do
  sleep 1
  tries=$((tries + 1))
done
[ -r "$SYS/comp_algorithm" ] || exit 1

algorithm=$(sed -n 's/^algorithm=\([A-Za-z0-9_-]*\)$/\1/p' "$CONFIG" | head -n 1)
size=$(sed -n 's/^size=\([0-9]*\)$/\1/p' "$CONFIG" | head -n 1)
[ -n "$algorithm" ] && [ -n "$size" ] || exit 1

available=$(tr -d '[]' < "$SYS/comp_algorithm")
case " $available " in
  *" $algorithm "*) ;;
  *) exit 1 ;;
esac

if [ -e /dev/block/zram0 ]; then
  dev=/dev/block/zram0
else
  dev=/dev/zram0
fi
[ -e "$dev" ] || exit 1

swapoff "$dev" 2>/dev/null || true
echo 1 > "$SYS/reset" || exit 1
echo "$algorithm" > "$SYS/comp_algorithm" || exit 1
echo "$size" > "$SYS/disksize" || exit 1
mkswap "$dev" >/dev/null 2>&1 || exit 1
swapon -p 32767 "$dev" >/dev/null 2>&1
