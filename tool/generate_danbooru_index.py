#!/usr/bin/env python3
"""Build CasRand's deterministic, compressed Danbooru completion index.

The input is ``tag-lists/danbooru/danbooru_2026-10-01_pt20-ia-dd.csv`` from
DraconicDragon/dbr-e621-lists-archive (the tagcomplete CSV format).  Danbooru
tags that were deprecated and therefore dropped from that list are added back
as aliases of their replacement tags, from ``danbooru_deprecated_aliases.json``
next to this script.  The output is a compact JSON array, compressed with gzip
using a stable timestamp and no filename header:
[tag, category, post_count, aliases].
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
from pathlib import Path

EXPECTED_SOURCE_SHA256 = "45afb2554525464ee49112512f6367ee004bd351afcef5f2435e99d6286884e3"
EXPECTED_ROW_COUNT = 220_510
DEFAULT_DEPRECATED_ALIASES = Path(__file__).with_name(
    "danbooru_deprecated_aliases.json"
)


def build(
    input_path: Path, output_path: Path, deprecated_path: Path
) -> tuple[str, int, int]:
    source_hash = hashlib.sha256(input_path.read_bytes()).hexdigest()
    if source_hash != EXPECTED_SOURCE_SHA256:
        raise SystemExit(
            f"unexpected source sha256: {source_hash}; "
            f"expected {EXPECTED_SOURCE_SHA256}"
        )

    rows: list[list[object]] = []
    with input_path.open("r", encoding="utf-8", newline="") as source:
        for row in csv.reader(source):
            if len(row) != 4:
                raise SystemExit(f"unexpected row shape: {row!r}")
            tag, category, count, aliases = row
            rows.append(
                [
                    tag,
                    int(category),
                    int(count),
                    [alias for alias in aliases.split(",") if alias],
                ]
            )

    if len(rows) != EXPECTED_ROW_COUNT:
        raise SystemExit(
            f"unexpected row count: {len(rows)}; expected {EXPECTED_ROW_COUNT}"
        )

    # Each deprecated tag is appended, in file order, to the aliases of every
    # replacement tag, so typing an old name still offers its replacements.
    by_tag = {row[0]: row for row in rows}
    source_aliases = {alias for row in rows for alias in row[3]}
    deprecated = json.loads(deprecated_path.read_text(encoding="utf-8"))
    added = 0
    for old_tag, targets in deprecated.items():
        if old_tag in by_tag or old_tag in source_aliases:
            raise SystemExit(f"deprecated tag is already in the source: {old_tag}")
        for target in targets:
            if target not in by_tag:
                raise SystemExit(f"unknown replacement for {old_tag}: {target}")
            aliases = by_tag[target][3]
            if old_tag not in aliases:
                aliases.append(old_tag)
                added += 1

    output_path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(
        rows,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    # ``mtime=0`` and an empty filename keep the derived asset reproducible.
    with output_path.open("wb") as raw:
        with gzip.GzipFile(
            filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0
        ) as compressed:
            compressed.write(payload)
    return source_hash, len(rows), added


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--deprecated-aliases", type=Path, default=DEFAULT_DEPRECATED_ALIASES
    )
    args = parser.parse_args()
    source_hash, row_count, added = build(
        args.input, args.output, args.deprecated_aliases
    )
    print(f"source_sha256={source_hash}")
    print(f"row_count={row_count}")
    print(f"deprecated_aliases_added={added}")
    print(f"output={args.output}")


if __name__ == "__main__":
    main()
