#!/system/bin/sh
# NoMount Suite metamodule hook (KSU/APatch, post-fs-data / metamodule stage).
# Runs the Suite mount pass (hookless mountless inject + RRO overlays), guarded by
# a bootloop counter, hides the RRO mounts via SUSFS if present, then signals ready.
# Root/su is NOT managed here (sucompat handles it, mountlessly).
MODDIR="${0%/*}"
NMDIR=/data/adb/nomount
# 0700: spoof.conf/blocklist/pathhide.conf are read as root at boot, so anything
# able to write here gets root. The dir was being created under the boot umask (0777).
mkdir -p "$NMDIR" && chmod 0700 "$NMDIR"
[ -f "$MODDIR/appcloak-sync.sh" ] && sh "$MODDIR/appcloak-sync.sh" --boot-prepare >/dev/null 2>&1
[ -f "$MODDIR/migrate-state.sh" ] && sh "$MODDIR/migrate-state.sh" >/dev/null 2>&1

# Single-run guard. Was a noclobber file in /dev: world-writable (boot umask),
# named after the project, and "held" by mere existence -- so anything able to
# create that path pre-empted the whole mount pass. flock releases on exit and
# lives in the 0700 state dir.
LOCK="$NMDIR/.mount.lock"
LOCK_DIR="$NMDIR/.mount.lock.dir"
if [ -d "$LOCK_DIR" ] && [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null
fi
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK" 2>/dev/null
    flock -n 9 || exit 0
else
    # Hybrid Mount uses an atomic mkdir lock for managers whose toybox lacks
    # flock. Keep the same semantics instead of silently allowing a double run.
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM
fi

ABI=$(getprop ro.product.cpu.abi)
BIN="$MODDIR/bin/$ABI/nomount"
# The Suite binary shells out to the hookless `nm` netlink client bundled beside it.
export NM_BIN="$MODDIR/bin/$ABI/nm"

# Self-heal executable bits: some installers (and non-recovery ksud extraction)
# don't preserve +x. Without it on nm the whole pass aborts before it can inject.
chmod 0755 "$BIN" "$NM_BIN" 2>/dev/null

# --- spoof add-on (dynamic vbmeta.digest) ---
# Runs in this post-fs-data stage so the property is in place before
# zygote/system_server come up. Best-effort: it never aborts the boot, and
# it is kept separate from the mount pass so a spoof failure can't affect mounting.
[ -f "$MODDIR/spoof.sh" ] && sh "$MODDIR/spoof.sh" 2>/dev/null

# --- Mountify compatibility ---
# The engine understands disable/remove/skip_mount, while Magisk-side modules
# use skip_mountify to opt out of a third-party metamodule. Mirror that marker
# through NoMount's own module blocklist without touching the module directory.
BLOCKLIST="$NMDIR/blocklist"
AUTO_SKIP="$NMDIR/.skip_mountify.auto"
CURRENT_SKIP="$NMDIR/.skip_mountify.current"
STALE_SKIP="$NMDIR/.skip_mountify.stale"
touch "$BLOCKLIST" "$AUTO_SKIP" "$CURRENT_SKIP" "$STALE_SKIP" 2>/dev/null
: > "$CURRENT_SKIP"
for d in /data/adb/modules/*/; do
    [ -d "$d" ] || continue
    { [ -f "$d/disable" ] || [ -f "$d/remove" ] || [ -f "$d/skip_mount" ]; } && continue
    [ -f "$d/skip_mountify" ] || continue
    basename "$d" >> "$CURRENT_SKIP"
done
sort -u "$AUTO_SKIP" > "$NMDIR/.skip_mountify.auto.sorted"
sort -u "$CURRENT_SKIP" > "$NMDIR/.skip_mountify.current.sorted"
comm -23 "$NMDIR/.skip_mountify.auto.sorted" "$NMDIR/.skip_mountify.current.sorted" > "$STALE_SKIP"
comm -12 "$NMDIR/.skip_mountify.auto.sorted" "$NMDIR/.skip_mountify.current.sorted" > "$NMDIR/.skip_mountify.keep"
if [ -s "$STALE_SKIP" ]; then
    awk 'NR==FNR { stale[$0]=1; next } !($0 in stale)' \
        "$STALE_SKIP" "$BLOCKLIST" > "$NMDIR/.blocklist.new"
    mv -f "$NMDIR/.blocklist.new" "$BLOCKLIST"
fi
: > "$NMDIR/.skip_mountify.added"
while IFS= read -r mid; do
    [ -n "$mid" ] || continue
    grep -Fxq "$mid" "$BLOCKLIST" || {
        echo "$mid" >> "$BLOCKLIST"
        echo "$mid" >> "$NMDIR/.skip_mountify.added"
    }
done < "$NMDIR/.skip_mountify.current.sorted"
cat "$NMDIR/.skip_mountify.keep" "$NMDIR/.skip_mountify.added" 2>/dev/null | sort -u > "$NMDIR/.skip_mountify.auto.new"
mv -f "$NMDIR/.skip_mountify.auto.new" "$AUTO_SKIP"
rm -f "$NMDIR/.skip_mountify.auto.sorted" "$NMDIR/.skip_mountify.current.sorted" \
      "$STALE_SKIP" "$NMDIR/.skip_mountify.keep" "$NMDIR/.skip_mountify.added"
chmod 0600 "$BLOCKLIST" "$AUTO_SKIP" 2>/dev/null

# --- bootloop guard ---
GUARD_MAX=3
COUNT=$(cat "$NMDIR/bootcount" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$NMDIR/bootcount"

if [ -f "$NMDIR/disabled" ]; then
    echo "nomount: disabled, skipping mount" > /dev/kmsg 2>/dev/null
elif [ "$COUNT" -ge "$GUARD_MAX" ]; then
    echo "nomount: bootloop guard tripped (count=$COUNT) -> self-disabling" > /dev/kmsg 2>/dev/null
    : > "$NMDIR/disabled"
    # Record WHY, while the evidence is still fresh. Without this a trip leaves only an
    # empty `disabled` file and the user has to dig through tombstones by hand to find out
    # what crashed (that is exactly how the /my_product FD-allowlist bootloop was found).
    # Everything here is best-effort and must never fail the boot.
    {
        echo "when=$(date '+%Y-%m-%d %H:%M:%S') epoch=$(date +%s)"
        echo "bootcount=$COUNT guard_max=$GUARD_MAX"
        echo "kernel=$(uname -r)"
        echo "suite=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -1)"
        echo "rules_at_trip=$("$NM_BIN" list 2>/dev/null | wc -l)"
        echo "modules_enabled=$(for m in /data/adb/modules/*/; do
                { [ -f "$m/disable" ] || [ -f "$m/remove" ] || [ -f "$m/skip_mount" ] || [ -f "$m/skip_mountify" ]; } && continue
                basename "$m"
            done | tr '\n' ' ')"
        # Newest native crash + its abort line: for an early-boot bootloop this is almost
        # always zygote/system_server and names the offending path outright.
        _t=$(ls -t /data/tombstones/tombstone_* 2>/dev/null | grep -v '\.pb$' | head -1)
        if [ -n "$_t" ]; then
            echo "tombstone=$_t"
            echo "  $(grep -m1 '>>> ' "$_t" 2>/dev/null)"
            echo "  $(grep -m1 'Abort message' "$_t" 2>/dev/null)"
        fi
    } > "$NMDIR/incident.log" 2>/dev/null
