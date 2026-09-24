#!/usr/bin/env python3
"""Port the workflow-pinned Oplus zram_opt.c into the built-in ZRAM code path."""

import argparse
import hashlib
import re
import urllib.request
from pathlib import Path


SOURCE_PATH = "vendor/oplus/kernel/mm/zram_opt/zram_opt.c"
REQUIRED_SOURCE_MARKERS = (
    "static void zo_set_swappiness",
    "register_trace_android_vh_tune_swappiness",
    "register_trace_android_vh_throttle_direct_reclaim_bypass",
    "register_trace_android_vh_page_cache_ra_order_bypass",
    "extern bool free_zram_is_ok(void);",
)
HOOK_HEADERS = {
    "android_vh_tune_swappiness": "include/trace/hooks/vmscan.h",
    "android_vh_throttle_direct_reclaim_bypass": "include/trace/hooks/vmscan.h",
    "android_rvh_set_balance_anon_file_reclaim": "include/trace/hooks/vmscan.h",
    "android_rvh_kswapd_shrink_node": "include/trace/hooks/vmscan.h",
    "android_vh_page_cache_ra_order_bypass": "include/trace/hooks/mm.h",
    "android_vh_init_adjust_zone_wmark": "include/trace/hooks/mm.h",
    "android_rvh_perform_reclaim": "include/trace/hooks/mm.h",
}
PORT_CONFIG = "CONFIG_OPLUS_LZ4KD_ZRAM_OPT"
REQUIRED_HOOKS = {
    "android_vh_tune_swappiness",
    "android_vh_throttle_direct_reclaim_bypass",
    "android_vh_page_cache_ra_order_bypass",
}


