#!/system/bin/sh

PATH=/data/adb/ksu/bin:/data/adb/magisk:/system/bin:/system/xbin:$PATH
NMDIR=/data/adb/nomount
CONF="$NMDIR/spoof.conf"
LOG="$NMDIR/spoof.log"

mkdir -p "$NMDIR" 2>/dev/null && chmod 0700 "$NMDIR" 2>/dev/null
[ -f "$LOG" ] && tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null

log() {
    echo "nomount-spoof: $*" > /dev/kmsg 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
}

have() { command -v "$1" >/dev/null 2>&1; }

vbmeta_digest=auto
vbmeta_size=auto
spoof_props=0
spoof_uname=0
uname_tail=""
uname_date=""
fix_shell_tmp=1
nm_load_conf() {
    [ -f "$CONF" ] || return 0
    while IFS= read -r _l; do
        _l=${_l%%#*}
        case "$_l" in *=*) ;; *) continue ;; esac
        _k=${_l%%=*}; _v=${_l#*=}
        _k=$(printf '%s' "$_k" | tr -d " \t")
        _v=${_v#\'}; _v=${_v%\'}; _v=${_v#\"}; _v=${_v%\"}
        case "$_k" in
            vbmeta_digest) vbmeta_digest=$_v ;;
            vbmeta_size)   vbmeta_size=$_v ;;
            spoof_props)   spoof_props=$_v ;;
            spoof_uname)   spoof_uname=$_v ;;
            spoof_cmdline) spoof_cmdline=$_v ;;
            uname_tail)    uname_tail=$_v ;;
            uname_date)    uname_date=$_v ;;
            fix_shell_tmp) fix_shell_tmp=$_v ;;
        esac
    done < "$CONF"
}
nm_load_conf

RESETPROP=""
find_resetprop() {
    local c
    for c in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop resetprop; do
        if [ -x "$c" ] 2>/dev/null; then RESETPROP="$c"; return 0; fi
        if command -v "$c" >/dev/null 2>&1; then RESETPROP="$c"; return 0; fi
    done
    if command -v magisk >/dev/null 2>&1; then RESETPROP="magisk resetprop"; return 0; fi
    return 1
}

sha256_of() {
    local f=$1 out=""
    if have sha256sum; then out=$(sha256sum "$f" 2>/dev/null | awk '{print $1}'); fi
    [ -z "$out" ] && have busybox && out=$(busybox sha256sum "$f" 2>/dev/null | awk '{print $1}')
    echo "$out"
}
sha512_of() {
    local f=$1 out=""
    if have sha512sum; then out=$(sha512sum "$f" 2>/dev/null | awk '{print $1}'); fi
    [ -z "$out" ] && have busybox && out=$(busybox sha512sum "$f" 2>/dev/null | awk '{print $1}')
    echo "$out"
}


SLOT=""

be_u32() {
    local f=$1 o=$2
    set -- $(dd if="$f" bs=1 skip="$o" count=4 2>/dev/null | od -An -tu1)
    echo $(( ${1:-0}*16777216 + ${2:-0}*65536 + ${3:-0}*256 + ${4:-0} ))
}
be_u64() {
    local f=$1 o=$2 hi lo
    set -- $(dd if="$f" bs=1 skip="$o" count=8 2>/dev/null | od -An -tu1)
    hi=$(( ${1:-0}*16777216 + ${2:-0}*65536 + ${3:-0}*256 + ${4:-0} ))
    lo=$(( ${5:-0}*16777216 + ${6:-0}*65536 + ${7:-0}*256 + ${8:-0} ))
    [ "$hi" -ne 0 ] && { echo 0; return; }
    echo "$lo"
}

resolve_part() {
    local n=$1 cand
    for cand in "/dev/block/by-name/${n}${SLOT}" "/dev/block/by-name/${n}"; do
        [ -e "$cand" ] && { echo "$cand"; return 0; }
    done
    return 1
}

ACC=""

