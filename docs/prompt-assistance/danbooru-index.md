# Bundled Danbooru completion index

CasRand Forge bundles a derived, compressed copy of the Danbooru tag list for
offline prompt completion.  The application never sends the text being edited
to Danbooru or another completion service.

## Pinned source

- Project: [`DominikDoom/a1111-sd-webui-tagcomplete`](https://github.com/DominikDoom/a1111-sd-webui-tagcomplete)
- File: [`tags/danbooru.csv`](https://github.com/DominikDoom/a1111-sd-webui-tagcomplete/blob/4170882f90b47be130a0ff9314f663c230b9153d/tags/danbooru.csv)
- Revision: `4170882f90b47be130a0ff9314f663c230b9153d`
- Source SHA-256: `f936684fa0b041e9a55d35f2052588e28d95eef8672be6829241f8b1a7214732`
- Source rows: `140782`
- Derived asset: `assets/prompt_assistance/danbooru-index.json.gz`
- Derived asset SHA-256 (at this revision): `ba4ce991bcbde3f7acc35f68d569bd067d6cea66cb7a39506c778a140d171614`

Each derived row is `[canonical_tag, category, post_count, aliases]`.

At runtime the application builds sorted canonical/alias prefix tables and a
two-character substring bucket index while decoding the asset in Flutter's
worker isolate. Queries use binary prefix lookup and the rarest substring
bucket, then retain only the deterministic top 12 candidates. This keeps
repeated broad queries bounded without sending prompt text or requiring a
network service.

## Reproducible import

With the pinned CSV saved as `/private/tmp/casrand-danbooru.csv`, run:

```sh
python3 tool/generate_danbooru_index.py \
  --input /private/tmp/casrand-danbooru.csv \
  --output assets/prompt_assistance/danbooru-index.json.gz
```

The script checks the source checksum and row count, emits compact UTF-8 JSON,
and writes gzip with a zero timestamp and no filename header so the output is
reproducible.

## Attribution and license

The upstream `a1111-sd-webui-tagcomplete` project is distributed under the MIT
license.  Its copyright notice is reproduced here for the redistributed data
derivative:

> Copyright (c) 2023 DominikDoom
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

CasRand Forge remains GPL-3.0; this attribution applies to the bundled derived
data only.
