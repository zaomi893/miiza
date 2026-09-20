#!/usr/bin/env python3
"""Remove legacy in-tree KernelSU hooks from a SUSFS GKI patch.

KowSU master installs equivalent hooks dynamically. Keeping both hook paths
would either reference the retired ABI or run the same interception twice.
The SUSFS filesystem, mount, map, kstat and AVC-spoofing hunks remain intact.
"""

from __future__ import annotations

import argparse
from pathlib import Path


LEGACY_SYMBOLS = (
    "ksu_is_input_hook_enabled",
    "ksu_su_compat_enabled",
    "ksu_handle_execveat",
    "ksu_handle_post_execveat_sucompat",
    "ksu_handle_faccessat",
    "ksu_is_init_rc_hook_enabled",
    "ksu_handle_sys_read",
    "ksu_handle_vfs_fstat",
    "ksu_handle_stat",
    "ksu_handle_sys_reboot",
    "ksu_handle_setresuid",
    "ksu_selinux_hide_running",
    "ksu_selinux_hide_enabled",
    "fake_status",
    "security_context_to_sid_with_policy",
    "security_sid_to_context_with_policy",
    "security_compute_av_user_with_policy",
)


def split_sections(lines: list[str]) -> tuple[list[str], list[list[str]]]:
    preamble: list[str] = []
    sections: list[list[str]] = []
    current: list[str] | None = None
    for line in lines:
        if line.startswith("diff --git "):
            current = [line]
            sections.append(current)
        elif current is None:
            preamble.append(line)
        else:
            current.append(line)
    return preamble, sections


def filter_section(section: list[str]) -> list[str]:
    first_hunk = next((index for index, line in enumerate(section) if line.startswith("@@ ")), None)
    if first_hunk is None:
        return section

    header = section[:first_hunk]
    hunks: list[list[str]] = []
    current: list[str] = []
    for line in section[first_hunk:]:
        if line.startswith("@@ "):
            if current:
                hunks.append(current)
            current = [line]
        else:
            current.append(line)
    if current:
        hunks.append(current)

    kept = [
        hunk
        for hunk in hunks
        if not any(symbol in line for line in hunk if line.startswith("+") for symbol in LEGACY_SYMBOLS)
    ]
    if not kept:
        return []
    return header + [line for hunk in kept for line in hunk]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("patch", type=Path)
    args = parser.parse_args()

    original = args.patch.read_text(encoding="utf-8").splitlines(keepends=True)
    preamble, sections = split_sections(original)
    filtered = preamble + [line for section in sections for line in filter_section(section)]
    text = "".join(filtered)

    remaining = [symbol for symbol in LEGACY_SYMBOLS if symbol in text]
    if remaining:
        raise SystemExit(f"legacy KowSU hook references remain: {', '.join(remaining)}")
    if "diff --git a/fs/susfs.c" not in text and "diff --git a/fs/Makefile" not in text:
        raise SystemExit("SUSFS core patch content was removed unexpectedly")

    args.patch.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