vbmeta_base() {
    local dev=$1 sz foot magic vo
    [ "$(dd if="$dev" bs=1 count=4 2>/dev/null)" = "AVB0" ] && { echo 0; return 0; }
    sz=$(blockdev --getsize64 "$dev" 2>/dev/null)
    [ -z "$sz" ] && sz=$(( $(cat "/sys/class/block/$(basename "$(readlink -f "$dev")")/size" 2>/dev/null || echo 0) * 512 ))
    [ "${sz:-0}" -gt 0 ] || sz=$(stat -c %s "$dev" 2>/dev/null || wc -c < "$dev" 2>/dev/null)
    [ "${sz:-0}" -gt 64 ] || return 1
    foot=$(( sz - 64 ))
    magic=$(dd if="$dev" bs=1 skip="$foot" count=4 2>/dev/null)
    [ "$magic" = "AVBf" ] || return 1
    vo=$(be_u64 "$dev" $(( foot + 20 )))
    [ "${vo:-0}" -gt 0 ] || return 1
    echo "$vo"
}

emit_struct() {
    local base=$1 depth=$2 dev magic auth aux len vo
    local desc_off desc_size aux_start p end tag nbf nlen nm
    [ "${depth:-0}" -gt 6 ] && return 0
    dev=$(resolve_part "$base") || { [ "$depth" = 0 ] && log "vbmeta: partition '$base$SLOT' not found"; return 1; }
    vo=$(vbmeta_base "$dev") || { [ "$depth" = 0 ] && log "vbmeta: '$dev' has no AVB header or footer"; return 1; }
    magic=$(dd if="$dev" bs=1 skip="$vo" count=4 2>/dev/null)
    [ "$magic" = "AVB0" ] || { [ "$depth" = 0 ] && log "vbmeta: '$dev' is not an AVB image"; return 1; }
    auth=$(be_u64 "$dev" $(( vo + 12 )))
    aux=$(be_u64 "$dev" $(( vo + 20 )))
    len=$(( 256 + auth + aux ))
    [ "$len" -ge 256 ] && [ "$len" -le 1048576 ] || { log "vbmeta: implausible struct len=$len for $base"; return 1; }
    dd if="$dev" bs=1 skip="$vo" count="$len" 2>/dev/null >> "$ACC"

    desc_off=$(be_u64 "$dev" $(( vo + 96 )))
    desc_size=$(be_u64 "$dev" $(( vo + 104 )))
    aux_start=$(( vo + 256 + auth ))
    p=$(( aux_start + desc_off ))
    end=$(( p + desc_size ))
    while [ "$p" -lt "$end" ]; do
        tag=$(be_u64 "$dev" "$p")
        nbf=$(be_u64 "$dev" $(( p + 8 )))
        [ "$nbf" -le 0 ] && break
        if [ "$tag" = "4" ]; then
            nlen=$(be_u32 "$dev" $(( p + 20 )))
            if [ "$nlen" -gt 0 ] && [ "$nlen" -le 64 ]; then
                nm=$(dd if="$dev" bs=1 skip=$(( p + 92 )) count="$nlen" 2>/dev/null)
                [ -n "$nm" ] && emit_struct "$nm" $(( depth + 1 ))
            fi
        fi
        p=$(( p + 16 + nbf ))
    done
    return 0
}

compute_vbmeta_digest() {
    ACC="$NMDIR/.vbacc"
    : > "$ACC" 2>/dev/null || return 1
    SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
    if ! emit_struct vbmeta 0 || [ ! -s "$ACC" ]; then
        rm -f "$ACC" 2>/dev/null
        return 1
    fi
    local alg dg=""
    alg=$(getprop ro.boot.vbmeta.hash_alg 2>/dev/null)
    [ "$alg" = "sha512" ] && dg=$(sha512_of "$ACC")
    [ -z "$dg" ] && dg=$(sha256_of "$ACC")
    VB_SIZE=$(wc -c < "$ACC" 2>/dev/null | tr -d ' \n')
    rm -f "$ACC" 2>/dev/null
    [ -n "$dg" ] && printf '%s' "$dg" | tr 'A-F' 'a-f'
}

