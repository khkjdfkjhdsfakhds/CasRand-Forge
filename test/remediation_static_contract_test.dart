import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('English and Chinese localization resources expose identical keys', () {
    final english = jsonDecode(File('assets/l10n/en.json').readAsStringSync())
        as Map<String, dynamic>;
    final chinese =
        jsonDecode(File('assets/l10n/zh-CN.json').readAsStringSync())
            as Map<String, dynamic>;

    expect(english.keys.toSet().difference(chinese.keys.toSet()), isEmpty);
    expect(chinese.keys.toSet().difference(english.keys.toSet()), isEmpty);
  });

  test('reviewed interface labels and Vibe feedback use localization keys', () {
    final sources = [
      'lib/ui/settings_page/widgets/settings_page_view.dart',
      'lib/ui/parameters_config/widgets/parameters_conifg_view.dart',
      'lib/ui/prompt_tab/widgets/prompt_tab_view.dart',
      'lib/ui/vibe_config/widgets/vibe_config_view.dart',
      'lib/ui/vibe_config_v4/viewmodels/vibe_config_v4_list_viewmodel.dart',
    ].map((path) => File(path).readAsStringSync()).join('\n');

    for (final literal in [
      "Text('Language')",
      "Text('Select language...')",
      "Text('Legacy Prompt Conditioning Mode')",
      "'Character \${index + 1}'",
      "'Could not add Vibe reference: \$error'",
      "Text('Strength')",
      "Text('Information Extracted')",
      "tooltip: 'Edit'",
      "tooltip: 'Delete'",
    ]) {
      expect(sources, isNot(contains(literal)), reason: literal);
    }
  });

  test('production networking never accepts an invalid TLS certificate', () {
    final apiService =
        File('lib/data/services/api_service.dart').readAsStringSync();

    expect(apiService, isNot(contains('badCertificateCallback')));
  });

  test('release metadata agrees on build 126', () {
    expect(File('pubspec.yaml').readAsStringSync(),
        contains('version: 0.9.10+126'));
    expect(
        File('.github/workflows/macos.yml').readAsStringSync(),
        contains(
            "CFBundleVersion' \"\$APP_PATH/Contents/Info.plist\")\" = \"126\""));
    expect(File('.github/workflows/android.yml').readAsStringSync(),
        contains("versionCode='126' versionName='0.9.10'"));
    expect(File('.github/workflows/windows.yml').readAsStringSync(),
        contains('0.9.10+126'));
  });

  test('Web workflow targets forge-main and deploys complete decoded output',
      () {
    final workflow = File('.github/workflows/web.yml').readAsStringSync();

    expect(workflow, contains('branches: [ "forge-main" ]'));
    expect(
      workflow,
      contains('printf \'%s\' "\${{ secrets.SECRETS_JSON_CONTENT }}" | '
          'base64 --decode > secrets.json'),
    );
    expect(workflow, contains('git add --all'));
    expect(workflow, contains('git diff --cached --quiet || git commit'));
  });
}
