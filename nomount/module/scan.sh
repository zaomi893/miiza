#!/system/bin/sh
# NoMount Cloak scanner
#   --cached : print cached results (xposed modules + HMA blacklist), no scan
#   default  : scan installed APKs for Xposed/LSPosed modules, scan Hide My
#              Applist blacklist, cache both, then print both sections.
# Xposed module markers (union, from strong to weak):
#   1. assets/xposed_init                     classic Xposed entry file
#   2. META-INF/xposed/                       LSPosed module decl (module.prop,
#                                             java_init.list / native_init.list)
#   3. manifest xposedmodule/xposedminversion/xposeddescription
#   4. manifest XposedProvider / libxposed    libxposed (new LSPosed) module
# Output sections:
#   #XPOSED  ... package<TAB>APK path pairs for Xposed/LSPosed modules
#   #HMA     ... package names of the Hide My Applist blacklist (apps to cloak)
CACHE=/data/adb/nomount/xposed_cache
HMA_CACHE=/data/adb/nomount/hma_blacklist_cache
mkdir -p /data/adb/nomount && chmod 0700 /data/adb/nomount

if [ "$1" = "--cached" ]; then
    echo "#XPOSED"
    cat "$CACHE" 2>/dev/null
    echo "#HMA"
    cat "$HMA_CACHE" 2>/dev/null
    exit 0
fi

# Manifest probe is I/O-bound -> ~2x cores, capped.
J=$(( $(nproc 2>/dev/null || echo 4) * 2 ))
[ "$J" -gt 24 ] && J=24
[ "$J" -lt 4 ] && J=4

# 1) Xposed / LSPosed / libxposed modules. Scan all packages, but only exact module markers match (system apps like shell never match).
pm list packages -f 2>/dev/null | sed 's/^package://' | xargs -P "$J" -n1 sh -c '
    apk="${1%=*}"; pkg="${1##*=}"
    [ -f "$apk" ] || exit 0
    if timeout 4 unzip -l "$apk" 2>/dev/null | grep -qaE "assets/xposed_init|META-INF/xposed/"; then
        printf "%s\t%s\n" "$pkg" "$apk"; exit 0
    fi
    timeout 4 unzip -p "$apk" AndroidManifest.xml 2>/dev/null | tr -d "\000" | \
        grep -qaE "xposedmodule|xposedminversion|xposeddescription|XposedProvider|libxposed" && \
        printf "%s\t%s\n" "$pkg" "$apk"
' _ | sort -u > "$CACHE"

# 2) Hide My Applist blacklist: for every template entry with isWhitelist:false,
#    collect its appList package names. config.json is a single line.
: > "$HMA_CACHE"
for cfg in /data/misc/*hide_my_applist*/config.json; do
    [ -f "$cfg" ] || continue
    grep -o '"isWhitelist":false,"appList":\[[^]]*\]' "$cfg" 2>/dev/null | \
        sed 's/.*"appList":\[//; s/\]$//' | \
        tr ',' '\n' | tr -d '"' | \
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
        grep -v '^$'
done | sort -u > "$HMA_CACHE"

echo "#XPOSED"
cat "$CACHE" 2>/dev/null
echo "#HMA"
cat "$HMA_CACHE" 2>/dev/null
