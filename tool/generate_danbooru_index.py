#!/usr/bin/env python3
"""Build CasRand's deterministic, compressed Danbooru completion index.

The input is the ``tags/danbooru.csv`` file from
DominikDoom/a1111-sd-webui-tagcomplete.  The output is a compact JSON array,
compressed with gzip using a stable timestamp and no filename header:
[tag, category, post_count, aliases].
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
from pathlib import Path

EXPECTED_SOURCE_SHA256 = "f936684fa0b041e9a55d35f2052588e28d95eef8672be6829241f8b1a7214732"
EXPECTED_ROW_COUNT = 140_782


def build(input_path: Path, output_path: Path) -> tuple[str, int]:
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
    return source_hash, len(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source_hash, row_count = build(args.input, args.output)
    print(f"source_sha256={source_hash}")
    print(f"row_count={row_count}")
    print(f"output={args.output}")


if __name__ == "__main__":
    main()
