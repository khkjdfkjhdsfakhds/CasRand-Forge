import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/core/constants/parameters.dart';
import 'package:nai_casrand/data/models/param_config.dart';

void main() {
  test('generation defaults use NAI 5 Full guidance 5 and rescale 0', () {
    final defaults = ParamConfig();
    final missingDefaults = defaults.toJson()
      ..remove('model')
      ..remove('scale')
      ..remove('cfg_rescale');
    final explicitLegacyValues = defaults.toJson()
      ..['model'] = 'nai-diffusion-4-curated-preview'
      ..['scale'] = 6.5
      ..['cfg_rescale'] = 0.1;

    expect(defaults.model, 'nai-diffusion-5-full');
    expect(defaults.scale, 5.0);
    expect(defaults.cfgRescale, 0.0);

    final migratedDefaults = ParamConfig.fromJson(missingDefaults);
    expect(migratedDefaults.model, 'nai-diffusion-5-full');
    expect(migratedDefaults.scale, 5.0);
    expect(migratedDefaults.cfgRescale, 0.0);

    final preservedValues = ParamConfig.fromJson(explicitLegacyValues);
    expect(preservedValues.model, 'nai-diffusion-4-curated-preview');
    expect(preservedValues.scale, 6.5);
    expect(preservedValues.cfgRescale, 0.1);
  });

  test('V5 payload drops SMEA flags and keeps the native schedule', () {
    final config = ParamConfig(
      model: 'nai-diffusion-5-full',
      sampler: 'k_euler_ancestral',
      noiseSchedule: 'native',
      sm: true,
      smDyn: true,
      randomSeed: false,
      seed: 7,
    );

    final payload = config.getPayload();

    expect(payload.containsKey('sm'), isFalse);
    expect(payload.containsKey('sm_dyn'), isFalse);
    expect(payload['noise_schedule'], 'native');
  });

  test('AI character position choice defaults on and preserves saved choices',
      () {
    final missingChoice = ParamConfig().toJson()..remove('auto_position');
    final savedManualChoice = ParamConfig().toJson()..['auto_position'] = false;

    expect(ParamConfig().autoPosition, isTrue);
    expect(ParamConfig.fromJson(missingChoice).autoPosition, isTrue);
    expect(
      ParamConfig.fromJson(savedManualChoice).autoPosition,
      isFalse,
    );
  });

  test('fixed seed value is preserved in saved configs', () {
    final restored = ParamConfig.fromJson(
      ParamConfig(randomSeed: false, seed: 45744032).toJson(),
    );

    expect(restored.randomSeed, isFalse);
    expect(restored.seed, 45744032);
    expect(restored.getPayload()['seed'], 45744032);
  });

  test('empty fixed seed has a safe zero payload fallback', () {
    final config = ParamConfig(randomSeed: false, seed: null);

    expect(config.getPayload()['seed'], 0);
  });

  test('V4 native schedule uses server defaults after mapping to karras', () {
    final config = ParamConfig(
      model: 'nai-diffusion-4-5-full',
      sampler: 'k_euler_ancestral',
      noiseSchedule: 'native',
      randomSeed: false,
      seed: 1524057167,
    );

    final payload = config.getPayload();

    expect(payload['noise_schedule'], 'karras');
    expect(payload.containsKey('deliberate_euler_ancestral_bug'), isFalse);
    expect(payload.containsKey('prefer_brownian'), isFalse);
  });

  test('imported sampler compatibility flags are preserved in payload', () {
    final config = ParamConfig();
    config.loadJson({
      'sampler': 'k_euler_ancestral',
      'noise_schedule': 'karras',
      'deliberate_euler_ancestral_bug': true,
      'prefer_brownian': false,
    });

    final payload = config.getPayload();

    expect(payload['deliberate_euler_ancestral_bug'], isTrue);
    expect(payload['prefer_brownian'], isFalse);
  });

  test('manually selected karras keeps the regular website defaults', () {
    final config = ParamConfig(
      sampler: 'k_euler_ancestral',
      noiseSchedule: 'karras',
    );

    final payload = config.getPayload();

    expect(payload['deliberate_euler_ancestral_bug'], isFalse);
    expect(payload['prefer_brownian'], isTrue);
  });

  test('manual sampler changes clear imported compatibility flags', () {
    final config = ParamConfig(
      deliberateEulerAncestralBug: true,
      preferBrownian: false,
    );

    config.clearImportedSamplerOverrides();
    final payload = config.getPayload();

    expect(payload.containsKey('deliberate_euler_ancestral_bug'), isFalse);
    expect(payload.containsKey('prefer_brownian'), isFalse);
  });

  test('loading a new sampler clears flags missing from new metadata', () {
    final config = ParamConfig(
      deliberateEulerAncestralBug: false,
      preferBrownian: true,
    );

    config.loadJson({
      'sampler': 'k_euler_ancestral',
      'noise_schedule': 'karras',
      'deliberate_euler_ancestral_bug': true,
    });
    final payload = config.getPayload();

    expect(payload['deliberate_euler_ancestral_bug'], isTrue);
    expect(payload.containsKey('prefer_brownian'), isFalse);
  });

  test('metadata import carries every supported generation setting', () {
    final config = ParamConfig();

    final loaded = config.loadJson({
      'model': 'nai-diffusion-4-5-curated',
      'width': 1024,
      'height': 1024,
      'scale': 6,
      'sampler': 'k_dpmpp_2m',
      'steps': 41,
      'n_samples': 2,
      'noise_schedule': 'exponential',
      'cfg_rescale': 0.35,
      'variety_plus': true,
      'legacy_uc': true,
      'seed': 123456,
    });

    expect(loaded, greaterThan(0));
    expect(config.model, 'nai-diffusion-4-5-curated');
    expect(config.sizes.single.width, 1024);
    expect(config.sizes.single.height, 1024);
    expect(config.scale, 6.0);
    expect(config.sampler, 'k_dpmpp_2m');
    expect(config.steps, 41);
    expect(config.nSamples, 2);
    expect(config.noiseSchedule, 'exponential');
    expect(config.cfgRescale, 0.35);
    expect(config.varietyPlus, isTrue);
    expect(config.legacyUc, isTrue);
    expect(config.randomSeed, isFalse);
    expect(config.seed, 123456);
  });

  test('NovelAI V4.5 metadata sources map to the correct models', () {
    expect(
      sourceToModel['NovelAI Diffusion V4.5 4BDE2A90'],
      'nai-diffusion-4-5-full',
    );
    expect(
      sourceToModel['NovelAI Diffusion V4.5 C02D4F98'],
      'nai-diffusion-4-5-curated',
    );
    expect(
      sourceToModel['NovelAI Diffusion V4.5 B5A2A797'],
      'nai-diffusion-4-5-curated',
    );
  });

  test('current and legacy V5 metadata hashes map to the correct variants', () {
    expect(
      sourceToModel['NovelAI Diffusion V5 0ADF9AB7'],
      'nai-diffusion-5-full',
    );
    expect(
      sourceToModel['NovelAI Diffusion V5 657484A5'],
      'nai-diffusion-5-full',
    );
    expect(
      sourceToModel['NovelAI Diffusion V5 DB276663'],
      'nai-diffusion-5-curated',
    );
    expect(
      modelFromSource('NovelAI Diffusion V5 FUTUREHASH'),
      'nai-diffusion-5-curated',
    );
  });

  test('V5 payload uses tag-hint / straight-alpha instead of legacy flags', () {
    final config = ParamConfig(
      model: 'nai-diffusion-5-full',
      randomSeed: false,
      seed: 7,
    );

    final payload = config.getPayload();

    expect(payload['ucPreset'], isNull);
    expect(payload['qualityToggle'], isNull);
    expect(payload['tag_hint_qt'], 0);
    expect(payload['tag_hint_uc_preset'], 0);
    expect(payload['straight_alpha'], isTrue);
  });

  test('legacy models keep ucPreset and qualityToggle in the payload', () {
    final config = ParamConfig(
      model: 'nai-diffusion-4-5-full',
      randomSeed: false,
      seed: 7,
    );

    final payload = config.getPayload();

    expect(payload['ucPreset'], 2);
    expect(payload['qualityToggle'], isFalse);
    expect(payload.containsKey('tag_hint_qt'), isFalse);
    expect(payload.containsKey('straight_alpha'), isFalse);
  });

  test('imported V5 tag-hint fields override the official defaults', () {
    final config = ParamConfig(model: 'nai-diffusion-5-full');
    config.loadJson({
      'straight_alpha': false,
      'tag_hint_qt': 3,
      'tag_hint_uc_preset': 1,
    });

    final payload = config.getPayload();

    expect(payload['straight_alpha'], isFalse);
    expect(payload['tag_hint_qt'], 3);
    expect(payload['tag_hint_uc_preset'], 1);
  });

  test('V5 tag-hint fields survive config save and restore', () {
    final source = ParamConfig(
      model: 'nai-diffusion-5-full',
      straightAlpha: false,
      tagHintQt: 2,
      tagHintUcPreset: 1,
    );

    final restored = ParamConfig.fromJson(source.toJson());

    expect(restored.straightAlpha, isFalse);
    expect(restored.tagHintQt, 2);
    expect(restored.tagHintUcPreset, 1);
    expect(restored.getPayload()['straight_alpha'], isFalse);
    expect(restored.getPayload()['tag_hint_qt'], 2);
    expect(restored.getPayload()['tag_hint_uc_preset'], 1);
  });

  test('V5 transparent background defaults off and is omitted when disabled',
      () {
    final config = ParamConfig(model: 'nai-diffusion-5-full');

    final payload = config.getPayload();

    expect(config.transparentBackground, isFalse);
    expect(payload.containsKey('tag_hint_transparent_background'), isFalse);
  });

  test('enabling transparent background sends the V5 tag hint', () {
    final config = ParamConfig(
      model: 'nai-diffusion-5-full',
      transparentBackground: true,
    );

    final payload = config.getPayload();

    expect(payload['tag_hint_transparent_background'], isTrue);
  });

  test('transparent background flag survives config save and restore', () {
    final source = ParamConfig(
      model: 'nai-diffusion-5-full',
      transparentBackground: true,
    );

    final restored = ParamConfig.fromJson(source.toJson());

    expect(restored.transparentBackground, isTrue);
    expect(restored.getPayload()['tag_hint_transparent_background'], isTrue);
  });

  test('transparent background is ignored for legacy models', () {
    final config = ParamConfig(
      model: 'nai-diffusion-4-5-full',
      transparentBackground: true,
    );

    final payload = config.getPayload();

    expect(payload.containsKey('tag_hint_transparent_background'), isFalse);
  });
}
