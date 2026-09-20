#!/system/bin/sh

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

rm -f "$NMDIR/.state_migrated_v168" "$NMDIR/.appcloak_manual_v2" \
      "$NMDIR/.pathmask_no_auto_apk_v1" "$NMDIR/hma_blacklist_cache" 2>/dev/null
