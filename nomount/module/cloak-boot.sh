#!/system/bin/sh
# Boot-time Cloak merge: run the scanner once, merge any newly found
# Xposed/LSPosed APK paths (#XPOSED) into the persistent pathhide rule list.
# HMA blacklist packages are applied to NoMount's UID deny scope instead of
# being mistaken for path substrings. Called once per boot from
# service.sh; the WebUI "Scan" button does the same on demand. No timers here.
# Packages the user manually disabled (recorded in .cloak_exclude) are never
# re-added by this boot scan.
NMDIR=/data/adb/nomount
MODDIR="${0%/*}"
[ -e /proc/pathhide ] || exit 0
[ -f "$MODDIR/scan.sh" ] || exit 0

# 1) scan (also refreshes the cache the WebUI reads on open)
sh "$MODDIR/scan.sh" > "$NMDIR/.cloak_scan.tmp" 2>/dev/null

# 2) merge: header + existing absolute paths + fresh Xposed APK paths,
#    minus user-manually-disabled packages (exclude list).
EXCLUDE="$NMDIR/.cloak_exclude"
touch "$EXCLUDE" 2>/dev/null
{
    echo '# NoMount Cloak — pathhide rule list (managed by WebUI)'
    sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d; /^\//!d' "$NMDIR/pathhide.conf" 2>/dev/null
    awk '/^#XPOSED$/{f=1;next} /^#HMA$/{f=0} f && NF' "$NMDIR/.cloak_scan.tmp" 2>/dev/null
} | sort -u | awk 'FILENAME==ARGV[1]{ex[$0]=1;next} !($0 in ex)' "$EXCLUDE" - > "$NMDIR/.cloak_conf.new"
mv -f "$NMDIR/.cloak_conf.new" "$NMDIR/pathhide.conf"

# 3) HMA names are application scope, never paths. Resolve them through the
# suite client so reinstall/user-profile UID changes remain durable.
ABI=$(getprop ro.product.cpu.abi)
BIN="$MODDIR/bin/$ABI/nomount"
[ -x "$BIN" ] || BIN="$MODDIR/bin/arm64-v8a/nomount"
if [ -x "$BIN" ]; then
    awk '/^#HMA$/{f=1;next} f && NF' "$NMDIR/.cloak_scan.tmp" 2>/dev/null |
    while IFS= read -r _pkg; do
        case "$_pkg" in *[!A-Za-z0-9._-]*|'') continue ;; esac
        "$BIN" uid block "$_pkg" >/dev/null 2>&1 || true
    done
fi
rm -f "$NMDIR/.cloak_scan.tmp"

# 4) publish one coherent RCU ruleset.
sh "$MODDIR/pathhide-apply.sh" >/dev/null 2>&1
