#!/system/bin/sh

MODDIR=${0%/*}
SYS=/sys/block/zram0
CONFIG=$MODDIR/zram_config.conf
SIZES="8589934592 12884901888 17179869184 25769803776"

read_algorithms() {
  tr -d '[]' < "$SYS/comp_algorithm" 2>/dev/null
}

active_algorithm() {
  sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$SYS/comp_algorithm" 2>/dev/null
}

has_algorithm() {
  case " $(read_algorithms) " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

zram_device() {
  if [ -e /dev/block/zram0 ]; then
    echo /dev/block/zram0
  else
    echo /dev/zram0
  fi
}

wait_key() {
  getevent -qt 1 >/dev/null 2>&1
  while true; do
    event=$(getevent -lqc 1 2>/dev/null | {
      while read -r line; do
        case "$line" in
          *KEY_VOLUMEDOWN*DOWN*) echo down; break ;;
          *KEY_VOLUMEUP*DOWN*) echo up; break ;;
          *KEY_POWER*DOWN*) input keyevent KEY_POWER; echo power; break ;;
        esac
      done
    })
    [ -n "$event" ] && { echo "$event"; return; }
    usleep 50000
  done
}

apply_zram() {
  alg=$1
  size=$2
  dev=$(zram_device)
  has_algorithm "$alg" || return 1
  [ -e "$dev" ] || return 1
  swapoff "$dev" 2>/dev/null || true
  echo 1 > "$SYS/reset" || return 1
  echo "$alg" > "$SYS/comp_algorithm" || return 1
  echo "$size" > "$SYS/disksize" || return 1
  mkswap "$dev" >/dev/null 2>&1 || return 1
  swapon -p 32767 "$dev" >/dev/null 2>&1 || return 1
}

[ -r "$SYS/comp_algorithm" ] || {
  echo "未找到内核 ZRAM 压缩算法接口"
  exit 1
}

ALGORITHMS=$(read_algorithms)
[ -n "$ALGORITHMS" ] || {
  echo "内核没有报告可用的 ZRAM 压缩算法"
  exit 1
}

current_alg=$(active_algorithm)
alg_count=$(echo "$ALGORITHMS" | wc -w)
index=0
for alg in $ALGORITHMS; do
  [ "$alg" = "$current_alg" ] && break
  index=$((index + 1))
done
[ "$index" -lt "$alg_count" ] || index=0

current_size=$(cat "$SYS/disksize" 2>/dev/null || echo 0)
size_count=$(echo "$SIZES" | wc -w)
size_index=0
i=0
for size in $SIZES; do
  [ "$size" = "$current_size" ] && { size_index=$i; break; }
  i=$((i + 1))
done

while true; do
  clear
  selected_alg=$(echo "$ALGORITHMS" | cut -d' ' -f$((index + 1)))
  selected_size=$(echo "$SIZES" | cut -d' ' -f$((size_index + 1)))
  echo "ZRAM 压缩配置"
  echo "------------------------------"
  echo "内核支持: $ALGORITHMS"
  echo "当前算法: $current_alg"
  echo "选择算法: $selected_alg"
  echo "选择大小: $(awk -v n="$selected_size" 'BEGIN { printf "%.0f GB", n/1073741824 }')"
  echo "------------------------------"
  echo "音量下：切换算法"
  echo "音量上：切换大小"
  echo "电源键：应用并退出"
  case $(wait_key) in
    down) index=$(( (index + 1) % alg_count )) ;;
    up) size_index=$(( (size_index + 1) % size_count )) ;;
    power)
      if apply_zram "$selected_alg" "$selected_size"; then
        {
          echo "algorithm=$selected_alg"
          echo "size=$selected_size"
        } > "$CONFIG"
        chmod 0600 "$CONFIG"
        echo "已应用：$selected_alg"
        exit 0
      fi
      echo "应用失败，原配置不会保存"
      exit 1
      ;;
  esac
done
