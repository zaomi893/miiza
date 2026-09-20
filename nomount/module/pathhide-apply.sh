#!/system/bin/sh
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
printf %s @global > /proc/pathhide 2>/dev/null || true

[ -f "${0%/*}/appcloak-sync.sh" ] && sh "${0%/*}/appcloak-sync.sh" >/dev/null 2>&1
