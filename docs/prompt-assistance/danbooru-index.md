# Bundled Danbooru completion index

CasRand Forge bundles a derived, compressed copy of the Danbooru tag list for
offline prompt completion.  The application never sends the text being edited
to Danbooru or another completion service.

## Pinned source

- Project: [`DraconicDragon/dbr-e621-lists-archive`](https://github.com/DraconicDragon/dbr-e621-lists-archive)
- File: [`tag-lists/danbooru/danbooru_2026-10-01_pt20-ia-dd.csv`](https://github.com/DraconicDragon/dbr-e621-lists-archive/blob/0d3b4e4d7e9890329a884afee4fada2b76f794eb/tag-lists/danbooru/danbooru_2026-10-01_pt20-ia-dd.csv)
  (Danbooru tags with at least 20 posts, active and deleted aliases)
- Revision: `0d3b4e4d7e9890329a884afee4fada2b76f794eb` (monthly list of 2026-10-01)
- Source SHA-256: `45afb2554525464ee49112512f6367ee004bd351afcef5f2435e99d6286884e3`
- Source rows: `220510`
- Deprecated-tag aliases: [`tool/danbooru_deprecated_aliases.json`](../../tool/danbooru_deprecated_aliases.json)
  (327 tags, 1336 aliases added)
- Derived asset: `assets/prompt_assistance/danbooru-index.json.gz`
- Derived asset SHA-256 (at this revision): `5674d0c42c435f43f018e1bc3c464ad1c1c78ad7ebe5e8d2ef76ff535b72c259`

Each derived row is `[canonical_tag, category, post_count, aliases]`.

At runtime the application builds sorted canonical/alias prefix tables and a
two-character substring bucket index while decoding the asset in Flutter's
worker isolate. Queries use binary prefix lookup and the rarest substring
bucket, then retain only the deterministic top 12 candidates. This keeps
repeated broad queries bounded without sending prompt text or requiring a
network service.

## Deprecated tags

Danbooru deprecates some broad tags in favour of more specific ones (for
example `black_footwear` → `black_shoes`, `black_boots`, …), and the source
list drops them.  So that typing an old name still offers its replacements,
`tool/danbooru_deprecated_aliases.json` maps each such tag to its
replacements, and the generator appends the old tag to the aliases of every
replacement.

The map was built on 2026-10-29 from the tags of the previous source
(DominikDoom/a1111-sd-webui-tagcomplete `tags/danbooru.csv` at
`4170882f90b47be130a0ff9314f663c230b9153d`) that are neither a tag nor an
alias in the new list.  Of those, the tags Danbooru's API reports as
deprecated were kept, mapped to the tags linked from the introduction of
their Danbooru wiki page (resolved through the new list's aliases), and
limited to replacements in the same category.  The file holds only tag
names, so regenerating the index needs no network access.

## Reproducible import

With the pinned CSV saved as `/private/tmp/casrand-danbooru.csv`, run:

```sh
python3 tool/generate_danbooru_index.py \
  --input /private/tmp/casrand-danbooru.csv \
  --output assets/prompt_assistance/danbooru-index.json.gz
```

The script checks the source checksum and row count, refuses a deprecated
tag that the source already contains or a replacement it lacks, emits compact
UTF-8 JSON, and writes gzip with a zero timestamp and no filename header so
the output is reproducible.

## Attribution and license

The `dbr-e621-lists-archive` project is released into the public domain
under the [Unlicense](https://unlicense.org), which places no conditions on
redistribution.  The bundled notice credits the source anyway:

> This is free and unencumbered software released into the public domain.
>
> Anyone is free to copy, modify, publish, use, compile, sell, or
> distribute this software, either in source code form or as a compiled
> binary, for any purpose, commercial or non-commercial, and by any
> means.
>
> In jurisdictions that recognize copyright laws, the author or authors
> of this software dedicate any and all copyright interest in the
> software to the public domain. We make this dedication for the benefit
> of the public at large and to the detriment of our heirs and
> successors. We intend this dedication to be an overt act of
> relinquishment in perpetuity of all present and future rights to this
> software under copyright law.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
> EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
> MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
> IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
> OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
> ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
> OTHER DEALINGS IN THE SOFTWARE.
>
> For more information, please refer to <https://unlicense.org>

CasRand Forge remains GPL-3.0; this notice applies to the bundled derived
data only.