do_vbmeta() {
    local mode=$1 cur cache="$NMDIR/vbmeta_digest.cache" szcache="$NMDIR/vbmeta_size.cache" dg="" sz=""
    [ "$mode" = "off" ] && { log "vbmeta.digest: off"; return 0; }

    cur=$(getprop ro.boot.vbmeta.digest 2>/dev/null)
    if [ -n "$cur" ] && [ "$mode" != "force" ]; then
        log "vbmeta.digest already present (len ${#cur}); leaving as-is"
    else
        [ -s "$cache" ] && [ "$mode" != "force" ] && dg=$(cat "$cache" 2>/dev/null)
        if [ -z "$dg" ]; then
            dg=$(compute_vbmeta_digest)
            [ -n "$dg" ] && { echo "$dg" > "$cache" 2>/dev/null; [ -n "$VB_SIZE" ] && echo "$VB_SIZE" > "$szcache" 2>/dev/null; }
        fi
        if [ -z "$dg" ]; then
            log "vbmeta.digest: could not compute (left unset)"
        elif [ -z "$RESETPROP" ]; then
            log "vbmeta.digest: resetprop unavailable, cannot set"
        else
            $RESETPROP -n ro.boot.vbmeta.digest "$dg" 2>/dev/null \
                && log "vbmeta.digest set = $dg ($mode)" || log "vbmeta.digest: resetprop failed"
        fi
    fi

    [ "${vbmeta_size:-auto}" = "off" ] && return 0
    [ -n "$RESETPROP" ] || return 0
    sz=$VB_SIZE
    [ -z "$sz" ] && [ -s "$szcache" ] && sz=$(cat "$szcache" 2>/dev/null)
    [ -n "$sz" ] || return 0
    cur=$(getprop ro.boot.vbmeta.size 2>/dev/null)
    if [ -z "$cur" ] || [ "$mode" = "force" ]; then
        $RESETPROP -n ro.boot.vbmeta.size "$sz" 2>/dev/null && log "vbmeta.size set = $sz ($mode)"
    fi
}

rp_reset_if_present() {
    local name=$1 want=$2 cur
    cur=$(getprop "$name" 2>/dev/null)
    [ -n "$cur" ] && [ "$cur" != "$want" ] \
        && $RESETPROP -n "$name" "$want" 2>/dev/null && log "prop $name -> $want"
}
rp_del() { [ -n "$(getprop "$1" 2>/dev/null)" ] && $RESETPROP -d "$1" 2>/dev/null && log "prop $1 deleted"; }

do_props() {
    [ "${spoof_props:-0}" = "1" ] || return 0
    [ -n "$RESETPROP" ] || { log "props: resetprop unavailable"; return 0; }

    rp_reset_if_present ro.boot.vbmeta.device_state    locked
    rp_reset_if_present ro.boot.verifiedbootstate      green
    rp_reset_if_present ro.boot.flash.locked           1
    rp_reset_if_present ro.boot.veritymode             enforcing
    rp_reset_if_present ro.boot.warranty_bit           0
    rp_reset_if_present ro.warranty_bit                0
    rp_reset_if_present ro.vendor.boot.warranty_bit    0
    rp_reset_if_present ro.vendor.warranty_bit         0
    rp_reset_if_present vendor.boot.vbmeta.device_state locked
    rp_reset_if_present vendor.boot.verifiedbootstate  green
    rp_reset_if_present ro.debuggable                  0
    rp_reset_if_present ro.force.debuggable            0
    rp_reset_if_present ro.secure                      1
    rp_reset_if_present ro.adb.secure                  1
    rp_reset_if_present ro.build.type                  user
    rp_reset_if_present ro.build.tags                  release-keys
    rp_reset_if_present ro.crypto.state                encrypted
    rp_reset_if_present ro.secureboot.lockstate        locked
    rp_reset_if_present ro.boot.realmebootstate        green
    rp_reset_if_present ro.boot.realme.lockstate       1

    base_utc=$(getprop ro.build.date.utc 2>/dev/null)
    if [ -n "$base_utc" ]; then
        for p in ro.bootimage.build.date.utc ro.odm.build.date.utc ro.odm_dlkm.build.date.utc \
                 ro.product.build.date.utc ro.system.build.date.utc ro.system_dlkm.build.date.utc \
                 ro.system_ext.build.date.utc ro.vendor.build.date.utc ro.vendor_dlkm.build.date.utc; do
            rp_reset_if_present "$p" "$base_utc"
        done
    fi

    for fp in ro.build.fingerprint ro.system.build.fingerprint ro.vendor.build.fingerprint \
              ro.product.build.fingerprint ro.odm.build.fingerprint ro.system_ext.build.fingerprint \
              ro.bootimage.build.fingerprint ro.vendor_dlkm.build.fingerprint \
              ro.odm_dlkm.build.fingerprint ro.system_dlkm.build.fingerprint; do
        cur=$(getprop "$fp" 2>/dev/null)
        [ -n "$cur" ] || continue
        new=$(echo "$cur" | sed -E 's#:(user|userdebug|eng)/(release-keys|test-keys|dev-keys)$#:user/release-keys#')
        [ "$new" != "$cur" ] && rp_reset_if_present "$fp" "$new"
    done
    d_cur=$(getprop ro.build.description 2>/dev/null)
    if [ -n "$d_cur" ]; then
        d_new=$(echo "$d_cur" | sed -E 's#-userdebug #-user #; s#-eng #-user #; s# (test-keys|dev-keys)$# release-keys#')
        [ "$d_new" != "$d_cur" ] && rp_reset_if_present ro.build.description "$d_new"
    fi
    f_cur=$(getprop ro.build.flavor 2>/dev/null)
    if [ -n "$f_cur" ]; then
        f_new=$(echo "$f_cur" | sed -E 's#-(userdebug|eng)$#-user#')
        [ "$f_new" != "$f_cur" ] && rp_reset_if_present ro.build.flavor "$f_new"
    fi

    case "$(getprop ro.bootmode 2>/dev/null)" in
        *recovery*) $RESETPROP -n ro.bootmode unknown 2>/dev/null && log "prop ro.bootmode -> unknown" ;;
    esac
    [ -n "$(getprop ro.kernel.qemu 2>/dev/null)" ] \
        && $RESETPROP -n ro.kernel.qemu "" 2>/dev/null && log "prop ro.kernel.qemu cleared"

    rp_del ro.boot.verifiedbooterror
    if [ "$(getprop ro.build.version.sdk 2>/dev/null)" -ge 36 ] 2>/dev/null; then
        rp_del sys.oem_unlock_allowed
    else
        rp_reset_if_present sys.oem_unlock_allowed 0
    fi
}

