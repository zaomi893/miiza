#!/system/bin/sh
NMDIR=/data/adb/nomount
MODDIR="${0%/*}"
i=0
booted=0
if [ "$(getprop sys.boot_completed)" = "1" ]; then
    booted=1
elif getprop --help 2>&1 | grep -q -- '-w'; then
    getprop -w sys.boot_completed 1 >/dev/null 2>&1
    [ "$(getprop sys.boot_completed)" = "1" ] && booted=1
else
    while [ "$i" -lt 48 ]; do
        if [ "$(getprop sys.boot_completed)" = "1" ]; then booted=1; break; fi
        sleep 5
        i=$((i + 1))
    done
fi


sleep 3
if [ "$booted" = "1" ]; then
    rm -f "$NMDIR/bootcount"
    echo "nomount: boot completed, guard counter reset" > /dev/kmsg 2>/dev/null
else
    echo "nomount: boot_completed never set - leaving guard counter armed" > /dev/kmsg 2>/dev/null
fi

[ -f "$MODDIR/scene-debugfs-watch.sh" ] && \
    sh "$MODDIR/scene-debugfs-watch.sh" --once >/dev/null 2>&1

[ -f "$MODDIR/pathhide-apply.sh" ] && sh "$MODDIR/pathhide-apply.sh" >/dev/null 2>&1

[ -f "$MODDIR/scan.sh" ] && sh "$MODDIR/scan.sh" --apply >/dev/null 2>&1

WATCH_PID="$NMDIR/.appcloak_pathhide_watch.pid"
if [ -f "$MODDIR/appcloak-pathhide-watch.sh" ] && \
   { [ ! -f "$WATCH_PID" ] || ! kill -0 "$(cat "$WATCH_PID" 2>/dev/null)" 2>/dev/null; }; then
    sh "$MODDIR/appcloak-pathhide-watch.sh" >/dev/null 2>&1 &
    echo $! > "$WATCH_PID"
fi

[ -f /data/adb/modules/meta-nomount/spoof.sh ] && \
    sh /data/adb/modules/meta-nomount/spoof.sh shell-tmp >/dev/null 2>&1

ABI=$(getprop ro.product.cpu.abi)
BIN="$MODDIR/bin/$ABI/nomount"
export NM_BIN="$MODDIR/bin/$ABI/nm"

if [ -x "$BIN" ] && [ ! -f "$NMDIR/disabled" ]; then
    _ab_all=$("$BIN" absorb 2>&1)
    _ab_rc=$?
    {
        printf 'stage=settled time=%s\n' "$(date +%s 2>/dev/null)"
        printf '%s\n' "$_ab_all"
        printf 'status=%s\n' "$_ab_rc"
    } >> "$NMDIR/absorb.log"
    _ab=$(printf '%s\n' "$_ab_all" | tail -1)
    echo "nomount: $_ab" > /dev/kmsg 2>/dev/null
fi

if [ -x "$BIN" ] && [ ! -f "$NMDIR/disabled" ] && [ -s "$NMDIR/whiteouts.txt" ]; then
    _wo=$("$BIN" whiteout apply 2>&1 | tail -1)
    echo "nomount: $_wo" > /dev/kmsg 2>/dev/null
fi

if [ -x "$BIN" ] && [ ! -f "$NMDIR/disabled" ] && [ -s "$NMDIR/uidhide" ]; then
    _bl=$("$BIN" uid apply 2>/dev/null)
    echo "nomount: block list re-applied ($_bl)" > /dev/kmsg 2>/dev/null
fi

if [ -x "$BIN" ] && [ ! -f "$NMDIR/disabled" ]; then
    _try=0
    while [ "$_try" -lt 2 ]; do
        "$BIN" check --device --write >/dev/null 2>&1
        _cons=$(sed -n 's/^consistency=//p' "$NMDIR/health.txt" 2>/dev/null)
        case "$_cons" in ok|unchecked*|'') break ;; esac
        _try=$((_try + 1))
        sleep 10
    done
    _hv=$(sed -n 's/^verdict=//p' "$NMDIR/health.txt" 2>/dev/null)
    echo "nomount: device check verdict=${_hv:-unknown} consistency=${_cons:-unknown} (settle tries=$_try)" > /dev/kmsg 2>/dev/null
fi

if command -v ksud >/dev/null 2>&1 && [ -x "$BIN" ] && [ ! -f "$NMDIR/disabled" ]; then
    _rules=$("$NM_BIN" list 2>/dev/null | wc -l)
    _rro=$("$NM_BIN" list 2>/dev/null | grep -c '/overlay/[^ ]*\.apk')
    _mnt=$(grep -c '/data/adb/modules' /proc/self/mountinfo 2>/dev/null || echo 0)
    _doc=$(timeout 30 "$BIN" check --plan 2>/dev/null | sed -n 's/^summary: \([0-9]*\) failed,.* \([0-9]*\) warnings.*$/\1 \2/p')
    _err=$(echo "$_doc" | awk '{print $1+0}')
    _wrn=$(echo "$_doc" | awk '{print $2+0}')
    _cons=$(sed -n 's/^consistency=//p' "$NMDIR/health.txt" 2>/dev/null)
    case "$_cons" in ok|unchecked*|'') _cons_bad=0 ;; *) _cons_bad=1 ;; esac
    if [ "$_cons_bad" = 1 ]; then
        _health="⚠️ per-UID inconsistency — see WebUI › Tools"
    elif [ "${_err:-0}" -gt 0 ]; then
        _health="⚠️ $_err error(s) — see WebUI › Tools"
    elif [ "${_wrn:-0}" -gt 0 ]; then
        _health="$_wrn warning(s)"
    else
        _health="healthy"
    fi
    if [ "${_mnt:-0}" -gt 0 ]; then
        _mstate="⚠ $_mnt module mount(s)"
    else
        _mstate="0 mounts"
    fi
    KSU_MODULE=meta-nomount ksud module config set --temp override.description \
        "[NoMount ✅ $_rules rules · $_rro RRO · $_mstate] $_health — fully mountless: hookless VFS + RRO, su via sucompat" \
        >/dev/null 2>&1
    echo "nomount: card refreshed ($_rules rules, $_mstate, $_health)" > /dev/kmsg 2>/dev/null
fi
exit 0