def adapt_source(
    source: str,
    source_repo: str,
    source_commit: str,
    unavailable_hooks: set[str] | None = None,
) -> str:
    for marker in REQUIRED_SOURCE_MARKERS:
        if marker not in source:
            raise ValueError(f"Pinned zram_opt.c is missing required source marker: {marker}")

    source = source.replace("#include <linux/sa_group.h>\n", "")
    source = source.replace("#include <linux/sa_common.h>\n", "")
    source = source.replace(
        "#include <linux/module.h>\n",
        "#include <linux/module.h>\n#include <linux/kallsyms.h>\n",
        1,
    )

    # These features are portable to the matching GKI trees and are enabled
    # only when the LZ4KD-specific Kconfig option is selected.
    for upstream_config in (
        "CONFIG_DYNAMIC_TUNING_SWAPPINESS",
        "CONFIG_OPLUS_BALANCE_ANON_FILE_RECLAIM",
        "CONFIG_OPLUS_EXTRA_FREE_KBYTES",
    ):
        source = source.replace(upstream_config, PORT_CONFIG)

    # The generic kernel does not build Oplus mm_osvelte or hybridswapd as
    # built-ins; their source-only sections must not introduce module imports.
    source = source.replace(
        "CONFIG_OPLUS_FEATURE_MM_OSVELTE",
        "CONFIG_OPLUS_LZ4KD_PORT_WITH_MM_OSVELTE",
    )
    source = source.replace(
        "CONFIG_HYBRIDSWAP_SWAPD",
        "CONFIG_OPLUS_LZ4KD_PORT_WITH_HYBRIDSWAP",
    )

    # ezr_enabled is declared and initialized only by mm_osvelte, which is
    # deliberately excluded from this in-tree GKI port.  Without that state,
    # retain the generic swappiness hook and remove its source-only bypass.
    source, removed_ezram_bypass = re.subn(
        r"(?m)^\s*if\s*\(\s*ezr_enabled\s*\)\s*\r?\n"
        r"\s*goto\s+bypass_swappiness_hook\s*;\s*\r?\n",
        "",
        source,
        count=1,
    )
    if re.search(r"\bgoto\s+bypass_swappiness_hook\s*;", source):
        raise ValueError("An unadapted mm_osvelte-only swappiness bypass remains")
    source, removed_bypass_label = re.subn(
        r"(?m)^bypass_swappiness_hook:\s*\r?\n", "", source, count=1
    )
    if removed_ezram_bypass and removed_bypass_label != 1:
        raise ValueError("Could not remove the now-unused swappiness bypass label")

    source = source.replace(
        "extern bool free_zram_is_ok(void);",
        """/*
 * The OEM zram driver exports free_zram_is_ok() with device-specific
 * watermarks.  The matching generic GKI zram has no equivalent API, so use
 * the generic swap-space availability signal instead of importing the OEM
 * zram.ko symbol.
 */
static bool free_zram_is_ok(void)
{
\treturn get_nr_swap_pages() > 0;
}""",
        1,
    )

    high_priority = re.compile(
        r"test_task_is_rt\s*\(\s*current\s*\)\s*\|\|\s*"
        r"current->prio\s*==\s*MAX_RT_PRIO\s*\|\|\s*"
        r"test_task_ux\s*\(\s*current\s*\)"
        r"(?:\s*\|\|\s*test_bit\s*\(\s*IM_FLAG_SURFACEFLINGER\s*,\s*&im_flag\s*\))?",
        re.MULTILINE,
    )
    source, replaced_high_priority = high_priority.subn(
        "current->prio <= MAX_RT_PRIO", source
    )
    if replaced_high_priority == 0:
        raise ValueError("Could not adapt the source-specific Oplus high-priority task check")

    source = re.sub(
        r"^\s*unsigned long im_flag\s*=\s*oplus_get_im_flag\(current\);\s*\n",
        "",
        source,
        flags=re.MULTILINE,
    )
    source = source.replace("test_task_is_rt(current)", "(current->prio < MAX_RT_PRIO)")
    source = source.replace("test_task_ux(current)", "false")

    for hook, handler in (
        ("android_rvh_kswapd_shrink_node", "mem_cgroup_flush_kswapd"),
        ("android_rvh_perform_reclaim", "mem_cgroup_flush_reclaim"),
    ):
        call = re.compile(
            rf"android_rvh_probe_register\(\s*"
            rf"p__tracepoint_{hook}\s*,\s*{handler}\s*,\s*NULL\s*\)",
            re.MULTILINE,
        )
        source, _ = call.subn(
            f"register_trace_{hook}({handler}, NULL)", source
        )

    source = source.replace(
        "osvelte_kallsyms_lookup_name", "kallsyms_lookup_name"
    )
    source = re.sub(
        r"mem_cgroup_flush_stats_dup\s*=\s*"
        r"kallsyms_lookup_name\(\"mem_cgroup_flush_stats\"\);",
        "mem_cgroup_flush_stats_dup = "
        "(mem_cgroup_flush_stats_t)kallsyms_lookup_name(\"mem_cgroup_flush_stats\");",
        source,
    )

    if unavailable_hooks:
        source = source.replace(
            "#include <linux/kallsyms.h>\n",
            "#include <linux/kallsyms.h>\n#include <linux/errno.h>\n",
            1,
        )
        stubs = [
            "/* Optional hooks absent from this workflow's kernel snapshot. */\n"
        ]
        for hook in sorted(unavailable_hooks):
            stubs.extend(
                (
                    f"#define register_trace_{hook}(probe, data) "
                    "({ (void)(probe); (void)(data); -EOPNOTSUPP; })\n",
                    f"#define unregister_trace_{hook}(probe, data) "
                    "do { (void)(probe); (void)(data); } while (0)\n",
                )
            )
        source = source.replace(
            "#include <linux/kallsyms.h>\n",
            "#include <linux/kallsyms.h>\n" + "".join(stubs),
            1,
        )

    # Oplus UX / SurfaceFlinger task classification lives in sched_assist,
    # which remains a loadable vendor module.  The in-tree port preserves the
    # RT-priority reclaim bypass without linking a built-in to that module.
    if any(
        token in source
        for token in (
            "linux/sa_group.h",
            "linux/sa_common.h",
            "test_task_is_rt(current)",
            "test_task_ux(current)",
            "oplus_get_im_flag(current)",
            "IM_FLAG_SURFACEFLINGER",
            "android_rvh_probe_register(",
            "osvelte_kallsyms_lookup_name",
            "extern bool free_zram_is_ok(void);",
        )
    ):
        raise ValueError("Unadapted Oplus module-only dependency remains in zram_opt.c")

    provenance = (
        f"/* In-tree LZ4KD port from {source_repo}@{source_commit}: {SOURCE_PATH}. */\n"
        "/* Oplus mm_osvelte, hybridswapd and sched_assist-only task tags are not linked. */\n"
    )
    if source.startswith("// SPDX-License-Identifier: GPL-2.0-only\n"):
        source = source.replace(
            "// SPDX-License-Identifier: GPL-2.0-only\n",
            "// SPDX-License-Identifier: GPL-2.0-only\n" + provenance,
            1,
        )
    else:
        source = provenance + source
    return source


