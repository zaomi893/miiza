#!/usr/bin/env python3
"""Apply the built-in NoMount call sites after other VFS patches.

SUSFS also edits proc/readdir and makes a traditional context patch fragile.
This installer scopes every insertion to its owning function, refuses missing
or duplicate anchors, and is idempotent through a per-site marker.
"""

from pathlib import Path
import sys


root = Path(sys.argv[1]).resolve()


def read(rel: str) -> tuple[Path, str]:
    path = root / rel
    return path, path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="\n")


def insert(rel: str, anchor: str, addition: str, marker: str, *, after=True) -> None:
    path, text = read(rel)
    if marker in text:
        return
    count = text.count(anchor)
    if count != 1:
        raise RuntimeError(f"{rel}: expected one anchor for {marker}, found {count}")
    replacement = anchor + addition if after else addition + anchor
    write(path, text.replace(anchor, replacement, 1))


def function_insert(rel: str, start: str, end: str, anchor: str,
                    addition: str, marker: str, *, after=True) -> None:
    path, text = read(rel)
    begin = text.find(start)
    finish = text.find(end, begin + len(start))
    if begin < 0 or finish < 0:
        raise RuntimeError(f"{rel}: function bounds missing for {marker}")
    body = text[begin:finish]
    if marker in body:
        return
    if body.count(anchor) != 1:
        raise RuntimeError(f"{rel}: anchor missing/ambiguous for {marker}")
    replacement = anchor + addition if after else addition + anchor
    body = body.replace(anchor, replacement, 1)
    write(path, text[:begin] + body + text[finish:])


insert(
    "fs/Kconfig", "config IO_WQ\n\tbool\n",
    "\nconfig NOMOUNT\n\tbool \"NoMount Path Redirection Subsystem\"\n"
    "\tdefault n\n\thelp\n\t  Mountless VFS injection and scoped path hiding.\n",
    "config NOMOUNT",
)
insert(
    "fs/Makefile", "obj-$(CONFIG_BUFFER_HEAD)\t+= buffer.o mpage.o\n",
    "obj-$(CONFIG_NOMOUNT) += nomount.o\n\n", "CONFIG_NOMOUNT) += nomount.o",
    after=False,
)
function_insert(
    "fs/proc/task_mmu.c", "show_map_vma(", "static int show_map",
    "\t\tino = inode->i_ino;\n",
    "#ifdef CONFIG_NOMOUNT\n"
    "\t\t{ extern void nomount_spoof_mmap_metadata(const struct inode *, dev_t *, unsigned long *);\n"
    "\t\t  nomount_spoof_mmap_metadata(inode, &dev, &ino); }\n"
    "#endif\n",
    "nomount_spoof_mmap_metadata",
)
function_insert(
    "fs/proc/task_mmu.c", "show_map_vma(", "static int show_map",
    "\tget_vma_name(vma, &path, &name, &name_fmt);\n",
    "#ifdef CONFIG_NOMOUNT\n"
    "\t{ extern bool nomount_pathhide_hide_path(const struct path *);\n"
    "\t  if (path && nomount_pathhide_hide_path(path)) path = NULL; }\n"
    "#endif\n",
    "path && nomount_pathhide_hide_path",
)
function_insert(
    "fs/proc/base.c", "static int do_proc_readlink", "static int proc_pid_readlink",
    "\tint len;\n",
    "#ifdef CONFIG_NOMOUNT\n"
    "\t{ extern bool nomount_pathhide_hide_path(const struct path *);\n"
    "\t  if (nomount_pathhide_hide_path(path)) { kfree(tmp); return -ENOENT; } }\n"
    "#endif\n",
    "nomount_pathhide_hide_path(path)",
)
function_insert(
    "fs/namei.c", "int inode_permission(", "EXPORT_SYMBOL(inode_permission)",
    "\tint retval;\n",
    "#ifdef CONFIG_NOMOUNT\n"
    "\t{ extern bool nomount_pathhide_hide_inode(const struct inode *);\n"
    "\t  if (!(mask & MAY_WRITE) && nomount_pathhide_hide_inode(inode)) return -ENOENT; }\n"
    "#endif\n",
    "nomount_pathhide_hide_inode(inode)",
)
function_insert(
    "fs/stat.c", "int vfs_getattr_nosec(", "EXPORT_SYMBOL(vfs_getattr_nosec)",
    "\tstruct inode *inode = d_backing_inode(path->dentry);\n",
    "#ifdef CONFIG_NOMOUNT\n"
    "\t{ extern bool nomount_pathhide_hide_inode(const struct inode *);\n"
    "\t  if (nomount_pathhide_hide_inode(inode)) return -ENOENT; }\n"
    "#endif\n",
    "nomount_pathhide_hide_inode(inode)",
)

for suffix, next_bound in (("", "SYSCALL_DEFINE3(getdents,"),
                           ("64", "SYSCALL_DEFINE3(getdents64,")):
    struct_name = f"struct getdents_callback{suffix} {{"
    function_insert(
        "fs/readdir.c", struct_name, "};", "\tstruct dir_context ctx;\n",
        "\tstruct inode *dir_inode;\n", "struct inode *dir_inode;",
    )
    fill_start = f"static bool filldir{suffix}("
    function_insert(
        "fs/readdir.c", fill_start, next_bound,
        "\tbuf->error = verify_dirent_name(name, namlen);\n",
        "#ifdef CONFIG_NOMOUNT\n"
        "\t{ extern bool nomount_pathhide_hide_dirent(const struct inode *, u64, const char *, int);\n"
        "\t  if (nomount_pathhide_hide_dirent(buf->dir_inode, ino, name, namlen)) return true; }\n"
        "#endif\n",
        "nomount_pathhide_hide_dirent(buf->dir_inode", after=False,
    )

function_insert(
    "fs/readdir.c", "SYSCALL_DEFINE3(getdents,", "struct getdents_callback64",
    "\tif (!fd_file(f))\n\t\treturn -EBADF;\n",
    "\tbuf.dir_inode = file_inode(fd_file(f));\n",
    "buf.dir_inode = file_inode",
)
function_insert(
    "fs/readdir.c", "SYSCALL_DEFINE3(getdents64,", "#ifdef CONFIG_COMPAT",
    "\tif (!fd_file(f))\n\t\treturn -EBADF;\n",
    "\tbuf.dir_inode = file_inode(fd_file(f));\n",
    "buf.dir_inode = file_inode",
)

print("NoMount VFS call sites installed")