SHELL_TMP=/data/local/tmp

do_shell_tmp() {
    [ "${fix_shell_tmp:-1}" = "1" ] || return 0
    local mode own ctx changed=""

    if [ ! -d "$SHELL_TMP" ]; then
        mkdir -p "$SHELL_TMP" 2>/dev/null \
            || { log "shell-tmp: $SHELL_TMP absent and not creatable"; return 0; }
        changed="created"
    fi

    mode=$(stat -c %a "$SHELL_TMP" 2>/dev/null)
    own=$(stat -c %u:%g "$SHELL_TMP" 2>/dev/null)
    ctx=$(stat -c %C "$SHELL_TMP" 2>/dev/null)

    if [ "$mode" != "771" ]; then
        chmod 0771 "$SHELL_TMP" 2>/dev/null && changed="$changed mode:${mode:-?}->771"
    fi
    if [ "$own" != "2000:2000" ]; then
        chown 2000:2000 "$SHELL_TMP" 2>/dev/null && changed="$changed owner:${own:-?}->2000:2000"
    fi
    if [ "$ctx" != "u:object_r:shell_data_file:s0" ]; then
        chcon u:object_r:shell_data_file:s0 "$SHELL_TMP" 2>/dev/null \
            && changed="$changed ctx:${ctx:-?}->shell_data_file"
    fi

    [ -n "$changed" ] && log "shell-tmp: ${changed# }"
    return 0
}

shell_tmp_status() {
    local mode own ctx bad=""
    [ -d "$SHELL_TMP" ] || { echo "absent"; return 0; }
    mode=$(stat -c %a "$SHELL_TMP" 2>/dev/null)
    own=$(stat -c %u:%g "$SHELL_TMP" 2>/dev/null)
    ctx=$(stat -c %C "$SHELL_TMP" 2>/dev/null)
    [ "$mode" = "771" ] || bad="$bad mode=$mode"
    [ "$own" = "2000:2000" ] || bad="$bad owner=$own"
    [ "$ctx" = "u:object_r:shell_data_file:s0" ] || bad="$bad ctx=$ctx"
    [ -z "$bad" ] && echo "clean ino=$(stat -c %i "$SHELL_TMP" 2>/dev/null)" \
                  || echo "dirty$bad ino=$(stat -c %i "$SHELL_TMP" 2>/dev/null)"
}

nm_sysd() {
    local d
    for d in /sys/kernel/boot_meta /sys/kernel/nomount; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}
