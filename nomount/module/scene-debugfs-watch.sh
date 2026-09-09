#!/system/bin/sh
# Adapted from LKM-PathMask 2.7.2: discover only the official Scene package's
# randomized debugfs mount under /dev. Scene may create it long after boot, so
# boot mode backs off after ten minutes and watches for up to 24 hours.
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
if [ "$1" != "--once" ]; then
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
fi

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
        # Once PathMask is active, stat(2) on the target correctly returns
        # ENOENT even to this root watcher. A path already authenticated and
        # still present as the exact debugfs mount is therefore reusable.
        if ! grep -Fqx "${_mp%/}" "$PATHS" 2>/dev/null; then
            [ -d "$_mp" ] || continue
            _ctx=$(stat -c '%C' "$_mp" 2>/dev/null | head -n 1 | tr -d '\r')
            [ "$_ctx" = u:object_r:debugfs:s0 ] || continue
        fi
        # Store the exact mount point. The in-kernel directory rule already
        # covers descendants; a synthetic trailing slash can make the exact
        # mount path fail a textual match before its inode has been resolved.
        printf '%s\n' "${_mp%/}" >> "$NMDIR/.scene_paths.new"
    done < /proc/self/mountinfo
    sort -u "$NMDIR/.scene_paths.new" > "$NMDIR/.scene_paths.sorted" 2>/dev/null &&
        mv -f "$NMDIR/.scene_paths.sorted" "$NMDIR/.scene_paths.new"
    [ -s "$NMDIR/.scene_paths.new" ]
}

_apply_found() {
    mv -f "$NMDIR/.scene_paths.new" "$PATHS"
    printf 'status=found\ncount=%s\nupdated=%s\n' \
        "$(grep -c . "$PATHS" 2>/dev/null)" "$(date +%s 2>/dev/null)" > "$STATE"
    if sh "$MODDIR/pathhide-apply.sh" >/dev/null 2>&1; then
        printf 'status=applied\ncount=%s\nupdated=%s\n' \
            "$(grep -c . "$PATHS" 2>/dev/null)" "$(date +%s 2>/dev/null)" > "$STATE"
        return 0
    fi
    printf 'status=apply-failed\ncount=%s\nupdated=%s\n' \
        "$(grep -c . "$PATHS" 2>/dev/null)" "$(date +%s 2>/dev/null)" > "$STATE"
    return 1
}

if [ "$1" = "--once" ]; then
    if _find_scene_mounts; then _apply_found; exit $?; fi
    rm -f "$NMDIR/.scene_paths.new"
    printf 'status=not-found\nupdated=%s\n' "$(date +%s 2>/dev/null)" > "$STATE"
    exit 0
fi

_i=0
while [ "$_i" -lt 3180 ]; do
    if _find_scene_mounts; then
        _apply_found
        exit $?
    fi
    if [ "$_i" -lt 300 ]; then sleep 2; else sleep 30; fi
    _i=$((_i + 1))
done
rm -f "$NMDIR/.scene_paths.new"
printf 'status=not-found\nupdated=%s\n' "$(date +%s 2>/dev/null)" > "$STATE"
