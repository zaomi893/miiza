#!/usr/bin/env python3
"""Skip selected modules in the kernel loader without changing vendor_boot."""

import os
import re
from pathlib import Path


source_path = Path("kernel/module/main.c")
names = [
    name.strip().removesuffix(".ko")
    for name in re.split(r"[,\s]+", os.environ.get("BLACKLIST_MODULES", ""))
    if name.strip()
]
names = list(dict.fromkeys(names))
for name in names:
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", name):
        raise SystemExit(f"Invalid module name in blacklist: {name!r}")

if not names:
    print("Module blacklist is empty")
    raise SystemExit(0)

source = source_path.read_text()
early_anchor = "\tlen = kernel_read_file(f, 0, &buf, INT_MAX, NULL, READING_MODULE);"
late_anchor = "\tmod = layout_and_allocate(info, flags);"
if source.count(early_anchor) != 1 or source.count(late_anchor) != 1:
    raise SystemExit("Kernel module loader anchors changed; refusing unsafe injection")

conditions = " ||\n\t     ".join(
    f'!strcmp(f->f_path.dentry->d_name.name, "{name}.ko")' for name in names
)
early_block = (
    "\t/* A first-stage load list may still name a module built into Image. */\n"
    "\tif (S_ISREG(file_inode(f)->i_mode) &&\n"
    f"\t    ({conditions})) {{\n"
    "\t\tpr_info(\"Skipping blocklisted module file %s\\n\",\n"
    "\t\t\tf->f_path.dentry->d_name.name);\n"
    "\t\treturn 0;\n"
    "\t}\n\n"
)
source = source.replace(early_anchor, early_block + early_anchor, 1)

late_block = "".join(
    f'\tif (!strcmp(info->name, "{name}")) {{\n'
    "\t\tpr_info(\"Skipping blocklisted module %s\\n\", info->name);\n"
    "\t\terr = 0;\n"
    "\t\tgoto free_copy;\n"
    "\t}\n"
    for name in names
)
source = source.replace(late_anchor, late_block + late_anchor, 1)
source_path.write_text(source)
print("Blocklisted modules: " + ", ".join(names))
