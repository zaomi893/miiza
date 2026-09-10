#!/bin/sh
set -eu

# NoMount may execute ksud for its documented module APIs, but it must never
# mutate the daemon, its inode flags, or the sibling multicall entry. Such state
# survives a kernel switch and can prevent ReSukiSU from updating userspace.
module_dir="$(CDPATH= cd -- "$(dirname -- "$0")/module" && pwd)"
pattern='(chattr|cp|mv|rm|ln|install|truncate|touch|dd)[[:space:]].*(/data/adb/ksud|\$\{?KSUD\}?|/data/adb/ksu/bin/ksu_susfs|\$\{?SUSFS_BIN\}?)'

if grep -RInE --include='*.sh' --include='*.html' "$pattern" "$module_dir"; then
    echo "error: NoMount must not mutate ksud or ksu_susfs" >&2
    exit 1
fi

if grep -RInE --include='*.sh' '(^|[[:space:]])(KSUD|SUSFS_BIN)=' "$module_dir"; then
    echo "error: obsolete ksud mutation guard returned" >&2
    exit 1
fi

echo "NoMount ksud isolation check passed"
