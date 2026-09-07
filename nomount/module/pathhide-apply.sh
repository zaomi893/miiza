#!/system/bin/sh
# Atomically rebuild the built-in PathHide table from durable user paths and
# the current boot's randomized Scene debugfs paths.  Deny scope means only
# apps selected in NoMount's per-UID list see the paths as absent.
NMDIR=/data/adb/nomount
[ -e /proc/pathhide ] || exit 0

echo - > /proc/pathhide 2>/dev/null || exit 1
echo @deny > /proc/pathhide 2>/dev/null || true
for _conf in "$NMDIR/pathhide.conf" "$NMDIR/scene_debugfs_paths"; do
    [ -f "$_conf" ] || continue
    while IFS= read -r _path; do
        _path=$(printf '%s' "$_path" | tr -d '\r')
        case "$_path" in /*) echo "+$_path" > /proc/pathhide 2>/dev/null ;; esac
    done < "$_conf"
done
