#!/system/bin/sh
# Read-only OnePlus 15T stock-kernel/HMBIRD collector.
# Run inside `adb shell`, then obtain root with a separate `su` command.

OUTDIR=/sdcard/Download
STAMP=$(date +%Y%m%d-%H%M%S)
WORK=/data/local/tmp/oneplus15t-hmbird-collect.$$
NAME=oneplus15t-hmbird-stock-$STAMP
REPORT=$WORK/$NAME/report.txt
umask 077
mkdir -p "$WORK/$NAME/modules" "$WORK/$NAME/btf" "$WORK/$NAME/trace" "$OUTDIR" || exit 1
cleanup() { rm -rf "$WORK" 2>/dev/null; }
trap cleanup EXIT INT TERM

section() { printf '\n\n===== %s =====\n' "$1"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }
read_tree() {
    base="$1"
    [ -e "$base" ] || { echo "MISSING: $base"; return; }
    find "$base" -maxdepth 3 -type f 2>/dev/null | sort | while IFS= read -r file; do
        printf '\n--- %s ---\n' "$file"
        timeout 2 cat "$file" 2>&1 | head -n 160
    done
}

{
    echo "OnePlus 15T stock HMBIRD compatibility collection"
    echo "collector_version=1"
    echo "created=$(date '+%Y-%m-%d %H:%M:%S %z')"
    section IDENTITY
    run id
    run cat /proc/self/attr/current
    run getenforce

    section DEVICE_AND_BUILD
    for prop in ro.serialno ro.boot.serialno ro.product.model ro.product.device \
        ro.product.vendor.device ro.build.display.id ro.build.version.incremental \
        ro.build.version.release ro.build.version.security_patch ro.build.fingerprint \
        ro.boot.slot_suffix ro.bootimage.build.fingerprint ro.vendor.build.fingerprint; do
        printf '%s=%s\n' "$prop" "$(getprop "$prop")"
    done
    run uname -a
    run cat /proc/version
    run cat /proc/cmdline
    run cat /proc/bootconfig

    section SCHED_EXT_AND_HMBIRD
    read_tree /sys/kernel/sched_ext
    read_tree /proc/sys/hmbird
    read_tree /proc/sys/hmbird_II
    read_tree /proc/oplus_hmbird

    section MODULE_STATE
    run cat /proc/modules
    run wc -l /proc/kallsyms
    run head -n 40 /proc/kallsyms
    for module in oplus_bsp_sched_ext rust_binder oplus_bsp_game_opt; do
        command -v modinfo >/dev/null 2>&1 && run modinfo "$module"
        [ -d "/sys/module/$module" ] && run find "/sys/module/$module" -maxdepth 2 -type f
    done

    section FOREGROUND_GAME_STATE
    run dumpsys activity top
    run dumpsys activity processes
} > "$REPORT" 2>&1

# Preserve kernel configuration, base BTF, module BTF and symbol inventory.
[ -r /proc/config.gz ] && cp /proc/config.gz "$WORK/$NAME/config.gz"
[ -r /sys/kernel/btf/vmlinux ] && cp /sys/kernel/btf/vmlinux "$WORK/$NAME/btf/vmlinux.btf"
for btf in /sys/kernel/btf/*; do
    [ -r "$btf" ] || continue
    case "${btf##*/}" in
        *hmbird*|*sched*|rust_binder|oplus_bsp_game*) cp "$btf" "$WORK/$NAME/btf/${btf##*/}.btf" ;;
    esac
done
cat /proc/kallsyms 2>/dev/null | gzip -1 > "$WORK/$NAME/kallsyms.gz"
dmesg > "$WORK/$NAME/dmesg.txt" 2>&1
logcat -d -v threadtime 2>/dev/null | grep -Ei 'hmbird|sched_ext|oplusHmbirdBpfManager|gameopt|gpa pid|cloud' \
    > "$WORK/$NAME/hmbird-logcat.txt"

# Copy the exact stock modules and their loading metadata; no partition writes.
for dir in /vendor_dlkm/lib/modules /vendor/lib/modules /odm/lib/modules; do
    [ -d "$dir" ] || continue
    for meta in modules.load modules.dep modules.alias modules.softdep modules.blocklist; do
        [ -r "$dir/$meta" ] && cp "$dir/$meta" "$WORK/$NAME/modules/$(echo "$dir" | tr '/' '_')-$meta"
    done
    find "$dir" -maxdepth 2 -type f 2>/dev/null | grep -Ei '/(.*hmbird.*|.*sched(_ext)?.*|rust_binder|.*game[_-]?opt.*)\.ko$' | \
        while IFS= read -r ko; do
            tag=$(echo "$ko" | sed 's#^/##; s#/#_#g')
            cp "$ko" "$WORK/$NAME/modules/$tag"
            sha256sum "$ko" >> "$WORK/$NAME/modules/SHA256SUMS"
        done
done

# Tracepoint ABI (formats and IDs) is enough; the collector does not enable or
# alter tracing. Run it while a supported game is foreground so logs/procfs
# contain the cloud policy already dispatched by ColorOS.
TRACE=/sys/kernel/tracing
[ -d "$TRACE/events" ] || TRACE=/sys/kernel/debug/tracing
if [ -d "$TRACE/events" ]; then
    find "$TRACE/events" -maxdepth 3 -type f 2>/dev/null | grep -Ei '/(hmbird|sched_ext|game|frame|freq).*\/(format|id)$' | \
        while IFS= read -r file; do
            out=$(echo "$file" | sed 's#^/##; s#/#_#g')
            cp "$file" "$WORK/$NAME/trace/$out" 2>/dev/null
        done
fi

# Stock boot supplies the exact Image/version metadata. Reading the active boot
# partition is non-destructive and avoids relying on a boot image from another OTA.
SLOT=$(getprop ro.boot.slot_suffix)
BOOT=/dev/block/by-name/boot$SLOT
[ -r "$BOOT" ] && dd if="$BOOT" of="$WORK/$NAME/boot-stock.img" bs=4M 2>/dev/null

find "$WORK/$NAME" -type f ! -name SHA256SUMS.txt -exec sha256sum {} \; > "$WORK/$NAME/SHA256SUMS.txt"
ARCHIVE=$OUTDIR/$NAME.tar.gz
if tar -czf "$ARCHIVE" -C "$WORK" "$NAME" 2>/dev/null; then
    chmod 0644 "$ARCHIVE"
else
    ARCHIVE=$OUTDIR/$NAME.tar
    tar -cf "$ARCHIVE" -C "$WORK" "$NAME" || exit 1
    chmod 0644 "$ARCHIVE"
fi
echo "Collection saved: $ARCHIVE"
echo "This archive contains the device serial, build fingerprints, kernel symbols, stock boot and OEM modules. Send it privately."