nm_bin() {
    local b
    [ -n "$NM_BIN" ] && [ -x "$NM_BIN" ] && { echo "$NM_BIN"; return 0; }
    for b in /data/adb/modules/meta-nomount/bin/*/nm; do
        [ -x "$b" ] && { echo "$b"; return 0; }
    done
    return 1
}
nm_knob() {
    local b d a
    b=$(nm_bin) && "$b" k "$1" "$2" 2>/dev/null && return 0
    d=$(nm_sysd) || return 1
    case "$1" in
        r) a=release;    [ -e "$d/$a" ] || a=uname_release ;;
        v) a=version;    [ -e "$d/$a" ] || a=uname_version ;;
        c) a=cmdline ;;
        b) a=bootconfig ;;
        *) return 1 ;;
    esac
    [ -w "$d/$a" ] || return 1
    printf '%s' "$2" > "$d/$a" 2>/dev/null
}
nm_knob_ok() { nm_bin >/dev/null 2>&1 || nm_sysd >/dev/null 2>&1; }

do_uname() {
    [ "${spoof_uname:-0}" = "1" ] || return 0
    if ! nm_knob_ok; then
        log "uname: kernel interface absent (needs the nomount uname build)"
        return 0
    fi

    if [ -n "$uname_tail" ]; then
        local tail prefix rel
        tail=$(printf '%s' "$uname_tail" | sed -E 's/^[0-9][0-9.]*-android[0-9]+-//')
        prefix=$(uname -r | grep -oE '^[0-9][0-9.]*-android[0-9]+-')
        rel="${prefix}${tail}"
        nm_knob r "$rel" && log "uname release=$rel"
    fi

    if [ -n "$uname_date" ]; then
        local d head ver
        d=$(printf '%s' "$uname_date" | grep -oE '(Mon|Tue|Wed|Thu|Fri|Sat|Sun) .*$')
        [ -z "$d" ] && d=$uname_date
        head=$(uname -v | sed -E 's/^(#[0-9]+ SMP( [A-Z_]*PREEMPT[A-Z_]*)?).*/\1/')
        ver="$head $d"
        nm_knob v "$ver" && log "uname version=$ver"
    fi
}

