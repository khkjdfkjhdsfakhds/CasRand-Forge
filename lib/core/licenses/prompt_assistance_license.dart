import 'package:flutter/foundation.dart';

/// Package label used by Flutter's About > View licenses page.
const promptAssistanceLicensePackage =
    'CasRand Forge — Danbooru completion index';

/// Attribution and license text for the bundled derived Danbooru index.
///
/// This is intentionally registered with [LicenseRegistry] rather than only
/// kept in repository documentation, so the notice is present in every
/// packaged build and is reachable from the existing About dialog.
const promptAssistanceLicenseText = '''
CasRand Forge includes a derived Danbooru completion index from the
DraconicDragon/dbr-e621-lists-archive project:
https://github.com/DraconicDragon/dbr-e621-lists-archive

Source file: tag-lists/danbooru/danbooru_2026-10-01_pt20-ia-dd.csv
Revision: 0d3b4e4d7e9890329a884afee4fada2b76f794eb
Source SHA-256: 45afb2554525464ee49112512f6367ee004bd351afcef5f2435e99d6286884e3
Source rows: 220510

Deprecated Danbooru tags that the source list no longer contains were added
as aliases of the replacement tags linked from their Danbooru wiki pages.

The source project is released into the public domain under the Unlicense:

This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.

In jurisdictions that recognize copyright laws, the author or authors
of this software dedicate any and all copyright interest in the
software to the public domain. We make this dedication for the benefit
of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of
relinquishment in perpetuity of all present and future rights to this
software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <https://unlicense.org>

The optional Chinese labels and pinyin lookup data were adapted from the
MIT-licensed Novelai Prompt Helper Enhanced project at:
https://github.com/cheerotter13-ai/novelai-prompt-helper-enhanced
They are bundled as convenience search metadata; the canonical tag inserted
into a prompt remains the Danbooru tag.
''';

/// Registers the bundled index notice for Flutter's About license page.
void registerPromptAssistanceLicense() {
  LicenseRegistry.addLicense(
    () async* {
      yield const LicenseEntryWithLineBreaks(
        <String>[promptAssistanceLicensePackage],
        promptAssistanceLicenseText,
      );
    },
  );
}
