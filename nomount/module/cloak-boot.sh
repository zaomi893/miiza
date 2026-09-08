#!/system/bin/sh
# Boot-time application scan. Xposed/LSPosed packages are added only to the
# independent application-visibility list. PathMask remains a file-path list:
# it contains user-entered paths plus Scene's separately discovered debugfs.
NMDIR=/data/adb/nomount
MODDIR="${0%/*}"
[ -f "$MODDIR/scan.sh" ] || exit 0

# 1) Scan (also refreshes the cache the WebUI reads on open).
sh "$MODDIR/scan.sh" > "$NMDIR/.cloak_scan.tmp" 2>/dev/null

# 2) One-time migration: old builds incorrectly auto-added every detected
# Xposed base.apk. Remove those generated /data/app rules once. Paths manually
# added after this migration are never scanned or removed.
MIGRATED="$NMDIR/.pathmask_no_auto_apk_v1"
if [ ! -f "$MIGRATED" ]; then
    {
        echo '# NoMount PathMask — manual file paths (managed by WebUI)'
        sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d; /^\/data\/app\/.*\/base\.apk[[:space:]]*$/d' \
            "$NMDIR/pathhide.conf" 2>/dev/null
    } > "$NMDIR/.pathhide.manual"
    mv -f "$NMDIR/.pathhide.manual" "$NMDIR/pathhide.conf"
    : > "$MIGRATED"
fi

# 3) Publish manual paths plus the current Scene debugfs paths when this kernel
# exposes PathMask. Application hiding remains usable independently.
[ -e /proc/pathhide ] && sh "$MODDIR/pathhide-apply.sh" >/dev/null 2>&1

# 4) Xposed packages belong only to the global application-visibility list.
GH_EXCLUDE="$NMDIR/.global_hide_exclude"
HMA_CACHE="$NMDIR/hma_blacklist_cache"
touch "$GH_EXCLUDE" 2>/dev/null
: > "$HMA_CACHE"
for _hma in \
    /data/user/0/org.frknkrc44.hma_oss/files/config.json \
    /data/user_de/0/org.frknkrc44.hma_oss/files/config.json \
    /data/user/0/icu.nullptr.hidemyapplist/files/config.json \
    /data/user_de/0/icu.nullptr.hidemyapplist/files/config.json; do
    [ -r "$_hma" ] || continue
    # Import only blacklist templates. Whitelist templates describe visible
    # packages and must never be inverted into a global hide list.
    grep -oE '"isWhitelist"[[:space:]]*:[[:space:]]*false[[:space:]]*,[[:space:]]*"appList"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$_hma" 2>/dev/null | \
        grep -oE '"[A-Za-z0-9_][A-Za-z0-9_.]*"' | tr -d '"' | \
        grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' >> "$HMA_CACHE"
done
sort -u "$HMA_CACHE" -o "$HMA_CACHE" 2>/dev/null
{
    echo '# NoMount global hidden packages'
    sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$NMDIR/hidden_apps.conf" 2>/dev/null
    awk -F '\t' 'NF { print $1 }' "$NMDIR/xposed_cache" 2>/dev/null
    cat "$HMA_CACHE" 2>/dev/null
} | sort -u | awk 'FILENAME==ARGV[1]{ex[$0]=1;next} !($0 in ex)' "$GH_EXCLUDE" - > "$NMDIR/.hidden_apps.new"
mv -f "$NMDIR/.hidden_apps.new" "$NMDIR/hidden_apps.conf"
chmod 0600 "$NMDIR/hidden_apps.conf" 2>/dev/null
[ -f "$MODDIR/appcloak-sync.sh" ] && sh "$MODDIR/appcloak-sync.sh" >/dev/null 2>&1
rm -f "$NMDIR/.cloak_scan.tmp"
