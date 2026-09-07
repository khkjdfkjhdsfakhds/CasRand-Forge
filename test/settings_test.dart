import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/api_token_config.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/settings.dart';

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  test('sequential progress memory defaults to disabled', () {
    expect(Settings.fromJson({}).rememberSequentialProgress, isFalse);
  });

  test('desktop JPEG storage settings default to safe PNG-only values', () {
    final settings = Settings.fromJson({});

    expect(settings.jpegStorageEnabled, isFalse);
    expect(settings.retainOriginalPng, isFalse);
  });

  test('desktop JPEG storage settings survive a JSON round trip', () {
    final settings = Settings.fromJson({
      'jpeg_storage_enabled': true,
      'retain_original_png': true,
    });

    final restored = Settings.fromJson(settings.toJson());
    expect(restored.jpegStorageEnabled, isTrue);
    expect(restored.retainOriginalPng, isTrue);
  });

  test('metadata retention is the default and metadata settings round-trip',
      () {
    final settings = Settings.fromJson({});
    expect(settings.metadataEraseEnabled, isFalse);
    expect(settings.customMetadataEnabled, isFalse);

    settings
      ..metadataEraseEnabled = true
      ..customMetadataEnabled = true
      ..customMetadataContent = '{"Description":"custom"}';
    final restored = Settings.fromJson(settings.toJson());

    expect(restored.metadataEraseEnabled, isTrue);
    expect(restored.customMetadataEnabled, isTrue);
    expect(restored.customMetadataContent, '{"Description":"custom"}');
  });

  test('prompt autocomplete defaults to enabled and persists its switch', () {
    final settings = Settings.fromJson({});
    expect(settings.promptAutocompleteEnabled, isTrue);

    settings.promptAutocompleteEnabled = false;
    final restored = Settings.fromJson(settings.toJson());
    expect(restored.promptAutocompleteEnabled, isFalse);
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

  test('metadata settings labels describe erasure rather than watermarking',
      () async {
    final chinese = jsonDecode(
      await rootBundle.loadString('assets/l10n/zh-CN.json'),
    ) as Map<String, dynamic>;
    final english = jsonDecode(
      await rootBundle.loadString('assets/l10n/en.json'),
    ) as Map<String, dynamic>;

    expect(chinese['metadata_erase_enabled'], '清除生成图片中的元数据');
    expect(chinese['metadata_erase_enabled_hint'], contains('PNG'));
    expect(chinese['custom_metadata_enabled'], '添加伪造元数据信息');
    expect(english['metadata_erase_enabled_hint'], contains('omit'));
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

  test('generation interval defaults to 2 without replacing saved values', () {
    expect(Settings.fromJson({}).generationIntervalSec, 2);
    expect(
      Settings.fromJson({'generation_interval': 10}).generationIntervalSec,
      10,
    );
  });

  test('generation setting labels describe the recommendation and multi-select',
      () async {
    final chinese = jsonDecode(
      await rootBundle.loadString('assets/l10n/zh-CN.json'),
    ) as Map<String, dynamic>;
    final english = jsonDecode(
      await rootBundle.loadString('assets/l10n/en.json'),
    ) as Map<String, dynamic>;

    expect(chinese['generation_interval'], '生成间隔（秒，建议至少为2秒）');
    expect(chinese['generation_image_size'], '图像尺寸（可多选）');
    expect(chinese['image_size'], '图像尺寸（宽 × 高）');
    expect(
      english['generation_interval'],
      'Generation interval (seconds; at least 2 recommended)',
    );
    expect(
        english['generation_image_size'], 'Image size (multiple selections)');
  });

  test('api tokens and display mode survive a JSON round trip', () {
    final settings = Settings.fromJson({'api_key': 'pst-main'});
    settings.apiTokens.addAll([
      ApiTokenConfig(label: 'Alt', token: 'pst-alt', enabled: false),
    ]);
    settings.parallelApiEnabled = true;
    settings.resultDisplayMode = 'classic';

    final restored = Settings.fromJson(
      json.decode(json.encode(settings.toJson())) as Map<String, dynamic>,
    );

    expect(restored.apiTokens, hasLength(2));
    expect(restored.apiTokens[0].label, 'Main API');
    expect(restored.apiTokens[0].token, 'pst-main');
    expect(restored.apiTokens[0].enabled, isTrue);
    expect(restored.apiTokens[0].isPrimary, isTrue);
    expect(restored.apiTokens[1].enabled, isFalse);
    expect(restored.parallelApiEnabled, isTrue);
    expect(restored.resultDisplayMode, 'classic');
  });

  test('classic grid is the default for new and pre-migration configs', () {
    expect(Settings.fromJson({}).resultDisplayMode, 'classic');
    expect(
      Settings.fromJson({
        'result_display_mode': 'waterfall',
      }).resultDisplayMode,
      'classic',
    );
  });

  test('post-migration waterfall choice is preserved', () {
    final settings = Settings.fromJson({
      'classic_grid_default_migrated': true,
      'result_display_mode': 'waterfall',
    });

    expect(settings.resultDisplayMode, 'waterfall');
    expect(settings.toJson()['classic_grid_default_migrated'], isTrue);
  });

  test('legacy configs automatically expose the main api key', () {
    final settings = Settings.fromJson({'api_key': 'pst-legacy'});

    expect(settings.apiTokens, hasLength(1));
    expect(settings.apiTokens.single.isPrimary, isTrue);
    final effective = settings.effectiveApiTokens;
    expect(effective, hasLength(1));
    expect(effective.single.token, 'pst-legacy');
    expect(settings.resultDisplayMode, 'classic');
  });

  test('legacy page visibility seeds matching navigation entries', () {
    final settings = Settings.fromJson({
      'show_image_to_image_page': true,
      'show_vibe_reference_page': true,
      'show_enhance_page': true,
      'show_director_tools_page': true,
      'proxy': '127.0.0.1:8080',
      'generation_count': 7,
    });

    expect(settings.navigation.destinations, [
      AppDestination.generation,
      AppDestination.config,
      AppDestination.imageToImage,
      AppDestination.vibeReference,
      AppDestination.enhance,
      AppDestination.directorTools,
      AppDestination.settings,
    ]);
    expect(settings.proxy, '127.0.0.1:8080');
    expect(settings.generationCount, 7);
    final saved = settings.toJson();
    expect(saved.containsKey('show_image_to_image_page'), isFalse);
    expect(saved.containsKey('show_vibe_reference_page'), isFalse);
    expect(saved.containsKey('show_enhance_page'), isFalse);
    expect(saved.containsKey('show_director_tools_page'), isFalse);
  });

  test('effective tokens skip disabled and empty entries', () {
    final settings = Settings.fromJson({'api_key': 'pst-legacy'});
    settings.apiTokens.addAll([
      ApiTokenConfig(label: 'Off', token: 'pst-off', enabled: false),
      ApiTokenConfig(label: 'Empty', token: ''),
      ApiTokenConfig(label: 'On', token: 'pst-on'),
    ]);
    settings
      ..parallelApiEnabled = true
      ..normalizeApiTokens();

    final effective = settings.effectiveApiTokens;
    expect(effective.map((entry) => entry.token), ['pst-legacy', 'pst-on']);
    expect(settings.apiKey, 'pst-legacy');
  });

  test('old additional tokens enable parallel mode and keep the main token',
      () {
    final settings = Settings.fromJson({
      'api_key': 'pst-main',
      'api_tokens': [
        {'label': 'Alt', 'token': 'pst-alt', 'enabled': true},
      ],
    });

    expect(settings.parallelApiEnabled, isTrue);
    expect(settings.apiTokens.map((entry) => entry.token), [
      'pst-main',
      'pst-alt',
    ]);
    expect(settings.effectiveApiTokens.map((entry) => entry.token), [
      'pst-main',
      'pst-alt',
    ]);
  });

  test('main token replacement preserves its order and removes duplicates', () {
    final settings = Settings.fromJson({
      'api_key': 'pst-main',
      'api_tokens': [
        {'label': 'Alt 1', 'token': 'pst-alt-1', 'enabled': true},
        {
          'label': 'Main label',
          'token': 'pst-main',
          'enabled': false,
          'is_primary': true,
        },
        {'label': 'Alt 2', 'token': 'pst-alt-2', 'enabled': true},
      ],
      'parallel_api_enabled': true,
    });

    settings.updatePrimaryApiKey('pst-alt-2');

    expect(settings.apiKey, 'pst-alt-2');
    expect(settings.apiTokens.map((entry) => entry.token), [
      'pst-alt-1',
      'pst-alt-2',
    ]);
    expect(settings.apiTokens[1].isPrimary, isTrue);
    expect(settings.apiTokens[1].enabled, isFalse);
  });

  test('parallel mode caps enabled accounts at six', () {
    final settings = Settings.fromJson({
      'api_key': 'pst-main',
      'parallel_api_enabled': true,
      'api_tokens': [
        for (var i = 0; i < 7; i++)
          {'label': 'T$i', 'token': 'pst-$i', 'enabled': true},
      ],
    });

    expect(settings.apiTokens.where((entry) => entry.enabled), hasLength(6));
    expect(settings.effectiveApiTokens, hasLength(6));
  });

  test('masked token hides the middle of the value', () {
    final token = ApiTokenConfig(label: 'A', token: 'pst-abcdefghijklmnop');
    expect(token.maskedToken, 'pst-ab···mnop');
    expect(token.maskedToken.contains('cdefgh'), isFalse);
  });

  test('masked token is total for empty and short legacy values', () {
    expect(ApiTokenConfig(label: 'empty', token: '').maskedToken, '');
    expect(ApiTokenConfig(label: 'one', token: 'x').maskedToken, 'x···');
    expect(ApiTokenConfig(label: 'two', token: 'xy').maskedToken, 'xy···');
    expect(ApiTokenConfig(label: 'short', token: 'pst').maskedToken, 'ps···');
  });
}
