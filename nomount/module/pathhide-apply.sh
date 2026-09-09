#!/system/bin/sh
# Atomically rebuild the built-in PathHide table from durable user paths and
# the current boot's randomized Scene debugfs paths. Global scope makes every
# process see these file paths as absent; it is independent of NoMount's UID
# injection blocklist.
NMDIR=/data/adb/nomount
[ -e /proc/pathhide ] || exit 0

printf %s - > /proc/pathhide 2>/dev/null || exit 1
for _conf in "$NMDIR/pathhide.conf" "$NMDIR/scene_debugfs_paths"; do
    [ -f "$_conf" ] || continue
    while IFS= read -r _path; do
        _path=$(printf '%s' "$_path" | tr -d '\r')
        case "$_path" in /*) printf '%s' "+$_path" > /proc/pathhide 2>/dev/null ;; esac
    done < "$_conf"
done
# Set the scope after adding rules. An empty in-kernel table has no scope field
# to update; writing this last also supports kernels whose first-rule default
# predates global PathMask.
printf %s @global > /proc/pathhide 2>/dev/null || true
