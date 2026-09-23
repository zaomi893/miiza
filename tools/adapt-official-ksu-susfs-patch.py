#!/usr/bin/env python3
"""Adapt the pinned SUSFS patch to the pinned official KernelSU source."""

import hashlib
import subprocess
import sys
from pathlib import Path


KSU_COMMIT = "623eba3e092b911a3a7389b7d87622a5835d2f3a"
SUSFS_COMMIT = "8dce4337bcd15807c5449bbeff6e02a967138db0"
PATCH_SHA256 = "17d6ec20bb418e9e2e594ab90ca1f5a078008259ab0fbe3f90e0bc815f2e577a"


def revision(path: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
    ).strip()


def pin_susfs(path: Path) -> None:
    if revision(path) != SUSFS_COMMIT:
        subprocess.run(
            ["git", "-C", str(path), "fetch", "--depth=1", "origin", SUSFS_COMMIT],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(path), "checkout", "--detach", SUSFS_COMMIT],
            check=True,
        )
    if revision(path) != SUSFS_COMMIT:
        raise ValueError("failed to pin the SUSFS source")


def replace_once(content: str, old: str, new: str) -> str:
    count = content.count(old)
    if count != 1:
        raise ValueError(f"expected one occurrence of {old!r}, found {count}")
    return content.replace(old, new, 1)


def adapt(content: str) -> str:
    content = replace_once(
        content,
        "-kernelsu-objs += hook/x86_64/syscall_hook.o\n-endif\n",
        "-kernelsu-objs += hook/x86_64/syscall_hook.o\n"
        "-else ifeq ($(CONFIG_RISCV),y)\n"
        "-kernelsu-objs += hook/riscv64/patch_memory.o\n"
        "-kernelsu-objs += hook/riscv64/syscall_hook.o\n"
        "-endif\n",
    )
    content = replace_once(content, "@@ -4,24 +4,12 @@", "@@ -4,27 +4,12 @@")

    parm_count = 0
    register_count = 0
    updated = []
    for line in content.splitlines(keepends=True):
        if line.startswith("-") and not line.startswith("---"):
            parm_count += line.count("PT_REGS_PARM1(")
            register_count += line.count("regs->__PT_PARM1_REG")
            line = line.replace("PT_REGS_PARM1(", "PT_REGS_SYSCALL_PARM1(")
            line = line.replace("regs->__PT_PARM1_REG", "PT_REGS_SYSCALL_PARM1(regs)")
        updated.append(line)
    if (parm_count, register_count) != (6, 3):
        raise ValueError(
            f"unexpected syscall argument changes: {parm_count} macros, {register_count} registers"
        )
    return "".join(updated)


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--pin-susfs":
        pin_susfs(Path(sys.argv[2]).resolve(strict=True))
        return
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: adapt-official-ksu-susfs-patch.py --pin-susfs SUSFS_ROOT "
            "| KSU_ROOT SUSFS_PATCH"
        )
    ksu_root = Path(sys.argv[1]).resolve(strict=True)
    patch_path = Path(sys.argv[2]).resolve(strict=True)
    susfs_root = patch_path.parents[2]
    if revision(ksu_root) != KSU_COMMIT:
        raise ValueError("official KernelSU revision changed; review the SUSFS adaptation")
    if revision(susfs_root) != SUSFS_COMMIT:
        raise ValueError("SUSFS revision changed; review the SUSFS adaptation")
    source = patch_path.read_bytes().replace(b"\r\n", b"\n")
    if hashlib.sha256(source).hexdigest() != PATCH_SHA256:
        raise ValueError("SUSFS patch changed; review the SUSFS adaptation")
    if b"\r" in source:
        raise ValueError("unexpected SUSFS patch line endings")
    sys.stdout.buffer.write(adapt(source.decode("utf-8")).encode("utf-8"))


if __name__ == "__main__":
    main()
