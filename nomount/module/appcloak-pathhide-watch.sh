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

if command -v inotifyd >/dev/null 2>&1; then
    exec inotifyd "$MODDIR/appcloak-pathhide-watch.sh --event" "$PKG_LIST:e"
fi

stamp=""
while sleep 300; do
    next=$(stat -c '%s:%Y' "$PKG_LIST" 2>/dev/null || echo '')
    if [ -n "$next" ] && [ "$next" != "$stamp" ]; then
        stamp="$next"
        sync_once
    fi
done