do_cmdline() {
    [ "${spoof_cmdline:-$spoof_props}" = "1" ] || return 0
    if [ "${spoof_props:-0}" != "1" ]; then
        log "cmdline: skipped (needs spoof_props=1 to stay consistent)"
        return 0
    fi
    if [ "$(getprop ro.boot.verifiedbootstate 2>/dev/null)" != "green" ]; then
        log "cmdline: skipped (props not normalized to green; check resetprop)"
        return 0
    fi
    local dg
    dg=$(getprop ro.boot.vbmeta.digest 2>/dev/null)

    if nm_knob_ok && [ -r /proc/cmdline ]; then
        local c
        c=$(sed -E 's/([a-z]*boot\.verifiedbootstate)=[^ ]*/\1=green/g;
                    s/([a-z]*boot\.vbmeta\.device_state)=[^ ]*/\1=locked/g;
                    s/([a-z]*boot\.flash\.locked)=[^ ]*/\1=1/g;
                    s/([a-z]*boot\.warranty_bit)=[^ ]*/\1=0/g;
                    s/([a-z]*boot\.veritymode)=[^ ]*/\1=enforcing/g;
                    s/ [a-z]*boot\.verifiedbooterror=[^ ]*//g' /proc/cmdline)
        [ -n "$dg" ] && c=$(printf '%s' "$c" | sed -E "s/([a-z]*boot\.vbmeta\.digest)=[^ ]*/\1=$dg/g")
        nm_knob c "$c" && log "cmdline sanitized (green/locked)"
    fi

    if nm_knob_ok && [ -r /proc/bootconfig ]; then
        local b
        b=$(sed -E '/[a-z]*boot\.verifiedbooterror[[:space:]]*=/d;
                    s/([a-z]*boot\.verifiedbootstate[[:space:]]*=[[:space:]]*")[^"]*/\1green/g;
                    s/([a-z]*boot\.vbmeta\.device_state[[:space:]]*=[[:space:]]*")[^"]*/\1locked/g;
                    s/([a-z]*boot\.flash\.locked[[:space:]]*=[[:space:]]*")[^"]*/\11/g;
                    s/([a-z]*boot\.warranty_bit[[:space:]]*=[[:space:]]*")[^"]*/\10/g;
                    s/([a-z]*boot\.veritymode[[:space:]]*=[[:space:]]*")[^"]*/\1enforcing/g' /proc/bootconfig)
        [ -n "$dg" ] && b=$(printf '%s' "$b" | sed -E "s/([a-z]*boot\.vbmeta\.digest[[:space:]]*=[[:space:]]*\")[^\"]*/\1$dg/g")
        nm_knob b "$b" && log "bootconfig sanitized (green/locked)"
    fi
}

props_status() {
    local n=0 c
    _d() { c=$(getprop "$1" 2>/dev/null); [ -n "$c" ] && [ "$c" != "$2" ] && n=$((n + 1)); }
    _d ro.boot.vbmeta.device_state    locked
    _d ro.boot.verifiedbootstate      green
    _d ro.boot.flash.locked           1
    _d ro.boot.veritymode             enforcing
    _d ro.boot.warranty_bit           0
    _d ro.warranty_bit                0
    _d ro.vendor.boot.warranty_bit    0
    _d ro.vendor.warranty_bit         0
    _d vendor.boot.vbmeta.device_state locked
    _d vendor.boot.verifiedbootstate  green
    _d ro.debuggable                  0
    _d ro.force.debuggable            0
    _d ro.secure                      1
    _d ro.adb.secure                  1
    _d ro.build.type                  user
    _d ro.build.tags                  release-keys
    _d ro.crypto.state                encrypted
    _d ro.secureboot.lockstate        locked
    _d ro.boot.realmebootstate        green
    _d ro.boot.realme.lockstate       1
    [ -n "$(getprop ro.boot.verifiedbooterror 2>/dev/null)" ] && n=$((n + 1))
    case "$(getprop ro.bootmode 2>/dev/null)" in *recovery*) n=$((n + 1)) ;; esac
    [ -n "$(getprop ro.kernel.qemu 2>/dev/null)" ] && n=$((n + 1))
    [ "$(getprop ro.build.version.sdk 2>/dev/null)" -ge 36 ] 2>/dev/null \
        && [ -n "$(getprop sys.oem_unlock_allowed 2>/dev/null)" ] && n=$((n + 1))
    [ "$n" = 0 ] && echo clean || echo "dirty $n"
}

capture_uname_orig() {
    local cache=$NMDIR/uname_orig bid
    bid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    [ -n "$bid" ] || return 0
    if [ ! -f "$cache" ] || [ "$(sed -n 1p "$cache" 2>/dev/null)" != "$bid" ]; then
        { echo "$bid"; uname -r; uname -v; } > "$cache" 2>/dev/null
    fi
}

main() {
    find_resetprop || log "resetprop not found (prop spoofing skipped)"
    capture_uname_orig
    do_vbmeta "$vbmeta_digest"
    do_props
    do_uname
    do_cmdline
    do_shell_tmp
}

[ -n "${NM_SPOOF_SOURCE:-}" ] && return 0 2>/dev/null

case "${1:-}" in
    compute)
        compute_vbmeta_digest
        exit 0 ;;
    verify)
        cur=$(getprop ro.boot.vbmeta.digest 2>/dev/null)
        dg=$(compute_vbmeta_digest)
        if [ -z "$dg" ]; then echo "error";
        elif [ -z "$cur" ]; then echo "absent $dg";
        elif [ "$cur" = "$dg" ]; then echo "match $dg";
        else echo "mismatch $dg"; fi
        exit 0 ;;
    props)
        props_status
        exit 0 ;;
    shell-tmp)
        do_shell_tmp
        exit 0 ;;
    shell-tmp-status)
        shell_tmp_status
        exit 0 ;;
    reset-uname)
        orig=$NMDIR/uname_orig
        [ -s "$orig" ] || { echo "no-baseline"; exit 0; }
        rel=$(sed -n 2p "$orig"); ver=$(sed -n 3p "$orig")
        [ -n "$rel" ] && nm_knob r "$rel"
        [ -n "$ver" ] && nm_knob v "$ver"
        if grep -v -E '^(uname_tail|uname_date)=' "$CONF" > "$CONF.t" 2>/dev/null; then
            printf "uname_tail=''\nuname_date=''\n" >> "$CONF.t"; mv "$CONF.t" "$CONF"
        fi
        echo "reset"
        exit 0 ;;
esac

main
exit 0
