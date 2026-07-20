import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/settings.dart';

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  test('sequential progress memory defaults to disabled', () {
    expect(Settings.fromJson({}).rememberSequentialProgress, isFalse);
  });

  test('sequential progress memory is persisted in settings JSON', () {
    final settings = Settings.fromJson({
      'remember_sequential_progress': false,
    });

    expect(settings.rememberSequentialProgress, isFalse);
    expect(settings.toJson()['remember_sequential_progress'], isFalse);
  });

  test('an explicitly enabled sequential progress setting is preserved', () {
    final settings = Settings.fromJson({
      'remember_sequential_progress': true,
    });

    expect(settings.rememberSequentialProgress, isTrue);
    expect(settings.toJson()['remember_sequential_progress'], isTrue);
  });

  test('Chinese UI consistently labels sequential selection as polling',
      () async {
    final source = await rootBundle.loadString('assets/l10n/zh-CN.json');
    final translations = jsonDecode(source) as Map<String, dynamic>;

    expect(
      translations['selection_method_single_sequential'],
      '单个 - 顺序遍历（轮询）',
    );
    expect(
      translations['remember_sequential_progress'],
      '记住顺序遍历（轮询）进度',
    );
    expect(
      translations.values.whereType<String>().any(
            (value) => RegExp(r'顺序遍历(?!（轮询）)').hasMatch(value),
          ),
      isFalse,
    );
  });

  test('negative prompt section title is English in both languages', () async {
    final chinese = jsonDecode(
      await rootBundle.loadString('assets/l10n/zh-CN.json'),
    ) as Map<String, dynamic>;
    final english = jsonDecode(
      await rootBundle.loadString('assets/l10n/en.json'),
    ) as Map<String, dynamic>;

    expect(chinese['negative_prompts'], 'Negative Prompt');
    expect(english['negative_prompts'], 'Negative Prompt');
    expect(chinese['uc'], '负面内容');
    expect(
      chinese['restore_initial_settings_warning'],
      contains('负面内容'),
    );
    expect(
      chinese.values.whereType<String>().any(
            (value) => value.contains('反向提示词'),
          ),
      isFalse,
    );
  });

  test('legacy batch settings migrate to per-image generation settings', () {
    final settings = Settings.fromJson({
      'batch_count': 4,
      'batch_interval': 12,
      'number_of_requests': 20,
    });

    expect(settings.generationIntervalSec, 12);
    expect(settings.generationCount, 20);

    final json = settings.toJson();
    expect(json['generation_interval'], 12);
    expect(json['generation_count'], 20);
    expect(json.containsKey('batch_count'), isFalse);
    expect(json.containsKey('batch_interval'), isFalse);
    expect(json.containsKey('number_of_requests'), isFalse);
  });

  test('new generation settings take precedence over legacy values', () {
    final settings = Settings.fromJson({
      'generation_interval': 3,
      'generation_count': 5,
      'batch_interval': 12,
      'number_of_requests': 20,
    });

    expect(settings.generationIntervalSec, 3);
    expect(settings.generationCount, 5);
  });
}
