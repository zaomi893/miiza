#!/system/bin/sh
# Publish NoMount's package list for the built-in AppCloak system-server filter.

SRC=/data/adb/nomount/hidden_apps.conf
SCOPE_SRC=/data/adb/nomount/scope_apps.conf
DIR=/data/system/nomount_appcloak
DST="$DIR/hidden_apps.conf"
SCOPE_DST="$DIR/scope_apps.conf"
ACTIVE="$DIR/active"
STATUS="$DIR/status"

if [ "$1" = "--status" ]; then
    if [ -s "$ACTIVE" ]; then
        echo active
    elif [ -s "$STATUS" ]; then
        cat "$STATUS"
    elif [ -f "$DST" ] && [ -s /data/adb/modules/meta-nomount/classes.dex ] && \
         [ -s /data/adb/modules/meta-nomount/zygisk/arm64-v8a.so ]; then
        echo waiting
    else
        echo missing
    fi
    exit 0
fi

[ "$1" = "--boot-prepare" ] && rm -f "$ACTIVE" "$STATUS"

mkdir -p "$DIR" || exit 1
TMP="$DIR/.hidden_apps.new"
SCOPE_TMP="$DIR/.scope_apps.new"
sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$SRC" 2>/dev/null | \
    grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' | sort -u > "$TMP"
sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$SCOPE_SRC" 2>/dev/null | \
    grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' | sort -u > "$SCOPE_TMP"
chown system:system "$DIR" "$TMP" "$SCOPE_TMP" 2>/dev/null
chmod 0700 "$DIR" 2>/dev/null
chmod 0600 "$TMP" "$SCOPE_TMP" 2>/dev/null
restorecon -RF "$DIR" 2>/dev/null
mv -f "$TMP" "$DST"
mv -f "$SCOPE_TMP" "$SCOPE_DST"
echo synced
