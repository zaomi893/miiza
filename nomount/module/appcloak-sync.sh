#!/system/bin/sh

SRC=/data/adb/nomount/hidden_apps.conf
SCOPE_SRC=/data/adb/nomount/scope_apps.conf
PATHHIDE_FLAG=/data/adb/nomount/appcloak_pathhide
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

if [ -e /proc/pathhide ]; then
    printf %s '@appcloak-clear' > /proc/pathhide 2>/dev/null || true
    if [ "$(cat "$PATHHIDE_FLAG" 2>/dev/null)" = "1" ]; then
        PKGMAP="$DIR/.packages.tsv"
        pm list packages -f -U 2>/dev/null | awk '
            {
                raw = $1
                sub(/^package:/, "", raw)
                last = 0
                for (i = 1; i <= length(raw); i++)
                    if (substr(raw, i, 1) == "=") last = i
                if (last > 1) {
                    path = substr(raw, 1, last - 1)
                    pkg = substr(raw, last + 1)
                    split($2, uidfield, ":")
                    uid = uidfield[2]
                    if (path ~ /^\// && pkg != "" && uid ~ /^[0-9]+$/) print pkg "\t" uid "\t" path
                }
            }' > "$PKGMAP" 2>/dev/null
        while IFS= read -r pkg; do
            [ -n "$pkg" ] || continue
            apk=$(awk -F '\t' -v pkg="$pkg" '$1 == pkg { print $3; exit }' "$PKGMAP" 2>/dev/null)
            case "$apk" in /*)
                apk_dir=$(dirname "$apk")
                printf '%s\n' "&$apk_dir/" > /proc/pathhide 2>/dev/null
                ;;
            esac
        done < "$DST"
        while IFS= read -r pkg; do
            [ -n "$pkg" ] || continue
            uid=$(awk -F '\t' -v pkg="$pkg" '$1 == pkg { print $2; exit }' "$PKGMAP" 2>/dev/null)
            case "$uid" in ''|*[!0-9]*) continue ;; esac
            if awk -F '\t' -v uid="$uid" 'NR == FNR { hidden[$1] = 1; next } $2 == uid && hidden[$1] { found = 1 } END { exit found ? 0 : 1 }' "$DST" "$PKGMAP" 2>/dev/null; then
                continue
            fi
            printf '%s\n' "@uid:$uid" > /proc/pathhide 2>/dev/null
        done < "$SCOPE_DST"
        rm -f "$PKGMAP" 2>/dev/null
    fi
fi
echo synced
