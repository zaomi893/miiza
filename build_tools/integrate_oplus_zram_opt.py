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

    # Several OEM snapshots carry private copies of the zone iterators, but
    # every target GKI tree already provides these through linux/mmzone.h.
    # Drop the copies and use the kernel's exported helpers to avoid duplicate
    # global symbols when linking vmlinux.
    zone_iterator_signatures = (
        "struct pglist_data *first_online_pgdat(void)",
        "struct pglist_data *next_online_pgdat(struct pglist_data *pgdat)",
        "struct zone *next_zone(struct zone *zone)",
    )
    zone_iterators_present = [signature in source for signature in zone_iterator_signatures]
    if any(zone_iterators_present):
        if not all(zone_iterators_present):
            raise ValueError("Pinned zram_opt.c contains only part of the zone iterator helpers")
        zone_iterator_block = re.compile(
            r"(?ms)^struct pglist_data \*first_online_pgdat\(void\)\s*\{.*?"
            r"^struct pglist_data \*next_online_pgdat\(struct pglist_data \*pgdat\)\s*\{.*?"
            r"^struct zone \*next_zone\(struct zone \*zone\)\s*\{.*?^\}\s*\r?\n"
        )
        source, removed_zone_iterators = zone_iterator_block.subn(
            "", source, count=1
        )
        if removed_zone_iterators != 1:
            raise ValueError("Could not isolate the duplicate Oplus zone iterator helpers")

    source = source.replace(
        "extern bool free_zram_is_ok(void);",
        "extern bool oplus_zram_free_watermark_ok(void);",
        1,
    )
    source = source.replace(
        "free_zram_is_ok()", "oplus_zram_free_watermark_ok()"
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


def integrate_kernel_zram_watermark(kernel_root: Path) -> None:
    """Add the OEM free-zram watermark using the generic driver's zram0 state."""
    zram_dir = kernel_root / "drivers/block/zram"
    driver_path = zram_dir / "zram_drv.c"
    header_path = zram_dir / "zram_drv.h"
    oplus_header_path = kernel_root / "include/linux/oplus_zram_watermark.h"
    for required in (driver_path, header_path):
        if not required.is_file():
            raise SystemExit(f"Missing expected zram watermark integration file: {required}")

    oplus_header = """/* OPLUS_LZ4KD_ZRAM_CGROUP_LIMIT */
#ifndef _LINUX_OPLUS_ZRAM_WATERMARK_H
#define _LINUX_OPLUS_ZRAM_WATERMARK_H

#include <linux/types.h>

#ifdef CONFIG_OPLUS_LZ4KD_ZRAM_OPT
int oplus_zram_set_used_limit_mb(s64 limit_mb);
u64 oplus_zram_get_used_limit_mb(void);
#endif

#endif /* _LINUX_OPLUS_ZRAM_WATERMARK_H */
"""
    if oplus_header_path.exists():
        if "OPLUS_LZ4KD_ZRAM_CGROUP_LIMIT" not in oplus_header_path.read_text(
            encoding="utf-8"
        ):
            raise ValueError(f"Conflicting header already exists: {oplus_header_path}")
    else:
        oplus_header_path.write_text(oplus_header, encoding="utf-8")

    driver = driver_path.read_text(encoding="utf-8")
    header = header_path.read_text(encoding="utf-8")
    marker = "OPLUS_LZ4KD_OEM_ZRAM_WATERMARK"
    prototype = "bool oplus_zram_free_watermark_ok(void);"
    if marker in driver:
        if prototype not in header or "bool oplus_zram_free_watermark_ok(void)" not in driver:
            raise ValueError("Found an incomplete Oplus zram watermark integration")
        if "oplus_zram_used_limit_pages" not in driver:
            raise ValueError("Found an outdated Oplus zram watermark integration")
        integrate_kernel_zram_cgroup(kernel_root)
        return
    if "oplus_zram_free_watermark_ok" in driver or prototype in header:
        raise ValueError("Found a partial or conflicting Oplus zram watermark integration")

    include_anchor = "#include <linux/part_stat.h>\n"
    if include_anchor not in driver:
        raise ValueError("Could not locate zram_drv.c include anchor for RCU support")
    for include in (
        "#include <linux/compiler.h>\n",
        "#include <linux/errno.h>\n",
        "#include <linux/rcupdate.h>\n",
        "#include <linux/oplus_zram_watermark.h>\n",
    ):
        if include.rstrip() not in driver:
            driver = driver.replace(include_anchor, include_anchor + include, 1)

    mutex_anchor = "static DEFINE_MUTEX(zram_index_mutex);\n"
    if driver.count(mutex_anchor) != 1:
        raise ValueError("Could not uniquely locate zram device index lock")
    watermark_impl = """\n#if defined(CONFIG_OPLUS_LZ4KD_ZRAM_OPT)
/* OPLUS_LZ4KD_OEM_ZRAM_WATERMARK
 * Match the OEM free_zram_is_ok() decision.  These generic GKI targets do
 * not implement Oplus zram expansion, so its increase_nr_pages adjustment
 * is zero.  zram0 is the device used by the supported phone configurations.
 */
static struct zram __rcu *oplus_zram_watermark_device;
static unsigned long oplus_zram_used_limit_pages;

int oplus_zram_set_used_limit_mb(s64 limit_mb)
{
\tif (limit_mb < 0 || (u64)limit_mb > (~0ULL >> 20))
\t\treturn -EINVAL;

\tWRITE_ONCE(oplus_zram_used_limit_pages,
\t\t   ((u64)limit_mb << 20) >> PAGE_SHIFT);
\treturn 0;
}

u64 oplus_zram_get_used_limit_mb(void)
{
\treturn ((u64)READ_ONCE(oplus_zram_used_limit_pages) << PAGE_SHIFT) >> 20;
}

bool oplus_zram_free_watermark_ok(void)
{
\tstruct zram *zram;
\tunsigned long nr_used = 0, nr_tot = 1, nr_rsv, same_pages = 0;
\tunsigned long nr_increase = 0;
\tunsigned long used_limit_pages =
\t\tREAD_ONCE(oplus_zram_used_limit_pages);

\trcu_read_lock();
\tzram = rcu_dereference(oplus_zram_watermark_device);
\tif (zram) {
\t\tnr_tot = READ_ONCE(zram->disksize) >> PAGE_SHIFT;
\t\tnr_used = (u64)atomic64_read(&zram->stats.pages_stored);
\t\tsame_pages = (u64)atomic64_read(&zram->stats.same_pages);
\t}
\trcu_read_unlock();

\tif (used_limit_pages)
\t\tnr_tot = used_limit_pages;
\tnr_tot = nr_tot ?: 1;
\tnr_rsv = nr_tot >> 6;

\tif (used_limit_pages)
\t\treturn nr_used < (nr_tot - nr_rsv);

\tif (nr_used - same_pages > nr_tot - nr_rsv - nr_increase / 2)
\t\treturn false;

\treturn nr_used < (nr_tot - nr_rsv);
}
#endif
"""
    driver = driver.replace(mutex_anchor, mutex_anchor + watermark_impl, 1)

    add_return = re.compile(r"(?m)^([ \t]*)return device_id;[ \t]*$")
    if len(add_return.findall(driver)) != 1:
        raise ValueError("Could not uniquely locate successful zram device creation")

    def publish_primary_device(match: re.Match[str]) -> str:
        indent = match.group(1)
        return (
            f"{indent}if (device_id == 0)\n"
            f"{indent}\trcu_assign_pointer(oplus_zram_watermark_device, zram);\n"
            f"{indent}return device_id;"
        )

    driver, replaced_add = add_return.subn(publish_primary_device, driver, count=1)
    if replaced_add != 1:
        raise ValueError("Could not publish the primary zram device for watermark checks")

    remove_anchor = re.compile(
        r"(?m)^([ \t]*)zram_reset_device\(zram\);\r?\n(?:\r?\n)?([ \t]*)put_disk\(zram->disk\);"
    )
    if len(remove_anchor.findall(driver)) != 1:
        raise ValueError("Could not uniquely locate zram device removal cleanup")

    def clear_primary_device(match: re.Match[str]) -> str:
        reset_indent, put_indent = match.groups()
        return (
            f"{reset_indent}zram_reset_device(zram);\n\n"
            f"{reset_indent}if (zram->disk->first_minor == 0) {{\n"
            f"{reset_indent}\trcu_assign_pointer(oplus_zram_watermark_device, NULL);\n"
            f"{reset_indent}\tsynchronize_rcu();\n"
            f"{reset_indent}}}\n\n"
            f"{put_indent}put_disk(zram->disk);"
        )

    driver, replaced_remove = remove_anchor.subn(
        clear_primary_device, driver, count=1
    )
    if replaced_remove != 1:
        raise ValueError("Could not safely clear the primary zram watermark device")

    final_endif = header.rfind("#endif")
    if final_endif < 0:
        raise ValueError("Could not locate zram_drv.h include-guard terminator")
    header = (
        header[:final_endif]
        + "#ifdef CONFIG_OPLUS_LZ4KD_ZRAM_OPT\n"
        + prototype
        + "\n#endif\n\n"
        + header[final_endif:]
    )

    driver_path.write_text(driver, encoding="utf-8")
    header_path.write_text(header, encoding="utf-8")
    integrate_kernel_zram_cgroup(kernel_root)


def integrate_kernel_zram_cgroup(kernel_root: Path) -> None:
    """Expose the OEM zram_used_limit_mb setting through memory cgroups."""
    marker = "OPLUS_LZ4KD_ZRAM_CGROUP_LIMIT"
    integrations = (
        (
            kernel_root / "mm/memcontrol.c",
            "static struct cftype memory_files[] = {",
        ),
        (
            kernel_root / "mm/memcontrol-v1.c",
            "struct cftype mem_cgroup_legacy_files[] = {",
        ),
    )
    header_include = "#include <linux/oplus_zram_watermark.h>\n"
    callback_block = """#ifdef CONFIG_OPLUS_LZ4KD_ZRAM_OPT
/* OPLUS_LZ4KD_ZRAM_CGROUP_LIMIT: same root cgroup control as Oplus hybridswapd. */
static int oplus_zram_used_limit_mb_write(struct cgroup_subsys_state *css,
\t\t\t\t\t  struct cftype *cft, s64 val)
{
\treturn oplus_zram_set_used_limit_mb(val);
}

static u64 oplus_zram_used_limit_mb_read(struct cgroup_subsys_state *css,
\t\t\t\t\t struct cftype *cft)
{
\treturn oplus_zram_get_used_limit_mb();
}
#endif

"""
    cftype_block = """#ifdef CONFIG_OPLUS_LZ4KD_ZRAM_OPT
\t{
\t\t.name = "zram_used_limit_mb",
\t\t.flags = CFTYPE_ONLY_ON_ROOT,
\t\t.write_s64 = oplus_zram_used_limit_mb_write,
\t\t.read_u64 = oplus_zram_used_limit_mb_read,
\t},
#endif
"""

    modified: list[tuple[Path, str]] = []
    for source_path, array_anchor in integrations:
        if not source_path.is_file():
            raise SystemExit(f"Missing expected memory cgroup integration file: {source_path}")

        source = source_path.read_text(encoding="utf-8")
        if marker in source:
            if '"zram_used_limit_mb"' not in source:
                raise ValueError(f"Found incomplete zram cgroup integration in {source_path}")
            modified.append((source_path, source))
            continue
        if '"zram_used_limit_mb"' in source:
            raise ValueError(f"Conflicting zram_used_limit_mb cgroup file in {source_path}")

        include_anchor = "#include <linux/memcontrol.h>\n"
        if include_anchor not in source:
            raise ValueError(f"Could not locate memory cgroup include anchor in {source_path}")
        if header_include.rstrip() not in source:
            source = source.replace(include_anchor, include_anchor + header_include, 1)

        if source.count(array_anchor) != 1:
            raise ValueError(f"Could not uniquely locate cgroup file array in {source_path}")
        source = source.replace(array_anchor, callback_block + array_anchor, 1)

        array_start = source.index(array_anchor)
        array_end = source.find("};", array_start)
        if array_end < 0:
            raise ValueError(f"Could not locate cgroup file array terminator in {source_path}")
        array_body = source[array_start:array_end]
        terminator = re.compile(
            r"(?m)^[ \t]*\{[ \t]*\}[ \t]*,?[ \t]*(?:/\*[^\n]*\*/)?[ \t]*$"
        )
        matches = list(terminator.finditer(array_body))
        if len(matches) != 1:
            raise ValueError(f"Could not uniquely locate cgroup file sentinel in {source_path}")
        sentinel = matches[0]
        insert_at = array_start + sentinel.start()
        source = source[:insert_at] + cftype_block + source[insert_at:]
        modified.append((source_path, source))

    for source_path, source in modified:
        source_path.write_text(source, encoding="utf-8")


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

    integrate_kernel_zram_watermark(kernel_root)

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
