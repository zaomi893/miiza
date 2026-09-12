#!/system/bin/sh
# Refresh auto-selected application-hide sources on demand from the WebUI.
# APKs are rescanned only when the installed package/path inventory changes.
NMDIR=/data/adb/nomount
CACHE="$NMDIR/xposed_cache"
INDEX="$NMDIR/xposed_packages"
HMA_CACHE="$NMDIR/hma_blacklist_cache"
NEW="$NMDIR/.xposed_packages.new"
CHANGED="$NMDIR/.xposed_packages.changed"
REMOVED="$NMDIR/.xposed_packages.removed"
SCAN_OUT="$NMDIR/.xposed_scan.new"
CACHE_TMP="$NMDIR/.xposed_cache.tmp"
LOCK="$NMDIR/.xposed_scan.lock"
mkdir -p "$NMDIR" && chmod 0700 "$NMDIR"

if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
        rm -rf "$LOCK"
        mkdir "$LOCK" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

if [ -f "$INDEX" ] && [ "$(head -n1 "$INDEX" 2>/dev/null)" = "# scan-v2" ]; then
    sed '1d' "$INDEX" > "$NMDIR/.xposed_packages.old"
    mv -f "$NMDIR/.xposed_packages.old" "$INDEX"
fi

pm list packages -f 2>/dev/null | sort > "$NEW"
if [ ! -f "$INDEX" ]; then
    cp -f "$NEW" "$CHANGED"
    : > "$REMOVED"
elif cmp -s "$NEW" "$INDEX" 2>/dev/null; then
    rm -f "$NEW" "$CHANGED" "$REMOVED" "$SCAN_OUT" "$CACHE_TMP"
else
    comm -13 "$INDEX" "$NEW" > "$CHANGED"
    comm -23 "$INDEX" "$NEW" > "$REMOVED"
fi

if [ -f "$CHANGED" ]; then
    J=$(( $(nproc 2>/dev/null || echo 4) / 2 ))
    [ "$J" -gt 4 ] && J=4
    [ "$J" -lt 1 ] && J=1
    : > "$SCAN_OUT"
    if [ -s "$CHANGED" ]; then
        tr '\n' '\0' < "$CHANGED" | xargs -0 -P "$J" -n1 sh -c '
        line="$1"
        apk="${line%=*}"; apk="${apk#package:}"; pkg="${line##*=}"
        [ -f "$apk" ] || exit 0
        if timeout 4 unzip -l "$apk" 2>/dev/null | grep -qaE "assets/xposed_init|META-INF/xposed/"; then
            printf "%s\t%s\n" "$pkg" "$apk"; exit 0
        fi
        timeout 4 unzip -p "$apk" AndroidManifest.xml 2>/dev/null | tr -d "\000" | \
            grep -qaE "xposedmodule|xposedminversion|xposeddescription|XposedProvider|libxposed" && \
            printf "%s\t%s\n" "$pkg" "$apk"
    ' _ >> "$SCAN_OUT"
    fi
    if [ -s "$REMOVED" ] && [ -s "$CACHE" ]; then
        sed 's/.*=//' "$REMOVED" | awk -F '\t' 'NR==FNR { del[$1]=1; next } !($1 in del)' - "$CACHE" > "$CACHE_TMP"
    elif [ -s "$CACHE" ]; then
        cp -f "$CACHE" "$CACHE_TMP"
    else
        : > "$CACHE_TMP"
    fi
    if [ -s "$SCAN_OUT" ] || [ -s "$CACHE_TMP" ]; then
        cat "$SCAN_OUT" "$CACHE_TMP" 2>/dev/null | sort -u > "$CACHE.new"
        mv -f "$CACHE.new" "$CACHE"
    fi
    mv -f "$NEW" "$INDEX"
    rm -f "$CHANGED" "$REMOVED" "$SCAN_OUT" "$CACHE_TMP"
fi

: > "$HMA_CACHE"
for cfg in \
    /data/user/0/org.frknkrc44.hma_oss/files/config.json \
    /data/user_de/0/org.frknkrc44.hma_oss/files/config.json \
    /data/user/0/icu.nullptr.hidemyapplist/files/config.json \
    /data/user_de/0/icu.nullptr.hidemyapplist/files/config.json; do
    [ -r "$cfg" ] || continue
    grep -oE '"isWhitelist"[[:space:]]*:[[:space:]]*false[[:space:]]*,[[:space:]]*"appList"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$cfg" 2>/dev/null | \
        grep -oE '"[A-Za-z0-9_][A-Za-z0-9_.]*"' | tr -d '"' | \
        grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' >> "$HMA_CACHE"
done
sort -u "$HMA_CACHE" -o "$HMA_CACHE" 2>/dev/null
chmod 0600 "$CACHE" "$INDEX" "$HMA_CACHE" 2>/dev/null

if [ "$1" = "--apply" ]; then
    OLD_AUTO="$NMDIR/auto_hide_cache"
    NEW_AUTO="$NMDIR/.auto_hide.new"
    EXCLUDE="$NMDIR/.global_hide_exclude"
    HIDDEN="$NMDIR/hidden_apps.conf"
    touch "$OLD_AUTO" "$EXCLUDE" "$HIDDEN"
    {
        awk -F '\t' 'NF { print $1 }' "$CACHE" 2>/dev/null
        cat "$HMA_CACHE" 2>/dev/null
    } | sort -u > "$NEW_AUTO"
    {
        echo '# NoMount global hidden packages'
        awk 'FILENAME==ARGV[1] { old[$0]=1; next }
             FILENAME==ARGV[2] { excluded[$0]=1; next }
             FILENAME==ARGV[3] { if ($0 !~ /^#/ && $0 != "" && !old[$0]) print; next }
             !excluded[$0] { print }' "$OLD_AUTO" "$EXCLUDE" "$HIDDEN" "$NEW_AUTO"
    } | awk '!seen[$0]++' > "$NMDIR/.hidden_apps.new"
    mv -f "$NMDIR/.hidden_apps.new" "$HIDDEN"
    mv -f "$NEW_AUTO" "$OLD_AUTO"
    chmod 0600 "$HIDDEN" "$OLD_AUTO" 2>/dev/null
    rm -f "$HMA_CACHE"
    [ -f "${0%/*}/appcloak-sync.sh" ] && sh "${0%/*}/appcloak-sync.sh" >/dev/null 2>&1
fi
