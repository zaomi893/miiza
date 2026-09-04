#!/usr/bin/env python3
"""Trim the OnePlus vendor module graph to the packages that are actually
published in OnePlusOSS public source.

Background
----------
OnePlus publishes only part of the SM8850 vendor kernel modules.  In the
`android_kernel_modules_and_devicetree_oneplus_sm8850` repo only the following
families exist under vendor/oplus/kernel/: audio, boot, camera, charger, cpu,
device_info (plus hardware/radio).  The aggregate target
`kernel_platform/oplus/bazel/oplus_modules.bzl` nevertheless lists ~130 oplus
DDK targets, ~89 of which point at packages that do not exist in the public
repo (dfr, dft, mm, network, storage, synchronize, touchpanel, tp, vibrator,
wifi, sensor, nfc, ipc, graphics, hans, power, ...).  Building any dist target
that pulls `*_all_oplus_ddk_modules_files` therefore fails at Bazel analysis
with "no such package".

This script rewrites the module graph so that only targets whose package
directory exists in the assembled tree remain, and removes the known missing
`//vendor/oplus/kernel/synchronize` dependency from the CPU sched_ext module
(verified to be an optional runtime hook: sched_assist only consumes
`struct sched_assist_locking_ops` registered through
`register_sched_assist_locking_ops()`, and no public source references any
symbol exported by oplus_locking_strategy).

Run from the directory that contains the assembled `source/` tree:
    python3 scripts/trim_public_oplus.py
"""
import ast
import os
import re
import sys

ROOT = "source"

MISSING = ("//vendor/oplus/kernel/synchronize:oplus_locking_strategy",
           "//vendor/oplus/kernel/synchronize:oplus_lock_torture")

def package_exists(label: str) -> bool:
    """Return True if the Bazel package directory for a //pkg:target exists."""
    if not label.startswith("//"):
        return False
    pkg = label.split(":", 1)[0][2:]
    return os.path.isdir(os.path.join(ROOT, pkg))

def rewrite_target_list(path: str) -> int:
    """Filter oplus_ddk_targets to public packages; return # dropped."""
    full = os.path.join(ROOT, path)
    src = open(full, encoding="utf-8").read()

    # Find the oplus_ddk_targets = [ ... ] literal with a bracket matcher.
    m = re.search(r'(oplus_ddk_targets\s*=\s*\[)', src)
    if not m:
        print(f"[skip] no oplus_ddk_targets list in {path}")
        return 0
    start = m.end() - 1  # index of '['
    depth = 0
    i = start
    while i < len(src):
        c = src[i]
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                break
        i += 1
    if depth != 0:
        raise SystemExit(f"ERROR: unbalanced list in {path}")
    body = src[start:i + 1]

    # Parse the Starlark list: split on top-level commas, evaluate each item.
    items, cur, depth, in_str, esc = [], [], 0, False, False
    for ch in body[1:-1]:
        if in_str:
            cur.append(ch)
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"' or ch == "'":
                in_str = False
            continue
        if ch == '"' or ch == "'":
            in_str = True
            cur.append(ch)
        elif ch in "[(":
            depth += 1
            cur.append(ch)
        elif ch in "])":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            items.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        items.append("".join(cur).strip())

    kept, dropped = [], []
    for it in items:
        if not it:
            continue
        # Dynamic names like "{target}_camera_extension".format(target) can't
        # be checked statically; their packages (camera/charger/...) exist.
        if it.startswith('"') and ".format(" not in it:
            try:
                label = ast.literal_eval(it)
            except Exception:
                kept.append(it)
                continue
            if label in MISSING or not package_exists(label):
                dropped.append(it)
            else:
                kept.append(it)
        else:
            kept.append(it)

    if not dropped:
        print(f"[ok] nothing to drop in {path}")
        return 0

    new_body = "oplus_ddk_targets = [\n" + "\n".join(
        f'        "{k}",' for k in kept) + "\n    ]"
    new_src = src[:start] + new_body + src[i + 1:]
    open(full, "w", encoding="utf-8").write(new_src)
    print(f"[trim] {path}: kept {len(kept)}, dropped {len(dropped)}")
    for d in dropped:
        print(f"        - {d}")
    return len(dropped)

