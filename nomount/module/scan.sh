#!/system/bin/sh
# Refresh auto-selected application-hide sources on demand from the WebUI.
# APKs are rescanned only when the installed package/path inventory changes.
NMDIR=/data/adb/nomount
CACHE="$NMDIR/xposed_cache"
INDEX="$NMDIR/xposed_packages"
HMA_CACHE="$NMDIR/hma_blacklist_cache"
mkdir -p "$NMDIR" && chmod 0700 "$NMDIR"

pm list packages -f 2>/dev/null | sort > "$NMDIR/.xposed_packages.new"
if ! cmp -s "$NMDIR/.xposed_packages.new" "$INDEX" 2>/dev/null; then
    J=$(( $(nproc 2>/dev/null || echo 4) * 2 ))
    [ "$J" -gt 24 ] && J=24
    [ "$J" -lt 4 ] && J=4
    xargs -P "$J" -n1 sh -c '
        apk="${1%=*}"; pkg="${1##*=}"
        [ -f "$apk" ] || exit 0
        if timeout 4 unzip -l "$apk" 2>/dev/null | grep -qaE "assets/xposed_init|META-INF/xposed/"; then
            printf "%s\t%s\n" "$pkg" "$apk"; exit 0
        fi
        timeout 4 unzip -p "$apk" AndroidManifest.xml 2>/dev/null | tr -d "\000" | \
            grep -qaE "xposedmodule|xposedminversion|xposeddescription|XposedProvider|libxposed" && \
            printf "%s\t%s\n" "$pkg" "$apk"
    ' _ < "$NMDIR/.xposed_packages.new" | sort -u > "$CACHE"
    mv -f "$NMDIR/.xposed_packages.new" "$INDEX"
else
    rm -f "$NMDIR/.xposed_packages.new"
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
    [ -f "${0%/*}/appcloak-sync.sh" ] && sh "${0%/*}/appcloak-sync.sh" >/dev/null 2>&1
fi
