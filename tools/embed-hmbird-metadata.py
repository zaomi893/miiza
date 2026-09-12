#!/usr/bin/env python3
"""Embed HMBIRD split-BTF metadata into the fixed slots of a GKI Image."""

from __future__ import annotations

import argparse
from pathlib import Path


BTF_MARKER = b"HMBIRD_BTF_SLOT"
IDS_MARKER = b"HMBIRD_IDS_SLOT"
BTF_SIZE_MARKER = b"HMBIRD_LEN_SLOT"
IDS_SIZE_MARKER = b"HMBIRD_IDS_LEN"
BTF_CAPACITY = 32768
IDS_CAPACITY = 512


def replace_slot(image: bytearray, marker: bytes, payload: bytes, capacity: int) -> int:
    if not payload or len(payload) > capacity:
        raise SystemExit(f"invalid payload size for {marker!r}: {len(payload)}")

    matches: list[int] = []
    start = 0
    while True:
        offset = image.find(marker, start)
        if offset < 0:
            break
        if len(image) - offset >= capacity and not any(
            image[offset + len(marker) : offset + capacity]
        ):
            matches.append(offset)
        start = offset + 1

    if len(matches) != 1:
        raise SystemExit(f"slot resolution failed for {marker!r}: {matches}")

    offset = matches[0]
    image[offset : offset + capacity] = payload + bytes(capacity - len(payload))
    return offset


def replace_size_marker(image: bytearray, marker: bytes, size: int, tag: bytes) -> None:
    if len(tag) + 4 != len(marker):
        raise SystemExit(f"invalid size marker tag for {marker!r}")
    offset = image.find(marker)
    if offset < 0 or image.find(marker, offset + 1) >= 0:
        raise SystemExit(f"size marker is missing or ambiguous: {marker!r}")
    image[offset : offset + len(marker)] = size.to_bytes(4, "little") + tag


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("btf", type=Path)
    parser.add_argument("btf_ids", type=Path)
    args = parser.parse_args()

    image = bytearray(args.image.read_bytes())
    btf = args.btf.read_bytes()
    btf_ids = args.btf_ids.read_bytes()

    if len(btf_ids) < 8 or len(btf_ids) > IDS_CAPACITY:
        raise SystemExit(f"invalid .BTF_ids size: {len(btf_ids)}")
    if (len(btf_ids) - 8) % 8:
        raise SystemExit(f"invalid .BTF_ids structure size: {len(btf_ids)}")
    declared_count = int.from_bytes(btf_ids[:4], "little")
    expected_count = (len(btf_ids) - 8) // 8
    if declared_count != expected_count:
        raise SystemExit(
            f"invalid .BTF_ids count: header={declared_count}, size={expected_count}"
        )

    btf_offset = replace_slot(image, BTF_MARKER, btf, BTF_CAPACITY)
    ids_offset = replace_slot(image, IDS_MARKER, btf_ids, IDS_CAPACITY)
    replace_size_marker(image, BTF_SIZE_MARKER, len(btf), b"BTFSIZEV001")
    replace_size_marker(image, IDS_SIZE_MARKER, len(btf_ids), b"IDSSIZEV01")
    args.image.write_bytes(image)

    verify = args.image.read_bytes()
    if verify[btf_offset : btf_offset + len(btf)] != btf:
        raise SystemExit("BTF payload readback failed")
    if verify[ids_offset : ids_offset + len(btf_ids)] != btf_ids:
        raise SystemExit("BTF IDs payload readback failed")

    print(
        f"embedded HMBIRD metadata: BTF={len(btf)} bytes, "
        f"BTF_ids={len(btf_ids)} bytes, IDs={declared_count}"
    )


if __name__ == "__main__":
    main()
