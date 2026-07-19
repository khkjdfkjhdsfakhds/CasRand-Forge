import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/core/constants/parameters.dart';
import 'package:nai_casrand/data/models/param_config.dart';

void main() {
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

  test('NovelAI V4.5 metadata sources map to the correct models', () {
    expect(
      sourceToModel['NovelAI Diffusion V4.5 4BDE2A90'],
      'nai-diffusion-4-5-full',
    );
    expect(
      sourceToModel['NovelAI Diffusion V4.5 C02D4F98'],
      'nai-diffusion-4-5-curated',
    );
  });
}
