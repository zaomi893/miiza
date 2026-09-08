#!/system/bin/sh
# Synchronize NoMount's package-visibility policy into the integrated HMA-OSS
# system-server backend. The backend watches this file by mtime and never needs
# config.json rewriting or a framework restart.

NMDIR=/data/adb/nomount
SRC="$NMDIR/hidden_apps.conf"

find_backend_dir() {
    for d in /data/misc/hide_my_applist_nomount_*; do
        [ -d "$d" ] || continue
        printf '%s\n' "$d"
        return 0
    done
    return 1
}

DIR="$(find_backend_dir)"
if [ "$1" = "--status" ]; then
    [ -n "$DIR" ] && [ -f "$DIR/nomount_hidden_apps.conf" ] && echo ready || echo missing
    exit 0
fi

[ -n "$DIR" ] || { echo missing; exit 1; }
TMP="$DIR/.nomount_hidden_apps.new"
sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$SRC" 2>/dev/null | \
    grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' | sort -u > "$TMP"
chown system:system "$TMP" 2>/dev/null
chmod 0600 "$TMP" 2>/dev/null
if [ -e "$DIR/config.json" ]; then
    chcon --reference="$DIR/config.json" "$TMP" 2>/dev/null || restorecon "$TMP" 2>/dev/null
else
    restorecon "$TMP" 2>/dev/null
fi
mv -f "$TMP" "$DIR/nomount_hidden_apps.conf"
echo synced