def drop_missing_lines(path: str) -> int:
    """Remove any remaining line in the file that references a //vendor/oplus
    target whose package does not exist (catches `+=` blocks such as the
    canoe-only wifi:wonder addition and the inject-test feature block)."""
    full = os.path.join(ROOT, path)
    src = open(full, encoding="utf-8").read()
    out_lines = []
    n = 0
    for line in src.splitlines(keepends=True):
        for m in re.finditer(r'"//vendor/oplus/[a-zA-Z_/]+:[a-zA-Z0-9_]+"', line):
            label = m.group(0).strip('"')
            if label in MISSING or not package_exists(label):
                n += 1
                line = ""
                break
        if line:
            out_lines.append(line)
    if n:
        open(full, "w", encoding="utf-8").write("".join(out_lines))
        print(f"[trim] {path}: removed {n} missing ref line(s) outside main list")
    else:
        print(f"[ok] no stray missing refs in {path}")
    return n

def drop_synchronize_deps(path: str) -> int:
    """Remove synchronize deps from sched_ext_ko_deps in oplus_local_modules.bzl."""
    full = os.path.join(ROOT, path)
    src = open(full, encoding="utf-8").read()
    n = 0
    for bad in MISSING:
        while bad in src:
            # remove the whole line containing the reference
            pat = re.compile(r'[ \t]*"[^"]*' + re.escape(bad) + r'",?\n')
            new, cnt = pat.subn("", src, count=1)
            if cnt:
                src = new
                n += 1
            else:
                break
    if n:
        open(full, "w", encoding="utf-8").write(src)
        print(f"[trim] {path}: removed {n} synchronize dep line(s)")
    else:
        print(f"[ok] no synchronize deps in {path}")
    return n

def patch_charger_modules(path: str) -> int:
    """Remove conditional deps that reference missing touchpanel/dft packages."""
    full = os.path.join(ROOT, path)
    if not os.path.isfile(full):
        print(f"[skip] {path} not present")
        return 0
    src = open(full, encoding="utf-8").read()
    bad = [
        "//vendor/oplus/kernel/touchpanel/kernelFwUpdate/bazel:oplus_bsp_fw_update",
        "//vendor/oplus/kernel/touchpanel/kernelFwUpdate/bazel:oplus_bsp_fw_update_headers",
        "//vendor/oplus/kernel/dft/bazel:oplus_bsp_dft_kernel_fb",
        "//vendor/oplus/kernel/dft/bazel:oplus_bsp_dft_olc",
    ]
    n = 0
    for b in bad:
        pat = re.compile(r'[ \t]*"' + re.escape(b) + r'",?\n')
        new, cnt = pat.subn("", src)
        if cnt:
            src = new
            n += cnt
    if n:
        open(full, "w", encoding="utf-8").write(src)
        print(f"[trim] {path}: removed {n} missing-dep line(s)")
    else:
        print(f"[ok] nothing to drop in {path}")
    return n

def main() -> int:
    if not os.path.isdir(ROOT):
        print(f"ERROR: '{ROOT}/' not found. Run from the workspace root that "
              f"contains the assembled source/ tree.", file=sys.stderr)
        return 2
    rewrite_target_list("kernel_platform/oplus/bazel/oplus_modules.bzl")
    drop_missing_lines("kernel_platform/oplus/bazel/oplus_modules.bzl")
    drop_synchronize_deps("vendor/oplus/kernel/cpu/oplus_local_modules.bzl")
    patch_charger_modules("vendor/oplus/kernel/charger/v1/modules.bzl")
    patch_charger_modules("vendor/oplus/kernel/charger/v2/modules.bzl")
    print("done")
    return 0

if __name__ == "__main__":
    sys.exit(main())
