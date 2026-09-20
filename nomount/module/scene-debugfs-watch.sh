#!/system/bin/sh
MODDIR=${0%/*}
NMDIR=/data/adb/nomount
PKG=com.omarea.vtools
STATE="$NMDIR/scene_debugfs_state"
PATHS="$NMDIR/scene_debugfs_paths"
LOCK="$NMDIR/scene_debugfs_watch.lock"
SCAN_LOCK="$NMDIR/.scene_debugfs_scan.lock"
NEW="$NMDIR/.scene_paths.$$"
SORTED="$NEW.sorted"

[ -e /proc/pathhide ] || exit 0
mkdir -p "$NMDIR"

scene_installed() {
    grep -q "^$PKG " /data/system/packages.list 2>/dev/null
}

write_state() {
    printf 'status=%s\ncount=%s\nupdated=%s\n' "$1" \
        "$(grep -c . "$PATHS" 2>/dev/null)" "$(date +%s 2>/dev/null)" > "$STATE"
}

scan_mounts() {
    : > "$NEW"
    while IFS= read -r line; do
        case "$line" in *' - debugfs '*) ;; *) continue ;; esac
        left=${line%% - *}
        set -- $left
        [ "$#" -ge 5 ] || continue
        mountpoint=${5%/}
        case "$mountpoint" in /dev/*) ;; *) continue ;; esac
        case "$mountpoint" in *'..'*|*','*|*' '*|*\\*) continue ;; esac
        if ! grep -Fqx "$mountpoint" "$PATHS" 2>/dev/null; then
            [ -d "$mountpoint" ] || continue
            context=$(stat -c '%C' "$mountpoint" 2>/dev/null | head -n 1 | tr -d '\r')
            [ "$context" = u:object_r:debugfs:s0 ] || continue
        fi
        printf '%s\n' "$mountpoint" >> "$NEW"
    done < /proc/self/mountinfo
    sort -u "$NEW" > "$SORTED" 2>/dev/null && mv -f "$SORTED" "$NEW"
}

scan_once() {
    if ! mkdir "$SCAN_LOCK" 2>/dev/null; then
        scan_pid=$(cat "$SCAN_LOCK/pid" 2>/dev/null)
        if [ -n "$scan_pid" ] && kill -0 "$scan_pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$SCAN_LOCK/pid" 2>/dev/null
        rmdir "$SCAN_LOCK" 2>/dev/null || return 0
        mkdir "$SCAN_LOCK" 2>/dev/null || return 0
    fi
    printf '%s\n' "$$" > "$SCAN_LOCK/pid"
    if ! scene_installed; then
        : > "$NEW"
        status=no-package
    else
        scan_mounts
        if [ -s "$NEW" ]; then status=found; else status=not-found; fi
    fi
    if cmp -s "$NEW" "$PATHS" 2>/dev/null; then
        if [ -s "$PATHS" ]; then write_state applied; else write_state "$status"; fi
        rm -f "$NEW" "$SORTED"
        rm -f "$SCAN_LOCK/pid"
        rmdir "$SCAN_LOCK" 2>/dev/null
        return 0
    fi
    mv -f "$NEW" "$PATHS"
    if sh "$MODDIR/pathhide-apply.sh" >/dev/null 2>&1; then
        if [ -s "$PATHS" ]; then write_state applied; else write_state "$status"; fi
    else
        write_state apply-failed
        rm -f "$NEW" "$SORTED"
        rm -f "$SCAN_LOCK/pid"
        rmdir "$SCAN_LOCK" 2>/dev/null
        return 1
    fi
    rm -f "$NEW" "$SORTED"
    rm -f "$SCAN_LOCK/pid"
    rmdir "$SCAN_LOCK" 2>/dev/null
    return 0
}

case "${1:-}" in
    --once)
        scan_once
        exit $?
        ;;
    --event)
        sleep 1
        scan_once
        exit $?
        ;;
esac

if ! mkdir "$LOCK" 2>/dev/null; then
    old_pid=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        old_cmd=$(tr '\000' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null)
        case "$old_cmd" in *scene-debugfs-watch.sh*|*inotifyd*) exit 0 ;; esac
    fi
    rm -f "$LOCK/pid" 2>/dev/null
    rmdir "$LOCK" 2>/dev/null || exit 0
    mkdir "$LOCK" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null' EXIT HUP INT TERM
scan_once
command -v inotifyd >/dev/null 2>&1 || exit 0
exec inotifyd "$MODDIR/scene-debugfs-watch.sh --event" /dev:mynd
