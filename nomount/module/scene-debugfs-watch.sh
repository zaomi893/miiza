#!/system/bin/sh
# Adapted from LKM-PathMask 2.7.2: discover only the official Scene package's
# randomized debugfs mount under /dev and stop after ten minutes.  No perpetual
# daemon/timer remains after discovery or timeout.
MODDIR=${0%/*}
NMDIR=/data/adb/nomount
PKG=com.omarea.vtools
STATE="$NMDIR/scene_debugfs_state"
PATHS="$NMDIR/scene_debugfs_paths"
LOCK="$NMDIR/scene_debugfs_watch.lock"

[ -e /proc/pathhide ] || exit 0
grep -q "^$PKG " /data/system/packages.list 2>/dev/null || {
    printf 'status=no-package\n' > "$STATE"
    : > "$PATHS"
    exit 0
}
if ! mkdir "$LOCK" 2>/dev/null; then
    _old_pid=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
        _old_cmd=$(tr '\000' ' ' < "/proc/$_old_pid/cmdline" 2>/dev/null)
        case "$_old_cmd" in *scene-debugfs-watch.sh*) exit 0 ;; esac
    fi
    rm -f "$LOCK/pid" 2>/dev/null
    rmdir "$LOCK" 2>/dev/null || exit 0
    mkdir "$LOCK" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null
trap 'rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' EXIT HUP INT TERM

_find_scene_mounts() {
    : > "$NMDIR/.scene_paths.new"
    while IFS= read -r _line; do
        case "$_line" in *' - debugfs '*) ;; *) continue ;; esac
        _left=${_line%% - *}
        set -- $_left
        [ "$#" -ge 5 ] || continue
        _mp=$5
        case "$_mp" in /dev/*) ;; *) continue ;; esac
        case "$_mp" in *'..'*|*','*|*' '*|*\\*) continue ;; esac
        [ -d "$_mp" ] || continue
        _ctx=$(stat -c '%C' "$_mp" 2>/dev/null | head -n 1 | tr -d '\r')
        [ "$_ctx" = u:object_r:debugfs:s0 ] || continue
        # Store the exact mount point. The in-kernel directory rule already
        # covers descendants; a synthetic trailing slash can make the exact
        # mount path fail a textual match before its inode has been resolved.
        printf '%s\n' "${_mp%/}" >> "$NMDIR/.scene_paths.new"
    done < /proc/self/mountinfo
    sort -u "$NMDIR/.scene_paths.new" > "$NMDIR/.scene_paths.sorted" 2>/dev/null &&
        mv -f "$NMDIR/.scene_paths.sorted" "$NMDIR/.scene_paths.new"
    [ -s "$NMDIR/.scene_paths.new" ]
}

_i=0
while [ "$_i" -lt 300 ]; do
    if _find_scene_mounts; then
        mv -f "$NMDIR/.scene_paths.new" "$PATHS"
        printf 'status=found\ncount=%s\nupdated=%s\n' \
            "$(grep -c . "$PATHS" 2>/dev/null)" "$(date +%s 2>/dev/null)" > "$STATE"
        if sh "$MODDIR/pathhide-apply.sh" >/dev/null 2>&1; then
            printf 'status=applied\ncount=%s\nupdated=%s\n' \
                "$(grep -c . "$PATHS" 2>/dev/null)" "$(date +%s 2>/dev/null)" > "$STATE"
            exit 0
        fi
        printf 'status=apply-failed\ncount=%s\nupdated=%s\n' \
            "$(grep -c . "$PATHS" 2>/dev/null)" "$(date +%s 2>/dev/null)" > "$STATE"
        exit 1
    fi
    sleep 2
    _i=$((_i + 1))
done
rm -f "$NMDIR/.scene_paths.new"
printf 'status=not-found\nupdated=%s\n' "$(date +%s 2>/dev/null)" > "$STATE"
