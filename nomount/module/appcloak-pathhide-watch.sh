#!/system/bin/sh
# Keep the optional AppCloak PathHide supplement aligned with package changes.
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

# Modern KSU/Magisk BusyBox provides inotifyd. If a minimal environment does
# not, keep the boot-time sync and exit instead of waking the device forever
# for a five-minute polling fallback; the next boot/WebUI apply refreshes it.
command -v inotifyd >/dev/null 2>&1 || exit 0
exec inotifyd "$MODDIR/appcloak-pathhide-watch.sh --event" "$PKG_LIST:e"
