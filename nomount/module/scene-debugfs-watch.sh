#!/system/bin/sh
MODDIR=${0%/*}
NMDIR=/data/adb/nomount
STATE="$NMDIR/scene_debugfs_state"
PATHS="$NMDIR/scene_debugfs_paths"
SCAN_LOCK="$NMDIR/.scene_debugfs_scan.lock"
NEW="$NMDIR/.scene_paths.$$"
SORTED="$NEW.sorted"

[ -e /proc/pathhide ] || exit 0
mkdir -p "$NMDIR"

write_state() {
    printf 'status=%s\ncount=%s\nupdated=%s\n' "$1" \
        "$(grep -c . "$PATHS" 2>/dev/null)" "$(date +%s 2>/dev/null)" > "$STATE"
}

release_scan_lock() {
    rm -f "$NEW" "$SORTED" "$SCAN_LOCK/pid"
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

scan_paths() {
    : > "$NEW"
    for marker in /dev/*/scene_mode_category; do
        [ -e "$marker" ] || continue
        parent=${marker%/*}
        case "$parent" in /dev/*) ;; *) continue ;; esac
        case "$parent" in *'..'*|*','*|*' '*|*\\*) continue ;; esac
        printf '%s\n' "$parent" >> "$NEW"
    done
    [ -e /dev/cpuset/scene-daemon ] && printf '%s\n' /dev/cpuset/scene-daemon >> "$NEW"
    sort -u "$NEW" > "$SORTED" 2>/dev/null && mv -f "$SORTED" "$NEW"
}

scan_once() {
    take_scan_lock || return 0
    scan_paths
    if [ -s "$NEW" ]; then status=found; else status=not-found; fi
    if [ ! -s "$NEW" ] && [ -s "$PATHS" ]; then
        write_state retained
        release_scan_lock
        return 0
    fi
    if cmp -s "$NEW" "$PATHS" 2>/dev/null; then
        [ -f "$STATE" ] || write_state "$status"
        release_scan_lock
        return 0
    fi
    mv -f "$NEW" "$PATHS"
    if sh "$MODDIR/pathhide-apply.sh" >/dev/null 2>&1; then
        if [ -s "$PATHS" ]; then write_state applied; else write_state "$status"; fi
    else
        write_state apply-failed
        release_scan_lock
        return 1
    fi
    release_scan_lock
}

scan_once
exit $?
