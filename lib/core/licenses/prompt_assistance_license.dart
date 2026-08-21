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
DominikDoom/a1111-sd-webui-tagcomplete project:
https://github.com/DominikDoom/a1111-sd-webui-tagcomplete

Source file: tags/danbooru.csv
Revision: 4170882f90b47be130a0ff9314f663c230b9153d
Source SHA-256: f936684fa0b041e9a55d35f2052588e28d95eef8672be6829241f8b1a7214732
Source rows: 140782

Copyright (c) 2023 DominikDoom

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
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
