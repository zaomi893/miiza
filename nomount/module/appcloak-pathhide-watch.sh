#!/system/bin/sh
MODDIR="${0%/*}"
PKG_LIST=/data/system/packages.list

sync_once() {
    [ -f "$MODDIR/appcloak-sync.sh" ] && sh "$MODDIR/appcloak-sync.sh" >/dev/null 2>&1
}

if [ "$1" = "--event" ]; then
    sleep 1
    sync_once
    exit 0
fi

while [ ! -f "$PKG_LIST" ]; do
    sleep 10
done
sync_once

command -v inotifyd >/dev/null 2>&1 || exit 0
exec inotifyd "$MODDIR/appcloak-pathhide-watch.sh --event" "$PKG_LIST:e"
