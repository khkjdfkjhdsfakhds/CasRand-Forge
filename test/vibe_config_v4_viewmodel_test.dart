import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/ui/vibe_config_v4/viewmodels/vibe_config_v4_list_viewmodel.dart';

import 'vibe_test_utils.dart';

void main() {
  setUp(() async {
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton(
      PayloadConfig(
        rootPromptConfig: PromptConfig(strs: [], prompts: []),
        negativePromptConfig: PromptConfig(strs: [], prompts: []),
        characterConfigList: [],
        savedPromptConfigList: [],
        paramConfig: ParamConfig(
          model: 'nai-diffusion-4-5-full',
          nSamples: 2,
        ),
        settings: Settings.fromJson({}),
        overridePrompt: '',
        useOverridePrompt: false,
        useCharacterPromptWithOverride: false,
      ),
    );
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  VibeConfigV4 vibe(int index) => VibeConfigV4(
        fileName: 'vibe-$index',
        vibeB64: 'encoded-$index',
        referenceStrength: 0.2,
      );

  test('estimates only active Vibes beyond the four free slots', () {
    final payloadConfig = GetIt.I<PayloadConfig>();
    final viewmodel = VibeConfigV4ListViewmodel();

    payloadConfig.vibeConfigListV4.addAll(List.generate(4, vibe));
    viewmodel.setFeatureEnabled(true);
    expect(viewmodel.estimatedExtraAnlas, 0);

    payloadConfig.vibeConfigListV4.add(vibe(4));
    expect(viewmodel.estimatedExtraAnlas, 4);

    viewmodel.setFeatureEnabled(false);
    expect(viewmodel.estimatedExtraAnlas, 0);
  });

  test('normal image import is pending until generation and costs 2 Anlas', () {
    final payloadConfig = GetIt.I<PayloadConfig>();
    final viewmodel = VibeConfigV4ListViewmodel();

    final count = viewmodel.addVibeBytes(makeTestPng(), 'reference.png');

    expect(count, 1);
    expect(payloadConfig.vibeConfigListV4, hasLength(1));
    expect(payloadConfig.vibeEnabled, isTrue);
    expect(viewmodel.pendingEncodingCount, 1);
    expect(viewmodel.unavailableEncodingCount, 0);
    expect(viewmodel.estimatedEncodingAnlas, 2);
  });

  test('embedded PNG encoding is ready for the current model', () {
    final viewmodel = VibeConfigV4ListViewmodel();
    final png = embedVibeEncodingInPng(makeTestPng(), 'embedded-vibe');

    viewmodel.addVibeBytes(png, 'embedded.png');

    expect(viewmodel.pendingEncodingCount, 0);
    expect(viewmodel.unavailableEncodingCount, 0);
    expect(
      viewmodel.vibeList.single.encodingFor(viewmodel.currentModel),
      'embedded-vibe',
    );
  });

  test('.naiv4vibe preserves imported strength and Information Extracted', () {
    final viewmodel = VibeConfigV4ListViewmodel();
    final bytes = utf8.encode(jsonEncode({
      'name': 'Imported',
      'type': 'encoding',
      'importInfo': {
        'model': 'nai-diffusion-4-5-full',
        'strength': 0.45,
        'information_extracted': 0.65,
      },
      'encodings': {
        'v4-5full': {
          'hash': {
            'params': {'information_extracted': 0.65},
            'encoding': 'imported-encoding',
          },
        },
      },
    }));

    viewmodel.addVibeBytes(bytes, 'imported.naiv4vibe');

    final config = viewmodel.vibeList.single;
    expect(config.referenceStrength, 0.45);
    expect(config.informationExtracted, 0.65);
    expect(config.encodingFor(viewmodel.currentModel), 'imported-encoding');
    expect(viewmodel.pendingEncodingCount, 0);
  });

  test('deleting the final Vibe resets manual disable for the next import', () {
    final payloadConfig = GetIt.I<PayloadConfig>();
    final viewmodel = VibeConfigV4ListViewmodel();

    payloadConfig.vibeConfigListV4.add(vibe(0));
    payloadConfig.noteVibeImported(wasEmpty: true);
    viewmodel.setFeatureEnabled(false);
    expect(payloadConfig.vibeEnabled, isFalse);

    viewmodel.removeConfigAtIndex(0);
    expect(payloadConfig.hasVibeResources, isFalse);

    payloadConfig.vibeConfigListV4.add(vibe(1));
    payloadConfig.noteVibeImported(wasEmpty: true);
    expect(payloadConfig.vibeEnabled, isTrue);
  });
}
