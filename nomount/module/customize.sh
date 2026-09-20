#!/system/bin/sh
ui_print "- Installing NoMount metamodule"
ui_print "- version $(grep_prop version "$MODPATH/module.prop")"

SUMS="$MODPATH/nomount.sha256sums"
if [ -f "$SUMS" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        if (cd "$MODPATH" && sha256sum -c "$SUMS" >/dev/null 2>&1); then
            ui_print "- Integrity check passed ($(wc -l < "$SUMS") files)"
        else
            ui_print "*********************************************************"
            ui_print "! Integrity check FAILED — a file does not match its hash."
            ui_print "! This zip is corrupted or was modified. Re-download it."
            ui_print "*********************************************************"
            abort "- Aborting install: integrity check failed"
        fi
    else
        ui_print "- sha256sum unavailable; skipping integrity check"
    fi
else
    ui_print "- No sha256 manifest bundled; skipping integrity check"
fi

for mp in /data/adb/modules/*/module.prop; do
    [ -f "$mp" ] || continue
    mdir="${mp%/module.prop}"
    id="${mdir##*/}"
    [ "$id" = "meta-nomount" ] && continue
    [ -f "$mdir/remove" ] && continue
    [ -f "$mdir/disable" ] && continue
    if grep -Eq '^[[:space:]]*metamodule[[:space:]]*=[[:space:]]*(1|true|yes)[[:space:]]*$' "$mp"; then
        other="$(grep '^name=' "$mp" | head -n1 | cut -d= -f2-)"
        ui_print "*********************************************************"
        ui_print "! Another metamodule is already installed:"
        ui_print "!   $id${other:+  ($other)}"
        ui_print "! KernelSU/APatch allow only ONE metamodule."
        ui_print "! Remove or disable it first, then flash NoMount."
        ui_print "*********************************************************"
        abort "- Aborting install: metamodule conflict"
    fi
done

for abi in arm64-v8a armeabi-v7a x86_64 x86; do
    for b in nomount nm; do
        if [ -f "$MODPATH/bin/$abi/$b" ]; then
            set_perm "$MODPATH/bin/$abi/$b" 0 0 0755
        fi
    done
done

NMDIR=/data/adb/nomount
mkdir -p "$NMDIR"
set_perm "$NMDIR" 0 0 0700
CONF="$NMDIR/spoof.conf"
[ -f "$CONF" ] || cat > "$CONF" <<'EOF'
EOF
seed_conf() { grep -q "^$1=" "$CONF" 2>/dev/null || echo "$1=$2" >> "$CONF"; }
seed_conf vbmeta_digest auto
seed_conf vbmeta_size auto
seed_conf spoof_props 0
seed_conf spoof_uname 0
seed_conf uname_tail ""
seed_conf uname_date ""
seed_conf fix_shell_tmp 1
set_perm "$CONF" 0 0 0644
[ -f "$MODPATH/spoof.sh" ] && set_perm "$MODPATH/spoof.sh" 0 0 0755
ui_print "- Spoof add-on enabled: dynamic vbmeta.digest"
ui_print "  config: $CONF"

[ -f "$MODPATH/pathhide-apply.sh" ] && set_perm "$MODPATH/pathhide-apply.sh" 0 0 0755
[ -f "$MODPATH/scene-debugfs-watch.sh" ] && set_perm "$MODPATH/scene-debugfs-watch.sh" 0 0 0755
[ -f "$MODPATH/appcloak-sync.sh" ] && set_perm "$MODPATH/appcloak-sync.sh" 0 0 0755
[ -f "$MODPATH/appcloak-pathhide-watch.sh" ] && set_perm "$MODPATH/appcloak-pathhide-watch.sh" 0 0 0755
[ -f "$MODPATH/migrate-state.sh" ] && set_perm "$MODPATH/migrate-state.sh" 0 0 0755
[ -f "$NMDIR/pathhide.conf" ] || : > "$NMDIR/pathhide.conf"
[ -f "$NMDIR/hidden_apps.conf" ] || : > "$NMDIR/hidden_apps.conf"
[ -f "$NMDIR/scope_apps.conf" ] || : > "$NMDIR/scope_apps.conf"
[ -f "$NMDIR/.global_hide_exclude" ] || : > "$NMDIR/.global_hide_exclude"
set_perm "$NMDIR/.global_hide_exclude" 0 0 0600
[ -f "$MODPATH/appcloak-sync.sh" ] && sh "$MODPATH/appcloak-sync.sh" >/dev/null 2>&1

[ -f "$NMDIR/absorb-skip" ] && [ ! -f "$NMDIR/absorb-skip.txt" ] && \
    cp -f "$NMDIR/absorb-skip" "$NMDIR/absorb-skip.txt"
if [ ! -f "$NMDIR/absorb-skip.txt" ]; then
    {
        echo "/apex/com.android.art/bin/dex2oat"
        echo "/apex/com.android.runtime/bin/dex2oat"
        echo "/system/bin/dex2oat"
        echo "/system/bin/app_process"
        echo "zygisksu"
    } > "$NMDIR/absorb-skip.txt"
fi
set_perm "$NMDIR/absorb-skip.txt" 0 0 0600
set_perm "$NMDIR/pathhide.conf" 0 0 0644
set_perm "$NMDIR/hidden_apps.conf" 0 0 0600
set_perm "$NMDIR/scope_apps.conf" 0 0 0600
[ -f "$MODPATH/migrate-state.sh" ] && sh "$MODPATH/migrate-state.sh" >/dev/null 2>&1
if [ -e /proc/pathhide ]; then
    ui_print "- Path hiding support detected"
    ui_print "  AppCloak targets/scope use WebUI; Xposed/HMA targets auto-select"
else
    ui_print "- PathMask unavailable: /proc/pathhide is missing (matching kernel required)"
fi

rm $MODPATH/nomount.sha256sums

ui_print "- Modules under /data/adb/modules are injected mountlessly at boot."