def download_source(repo: str, commit: str) -> str:
    url = f"https://raw.githubusercontent.com/{repo}/{commit}/{SOURCE_PATH}"
    request = urllib.request.Request(url, headers={"User-Agent": "Codex-kernel-build"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8")


def integrate(kernel_root: Path, source: str, repo: str, commit: str) -> str:
    zram_dir = kernel_root / "drivers/block/zram"
    kconfig_path = zram_dir / "Kconfig"
    makefile_path = zram_dir / "Makefile"
    for required in (kconfig_path, makefile_path):
        if not required.is_file():
            raise SystemExit(f"Missing expected kernel integration file: {required}")

    initial_port = adapt_source(source, repo, commit)
    unavailable_hooks = set()
    for hook, header_rel in HOOK_HEADERS.items():
        if f"register_trace_{hook}" not in initial_port:
            continue
        header_path = kernel_root / header_rel
        if not header_path.is_file() or hook not in header_path.read_text():
            if hook in REQUIRED_HOOKS:
                raise SystemExit(
                    f"Pinned zram_opt.c requires {hook}, absent from {header_path}"
                )
            unavailable_hooks.add(hook)

    ported_source = adapt_source(
        source, repo, commit, unavailable_hooks=unavailable_hooks
    )
    if unavailable_hooks:
        print(
            "Optional Oplus zram_opt hooks unavailable in this kernel snapshot: "
            + ", ".join(sorted(unavailable_hooks))
        )

    source_hash = hashlib.sha256(source.encode("utf-8")).hexdigest()
    (zram_dir / "oplus_bsp_zram_opt.c").write_text(
        ported_source, encoding="utf-8"
    )

    kconfig = kconfig_path.read_text(encoding="utf-8")
    if "config OPLUS_LZ4KD_ZRAM_OPT" not in kconfig:
        kconfig += (
            "\n\nconfig OPLUS_LZ4KD_ZRAM_OPT\n"
            '\tbool "Oplus zram optimization port for LZ4KD builds"\n'
            "\tdepends on ZRAM && ZRAM_BACKEND_LZ4KD && KALLSYMS_ALL\n"
            "\tdefault n\n"
            "\thelp\n"
            "\t  Build the matching Oplus zram_opt.c snapshot into the kernel.\n"
            "\t  This option is enabled by the LZ4KD build workflow only.\n"
        )
        kconfig_path.write_text(kconfig, encoding="utf-8")

    makefile = makefile_path.read_text(encoding="utf-8")
    object_rule = "obj-$(CONFIG_OPLUS_LZ4KD_ZRAM_OPT) += oplus_bsp_zram_opt.o"
    if object_rule not in makefile:
        makefile = makefile.rstrip() + "\n" + object_rule + "\n"
        makefile_path.write_text(makefile, encoding="utf-8")

    defconfig_path = kernel_root / "arch/arm64/configs/gki_defconfig"
    if not defconfig_path.is_file():
        raise SystemExit(f"Missing GKI defconfig: {defconfig_path}")
    defconfig = defconfig_path.read_text(encoding="utf-8")
    defconfig = re.sub(
        rf"^\s*{PORT_CONFIG}=.*\n?", "", defconfig, flags=re.MULTILINE
    )
    defconfig_path.write_text(
        defconfig.rstrip() + f"\n{PORT_CONFIG}=y\n", encoding="utf-8"
    )
    return source_hash


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel-root", type=Path, required=True)
    parser.add_argument("--source-repo", required=True)
    parser.add_argument("--source-commit", required=True)
    args = parser.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.source_repo):
        raise SystemExit(f"Invalid GitHub source repository: {args.source_repo!r}")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.source_commit):
        raise SystemExit(f"Expected a pinned 40-character commit, got {args.source_commit!r}")

    try:
        source = download_source(args.source_repo, args.source_commit)
        source_hash = integrate(
            args.kernel_root, source, args.source_repo, args.source_commit
        )
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error

    print(
        "Integrated Oplus zram_opt.c from "
        f"{args.source_repo}@{args.source_commit} ({source_hash})"
    )


if __name__ == "__main__":
    main()
