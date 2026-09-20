#!/system/bin/sh
MODDIR=${0%/*}
NMDIR=/data/adb/nomount
PKG=com.omarea.vtools
STATE="$NMDIR/scene_debugfs_state"
PATHS="$NMDIR/scene_debugfs_paths"
SIGNATURE="$NMDIR/scene_debugfs_signature"
LOCK="$NMDIR/scene_debugfs_watch.lock"
SCAN_LOCK="$NMDIR/.scene_debugfs_scan.lock"
NEW="$NMDIR/.scene_paths.$$"
NEW_SIGNATURE="$NMDIR/.scene_signature.$$"
SORTED="$NEW.sorted"
SORTED_SIGNATURE="$NEW_SIGNATURE.sorted"

[ -e /proc/pathhide ] || exit 0
mkdir -p "$NMDIR"

scene_installed() {
    grep -q "^$PKG " /data/system/packages.list 2>/dev/null
}

write_state() {
    printf 'status=%s\ncount=%s\nupdated=%s\n' "$1" \
        "$(grep -c . "$PATHS" 2>/dev/null)" "$(date +%s 2>/dev/null)" > "$STATE"
}

release_scan_lock() {
    rm -f "$NEW" "$NEW_SIGNATURE" "$SORTED" "$SORTED_SIGNATURE" "$SCAN_LOCK/pid"
    rmdir "$SCAN_LOCK" 2>/dev/null
}

take_scan_lock() {
    if mkdir "$SCAN_LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$SCAN_LOCK/pid"
        return 0
    fi
    scan_pid=$(cat "$SCAN_LOCK/pid" 2>/dev/null)
    if [ -n "$scan_pid" ] && kill -0 "$scan_pid" 2>/dev/null; then
        return 1
    fi
    rm -f "$SCAN_LOCK/pid" 2>/dev/null
    rmdir "$SCAN_LOCK" 2>/dev/null || return 1
    mkdir "$SCAN_LOCK" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$SCAN_LOCK/pid"
}

scan_mounts() {
    : > "$NEW"
    : > "$NEW_SIGNATURE"
    while IFS= read -r line; do
        case "$line" in *' - debugfs '*) ;; *) continue ;; esac
        left=${line%% - *}
        set -- $left
        [ "$#" -ge 5 ] || continue
        mount_id=$1
        mountpoint=${5%/}
        case "$mountpoint" in /dev/*) ;; *) continue ;; esac
        case "$mountpoint" in *'..'*|*','*|*' '*|*\\*) continue ;; esac
        if ! grep -Fqx "$mountpoint" "$PATHS" 2>/dev/null; then
            [ -d "$mountpoint" ] || continue
            context=$(stat -c '%C' "$mountpoint" 2>/dev/null | head -n 1 | tr -d '\r')
            [ "$context" = u:object_r:debugfs:s0 ] || continue
        fi
        printf '%s\n' "$mountpoint" >> "$NEW"
        printf '%s:%s\n' "$mount_id" "$mountpoint" >> "$NEW_SIGNATURE"
    done < /proc/self/mountinfo
    sort -u "$NEW" > "$SORTED" 2>/dev/null && mv -f "$SORTED" "$NEW"
    sort -u "$NEW_SIGNATURE" > "$SORTED_SIGNATURE" 2>/dev/null && \
        mv -f "$SORTED_SIGNATURE" "$NEW_SIGNATURE"
}

scan_once() {
    take_scan_lock || return 0
    if ! scene_installed; then
        : > "$NEW"
        : > "$NEW_SIGNATURE"
        status=no-package
    else
        scan_mounts
        if [ -s "$NEW" ]; then status=found; else status=not-found; fi
    fi
    if cmp -s "$NEW" "$PATHS" 2>/dev/null && \
       cmp -s "$NEW_SIGNATURE" "$SIGNATURE" 2>/dev/null; then
        [ -f "$STATE" ] || write_state "$status"
        release_scan_lock
        return 0
    fi
    mv -f "$NEW" "$PATHS"
    mv -f "$NEW_SIGNATURE" "$SIGNATURE"
    if sh "$MODDIR/pathhide-apply.sh" >/dev/null 2>&1; then
        if [ -s "$PATHS" ]; then write_state applied; else write_state "$status"; fi
    else
        write_state apply-failed
        release_scan_lock
        return 1
    fi
    release_scan_lock
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
        case "$old_cmd" in *scene-debugfs-watch.sh*) exit 0 ;; esac
    fi
    rm -f "$LOCK/pid" 2>/dev/null
    rmdir "$LOCK" 2>/dev/null || exit 0
    mkdir "$LOCK" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" > "$LOCK/pid"
event_pid=""
stop_watcher() {
    if [ -n "$event_pid" ] && kill -0 "$event_pid" 2>/dev/null; then
        event_cmd=$(tr '\000' ' ' < "/proc/$event_pid/cmdline" 2>/dev/null)
        case "$event_cmd" in *inotifyd*) kill "$event_pid" 2>/dev/null ;; esac
    fi
    event_pid=""
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null
}
trap stop_watcher EXIT
trap 'stop_watcher; exit 0' HUP INT TERM

scan_once
if command -v inotifyd >/dev/null 2>&1; then
    inotifyd "$MODDIR/scene-debugfs-watch.sh --event" /dev:mynd >/dev/null 2>&1 &
    event_pid=$!
else
    for busybox_path in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
        [ -x "$busybox_path" ] || continue
        "$busybox_path" inotifyd "$MODDIR/scene-debugfs-watch.sh --event" /dev:mynd \
            >/dev/null 2>&1 &
        event_pid=$!
        break
    done
fi

fast_until=$(( $(date +%s 2>/dev/null) + 120 ))
while [ -e /proc/pathhide ] && [ ! -e "$MODDIR/disable" ] && [ ! -e "$MODDIR/remove" ]; do
    now=$(date +%s 2>/dev/null)
    if [ -s "$PATHS" ]; then
        delay=120
    elif [ "$now" -lt "$fast_until" ]; then
        delay=5
    else
        delay=30
    fi
    sleep "$delay"
    scan_once
done
