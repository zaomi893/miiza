#!/system/bin/sh
# Boot-time Cloak merge: run the scanner once, merge any newly found
# Xposed/LSPosed APK paths (#XPOSED) into the persistent pathhide rule list.
# Called once per boot from service.sh; the WebUI "Scan" button does the same
# on demand. Application targets remain managed by NoMount's existing UID
# block/unblock list; this scanner only discovers paths.
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
    awk '/^#XPOSED$/{f=1;next} f && NF { print (NF > 1 ? $NF : $0) }' \
        "$NMDIR/.cloak_scan.tmp" 2>/dev/null
} | sort -u | awk 'FILENAME==ARGV[1]{ex[$0]=1;next} !($0 in ex)' "$EXCLUDE" - > "$NMDIR/.cloak_conf.new"
mv -f "$NMDIR/.cloak_conf.new" "$NMDIR/pathhide.conf"

rm -f "$NMDIR/.cloak_scan.tmp"

# 3) publish one coherent RCU ruleset.
sh "$MODDIR/pathhide-apply.sh" >/dev/null 2>&1
