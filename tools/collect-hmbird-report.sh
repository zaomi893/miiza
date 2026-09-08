#!/system/bin/sh
# OnePlus HMBIRD diagnostic collector. Run from an interactive root shell while
# the affected game stays foreground. Output: /sdcard/Download/hmbird-report.txt

OUT=/sdcard/Download/hmbird-report.txt
TMP=/data/local/tmp/hmbird-report.$$
mkdir -p /sdcard/Download "$TMP" 2>/dev/null

section() { printf '\n\n===== %s =====\n' "$1"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }
read_tree() {
    base="$1"
    [ -e "$base" ] || { echo "MISSING: $base"; return; }
    find "$base" -maxdepth 3 -type f 2>/dev/null | sort | while IFS= read -r f; do
        printf '\n--- %s ---\n' "$f"
        timeout 2 cat "$f" 2>&1 | head -n 120
    done
}

{
    echo "HMBIRD diagnostic report"
    echo "collector_version=2"
    echo "created=$(date '+%Y-%m-%d %H:%M:%S %z')"

    section IDENTITY
    run id
    run cat /proc/self/attr/current
    command -v capsh >/dev/null 2>&1 && run capsh --print
    run getenforce

    section DEVICE_AND_BUILD
    for p in ro.product.model ro.product.device ro.build.display.id ro.build.version.incremental \
        ro.build.version.release ro.build.version.security_patch ro.build.fingerprint \
        ro.boot.slot_suffix ro.bootimage.build.fingerprint ro.vendor.build.fingerprint; do
        printf '%s=%s\n' "$p" "$(getprop "$p")"
    done
    run uname -a
    run cat /proc/version
    run cat /proc/cmdline
    run cat /proc/bootconfig

    section KERNEL_MODULES
    run cat /proc/modules
    for d in /vendor_dlkm/lib/modules /vendor/lib/modules /odm/lib/modules; do
        [ -d "$d" ] || continue
        echo "-- $d"
        find "$d" -maxdepth 1 -type f 2>/dev/null | sort | grep -Ei 'hmbird|sched|game|frame|freq|oplus'
    done
    for m in oplus_bsp_sched_ext oplus_hmbird oplus_game_opt; do
        command -v modinfo >/dev/null 2>&1 && run modinfo "$m"
    done

    section HMBIRD_PROCFS
    read_tree /proc/sys/hmbird_II
    read_tree /proc/oplus_hmbird

    TRACE=/sys/kernel/tracing
    [ -d "$TRACE/events" ] || TRACE=/sys/kernel/debug/tracing
    section TRACEPOINT_INVENTORY
    echo "tracefs=$TRACE"
    if [ -d "$TRACE/events" ]; then
        find "$TRACE/events" -maxdepth 3 -type f -name enable 2>/dev/null | \
            grep -Ei 'hmbird|freqgov|frameboost|sched_ext|game' | sort
    else
        echo "tracefs events unavailable"
    fi

    section FOREGROUND_AND_GAME_SERVICES
    run dumpsys activity activities
    run dumpsys window windows
    run ps -A -o USER,PID,PPID,NAME,ARGS
    run dumpsys package com.tencent.tmgp.pubgmhd
    run dumpsys package com.tencent.tmgp.sgame

    section SHORT_HMBIRD_TRACE
    if [ -w "$TRACE/tracing_on" ] && [ -r "$TRACE/trace" ]; then
        STATE="$TMP/event-state"
        : > "$STATE"
        find "$TRACE/events" -maxdepth 3 -type f -name enable 2>/dev/null | \
            grep -Ei 'hmbird|freqgov|frameboost|sched_ext' | while IFS= read -r f; do
                printf '%s\t%s\n' "$f" "$(cat "$f" 2>/dev/null)" >> "$STATE"
                echo 1 > "$f" 2>/dev/null
            done
        OLD_TRACE="$(cat "$TRACE/tracing_on" 2>/dev/null)"
        MARK="NM_HMBIRD_START_$(date +%s)_$$"
        [ -w "$TRACE/trace_marker" ] && echo "$MARK" > "$TRACE/trace_marker" 2>/dev/null
        echo 1 > "$TRACE/tracing_on" 2>/dev/null
        echo "Tracing for 8 seconds; keep the affected game foreground and active..."
        sleep 8
        cat "$TRACE/trace" 2>/dev/null | awk -v m="$MARK" 'index($0,m){seen=1;next} seen' | tail -n 5000
        [ "$OLD_TRACE" = "0" ] && echo 0 > "$TRACE/tracing_on" 2>/dev/null
        while IFS="$(printf '\t')" read -r f v; do [ -n "$f" ] && echo "$v" > "$f" 2>/dev/null; done < "$STATE"
        echo "trace_state_restored=1"
    else
        echo "tracefs is not writable from this root context"
    fi

    section KERNEL_LOG_FILTERED
    dmesg 2>&1 | tail -n 12000 | grep -Ei 'hmbird|sched_ext|oplus_bsp_sched|frame.?boost|game.?opt|freqgov|btf|unknown symbol|module.*(fail|error)|vermagic' | tail -n 2500

    section ANDROID_LOG_FILTERED
    logcat -d -v threadtime -t 12000 2>&1 | grep -Ei 'hmbird|sched_ext|frame.?boost|game.?opt|GameScene|ControlLooper|COSA|freqgov|cloud|云控|btf|unknown symbol' | tail -n 3500

    section FILE_HASHES
    for f in $(find /vendor_dlkm/lib/modules /vendor/lib/modules /odm/lib/modules -maxdepth 1 -type f 2>/dev/null | grep -Ei 'hmbird|sched_ext|game|frame|freqgov'); do
        sha256sum "$f" 2>/dev/null
    done
} > "$OUT" 2>&1

chmod 0644 "$OUT" 2>/dev/null
rm -rf "$TMP" 2>/dev/null
echo "Report saved: $OUT"