elif [ -x "$BIN" ]; then
    timeout 60 "$BIN" mount 2>/dev/null
    MOUNT_STATUS=$?
else
    MOUNT_STATUS=1
fi

# --- hiding ---
# Nothing to hide: the Suite is now FULLY MOUNTLESS. Hookless VFS injection covers
# regular files AND RRO overlay APKs (injected into /product/overlay etc.; OMS +
# idmap2 pick them up at the system_server scan, which runs after this post-fs-data
# pass). su is sucompat (mountless). There is no overlayfs mount and no work tmpfs,
# so a mount scanner sees only stock mounts — nothing to hide, no SUSFS, no umount.

# --- tag managed modules in the manager with how the Suite serves them ---
if command -v ksud >/dev/null 2>&1; then
    _vf=""; _ov=""
    for d in /data/adb/modules/*/; do
        [ -d "$d" ] || continue
        mid=$(basename "$d")
        { [ "$mid" = "meta-nomount" ] || [ "$mid" = "kernelnosu" ]; } && continue
        { [ -f "$d/disable" ] || [ -f "$d/remove" ] || [ -f "$d/skip_mount" ] || [ -f "$d/skip_mountify" ]; } && continue
        # Mirror the injector (src/mount.rs): content lives under ANY top-level dir that maps
        # to a real partition, not just system/ (auto_mount modules ship product/ directly).
        # Plain `find` (no -L) is deliberate: a module's `system/product -> ../product`
        # layout-convergence symlink must not be followed, or its files count twice.
        _roots=""
        for _pd in "$d"*/; do
            [ -d "$_pd" ] || continue
            # Mirrors the injector's non-following file_type(): a top-level symlink (e.g.
            # OnePlus_Dialer_Universal's `product -> ./system/product`) is not a root to walk;
            # counting it would double-count the files it points at.
            [ -L "${_pd%/}" ] && continue
            _n=$(basename "$_pd")
            case "$_n" in
                data|mnt|dev|proc|sys|cache|metadata|config|storage|sdcard|apex|tmp|\
                debug_ramdisk|linkerconfig|postinstall|second_stage_resources|bin|sbin) continue ;;
            esac
            [ -d "/$_n" ] || continue
            _roots="$_roots $_pd"
        done
        [ -z "$_roots" ] && continue
        _o=0; _v=0
        [ -n "$(find $_roots -path '*/overlay/*.apk' -print -quit 2>/dev/null)" ] && _o=1
        [ -n "$(find $_roots -type f ! -path '*/overlay/*' -print -quit 2>/dev/null)" ] && _v=1
        [ "$_o" = 0 ] && [ "$_v" = 0 ] && continue
        if [ "$_o" = 1 ] && [ "$_v" = 1 ]; then _t="vfs + overlay"; _ov="$_ov $mid";
        elif [ "$_o" = 1 ]; then _t="overlay"; _ov="$_ov $mid";
        else _t="vfs"; _vf="$_vf $mid"; fi
        # How many rules this module actually got, and whether it owns any mount. The
        # rule count is the honest measure of "is this module being served" — a module
        # can be enabled and still contribute nothing. A non-zero mount count is the only
        # thing that breaks the zero-mount posture, so it is called out per module.
        _n=$("$NM_BIN" list 2>/dev/null | grep -c "/data/adb/modules/$mid/")
        _m=$(grep -cE "/data/adb/modules/$mid(/|$)" /proc/self/mountinfo 2>/dev/null); _m=${_m:-0}
        _badge="$_t · $_n served"
        [ "${_m:-0}" -gt 0 ] && _badge="$_badge · ⚠ $_m mount(s)"
        _orig=$(sed -n 's/^description=//p' "$d/module.prop" | head -1)
        KSU_MODULE="$mid" ksud module config set --temp override.description \
            "[NoMount · $_badge] $_orig" >/dev/null 2>&1
    done

    # The Suite's own card doubles as the at-a-glance status readout, so put the live
    # numbers there rather than restating the tagline the module.prop already carries.
    _rules=$("$NM_BIN" list 2>/dev/null | wc -l)
    _rro=$("$NM_BIN" list 2>/dev/null | grep -c '/overlay/[^ ]*\.apk')
    _mods=0
    for _x in $_vf $_ov; do _mods=$((_mods + 1)); done
    _list=""
    [ -n "$_vf" ] && _list="vfs:$_vf"
    [ -n "$_ov" ] && _list="$_list${_list:+ | }overlay:$_ov"
    if [ -f "$NMDIR/disabled" ]; then
        _desc="[NoMount ⛔ disabled] bootloop guard tripped — open WebUI › Tools › Last incident"
    else
        _desc="[NoMount ✅ $_rules rules · $_rro RRO · $_mods modules] fully mountless — hookless VFS + RRO, no overlayfs, su via sucompat${_list:+. $_list}"
    fi
    KSU_MODULE=meta-nomount ksud module config set --temp override.description "$_desc" >/dev/null 2>&1
fi

if [ "${MOUNT_STATUS:-1}" -eq 0 ]; then
    ksud kernel notify-module-mounted 2>/dev/null
fi
exit 0
