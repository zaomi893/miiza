#!/system/bin/sh
# v1.6.8 state migration: older custom builds accidentally mixed application
# package names into NoMount Suite's module-skip blocklist.  New Suite releases
# reserve `blocklist` for module IDs and use `uidhide` for injection visibility.
# AppCloak has its own hidden_apps.conf, so overlapping app entries must be
# removed from blocklist or a same-named module (notably Scene) is never served.

NMDIR=/data/adb/nomount
BL="$NMDIR/blocklist"

mkdir -p "$NMDIR" || exit 1
chmod 0700 "$NMDIR" 2>/dev/null

if [ -s "$BL" ]; then
    {
        cat "$NMDIR/hidden_apps.conf" 2>/dev/null
        cat "$NMDIR/auto_hide_cache" 2>/dev/null
        awk -F '\t' 'NF { print $1 }' "$NMDIR/xposed_cache" 2>/dev/null
        cat "$NMDIR/hma_blacklist_cache" 2>/dev/null
    } | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' | sort -u > "$NMDIR/.legacy_app_entries"

    awk 'NR==FNR { app[$0]=1; next }
         /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
         !app[$0] && !seen[$0]++ { print }' \
        "$NMDIR/.legacy_app_entries" "$BL" > "$NMDIR/.blocklist.new"
    mv -f "$NMDIR/.blocklist.new" "$BL"
    rm -f "$NMDIR/.legacy_app_entries"
    chmod 0600 "$BL" 2>/dev/null
fi

# Remove superseded one-shot markers and the old per-source HMA display cache.
# auto_hide_cache is the source-neutral automatic selection list.
rm -f "$NMDIR/.state_migrated_v168" "$NMDIR/.appcloak_manual_v2" \
      "$NMDIR/.pathmask_no_auto_apk_v1" "$NMDIR/hma_blacklist_cache" 2>/dev/null
