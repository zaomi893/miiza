#!/usr/bin/env python3
"""Fail a workflow before compiling if its device/platform sources are mixed."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import urllib.parse
import urllib.request
from pathlib import Path


DEVICES = {
    "ace6t": {
        "platform": "qcom", "soc": "sm8845", "version": "6.12.38",
        "kernel_repo": "android_kernel_common_oneplus_sm8845",
        "kernel_branch": "oneplus/sm8845_b_16.0.0_ace_6t",
        "module_repo": "OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8845",
        "module_branch": "oneplus/sm8845_b_16.0.0_ace_6t",
        "makefile": "hmbird_module/Makefile.qcom",
    },
    "pad3pro": {
        "platform": "qcom", "soc": "sm8850", "version": "6.12.58",
        "kernel_repo": "android_kernel_common_oneplus_sm8850",
        "kernel_branch": "oneplus/sm8850_b_16.0_pad_3_pro",
        "module_repo": "OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850",
        "module_branch": "oneplus/sm8850_b_16.0_pad_3_pro",
        "makefile": "hmbird_module/Makefile.qcom",
    },
    "ace6ultra": {
        "platform": "mtk", "soc": "mt6993", "version": "6.12.58",
        "kernel_repo": "android_kernel_oneplus_mt6993",
        "kernel_branch": "oneplus/mt6993_b_16.0_ace_6_ultra",
        "module_repo": "OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_mt6993",
        "module_branch": "oneplus/mt6993_b_16.0_ace_6_ultra",
        "makefile": "hmbird_module/Makefile.mtk",
    },
    "findx9": {
        "platform": "mtk", "soc": "mt6993", "version": "6.12.23",
        "kernel_repo": "android_kernel_oppo_mt6993",
        "kernel_branch": "oppo/mt6993_b_16.0.0_find_x9",
        "module_repo": "oppo-source/android_kernel_modules_and_devicetree_oppo_mt6993",
        "module_branch": "oppo/mt6993_b_16.0.0_find_x9",
        "makefile": "hmbird_module/Makefile.mtk",
    },
}


def api(path: str) -> dict:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "miiza-source-check"}
    token = os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(f"https://api.github.com{path}", headers=headers), timeout=30) as response:
        return json.load(response)


def kernel_version(makefile: str) -> str:
    values = {}
    for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
        match = re.search(rf"^{key}\s*=\s*(\d+)\s*$", makefile, re.MULTILINE)
        if not match:
            raise SystemExit(f"kernel Makefile lacks {key}")
        values[key] = match.group(1)
    return ".".join(values[key] for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True, choices=DEVICES)
    args = parser.parse_args()
    expected = dict(DEVICES[args.device])
    migrated_owner = os.environ.get("MIGRATED_REPO_OWNER", "").strip()
    if not migrated_owner:
        raise SystemExit("MIGRATED_REPO_OWNER is required")
    expected["kernel_repo"] = f'{migrated_owner}/{expected["kernel_repo"]}'
    # OPPO has not published the PLG110 16.0.10.501 MT6993 module tree. Its
    # stock sched_ext module has the same CAD3... source version and 39-kfunc
    # layout as this official Ace6T sync point; compile those sources with the
    # Find X9 MTK Makefile to generate metadata only (never replacement code).
    if args.device == "findx9" and os.environ.get("HMBIRD_TRACK") == "gold":
        expected["module_repo"] = (
            "OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8845"
        )
        expected["module_branch"] = "oneplus/sm8845_b_16.0.0_ace_6t"
    actual = {
        "platform": os.environ["SOC_PLATFORM"],
        "soc": os.environ["SOC_ID"],
        "version": f'{os.environ["KERNEL_VERSION"]}.{re.match(r"\d+", os.environ["SUB_VERSION"]).group()}',
        "kernel_repo": os.environ["KERNEL_SOURCE_REPO"],
        "kernel_branch": os.environ["KERNEL_SOURCE_BRANCH"],
        "module_repo": os.environ["HMBIRD_SOURCE_REPO"],
        "module_branch": os.environ["HMBIRD_SOURCE_BRANCH"],
        "makefile": os.environ["HMBIRD_MAKEFILE"],
    }
    errors = [f"{key}: expected {value}, got {actual[key]}" for key, value in expected.items() if actual[key] != value]
    if errors:
        raise SystemExit("device/platform source mismatch:\n" + "\n".join(errors))

    module_makefile = Path(expected["makefile"]).read_text()
    wanted = "CONFIG_OPLUS_SYSTEM_KERNEL_QCOM" if expected["platform"] == "qcom" else "CONFIG_OPLUS_SYSTEM_KERNEL_MTK"
    forbidden = "CONFIG_OPLUS_SYSTEM_KERNEL_MTK" if expected["platform"] == "qcom" else "CONFIG_OPLUS_SYSTEM_KERNEL_QCOM"
    if wanted not in module_makefile or forbidden in module_makefile:
        raise SystemExit(f"{expected['makefile']} does not exclusively select {expected['platform']}")

    branch = urllib.parse.quote(expected["kernel_branch"], safe="")
    ref = api(f"/repos/{expected['kernel_repo']}/git/ref/heads/{branch}")
    head = ref["object"]["sha"]
    pinned = os.environ["KERNEL_SOURCE_COMMIT"]
    if head != pinned:
        raise SystemExit(f"migrated kernel branch moved: expected {pinned}, current {head}")
    content = api(f"/repos/{expected['kernel_repo']}/contents/Makefile?ref={urllib.parse.quote(pinned, safe='')}")
    version = kernel_version(base64.b64decode(content["content"]).decode())
    if version != expected["version"]:
        raise SystemExit(f"kernel version mismatch: expected {expected['version']}, got {version}")
    print(f"verified {args.device}: {expected['soc']} {expected['platform']} Linux {version} @ {head}")


if __name__ == "__main__":
    main()
