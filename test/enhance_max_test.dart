import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/ui/generation_page/widgets/result_actions.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/enhance_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/use_cases/enhance_request_options.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';

PayloadConfig configFor(String model, String prompt) => PayloadConfig(
      rootPromptConfig:
          PromptConfig(strs: [prompt], prompts: [], shuffled: false),
      negativePromptConfig: PromptConfig(strs: ['bad quality'], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(model: model),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

const sourcePlan = I2iRequestPlan(
  imageB64: 'aW1hZ2U=',
  maskB64: null,
  width: 1216,
  height: 832,
  strength: .5,
  noise: 0,
  addOriginalImage: false,
  composite: null,
  summary: 'Enhance',
);

class _WebsiteRandom implements Random {
  _WebsiteRandom(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  bool nextBool() => throw UnimplementedError();
  @override
  int nextInt(int max) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Enhance final-size alignment handles both sides of the half-step', () {
    for (final item in [
      (95, 64),
      (96, 128),
      (97, 128),
      (1248, 1280),
      (1824, 1856)
    ]) {
      expect(EnhanceRequestOptions.apiSize(item.$1, item.$1),
          GenerationSize(width: item.$2, height: item.$2));
    }
    final config = EnhanceConfig()
      ..setPreparedImage(Uint8List(1), width: 832, height: 1216);
    config.setScale(1.5);
    expect(config.requestSize('nai-diffusion-5-full'),
        const GenerationSize(width: 1248, height: 1824));
    expect(config.outputSize('nai-diffusion-5-full'),
        const GenerationSize(width: 1280, height: 1856));
    expect(config.costSize('nai-diffusion-5-full'),
        const GenerationSize(width: 1280, height: 1856));
  });

  test('Max eligibility uses source area before final API alignment', () {
    final config = EnhanceConfig();
    for (final size in [(1472, 1700), (1700, 1472), (1536, 1638)]) {
      config.setPreparedImage(Uint8List(1), width: size.$1, height: size.$2);
      expect(config.canUseMax('nai-diffusion-5-full'), isTrue);
      config.selectMax();
      expect(config.usesMax('nai-diffusion-5-full'), isTrue);
    }
    config.setPreparedImage(Uint8List(1), width: 1536, height: 1639);
    expect(config.canUseMax('nai-diffusion-5-full'), isFalse);
  });

  test('Max billing applies website 16 and 32 grids directly to source', () {
    expect(EnhanceRequestOptions.costSize(1472, 1700),
        const GenerationSize(width: 1664, height: 1888));
    expect(EnhanceRequestOptions.costSize(1536, 1638),
        const GenerationSize(width: 1696, height: 1824));
  });

  test('ordinary scale eligibility checks exact fractional dimensions', () {
    final config = EnhanceConfig()
      ..setPreparedImage(Uint8List(1), width: 43, height: 43);
    expect(config.availableScales, isEmpty);
  });

  test('Enhance follows website random seed range and signed noise seed', () {
    for (final sample in [
      (0.0, -1),
      (1 / 0x100000000, 0),
      (0.5, 2147483647),
      (1 - 1 / 0x100000000, 4294967294),
    ]) {
      final seed =
          EnhanceRequestOptions.nextSeed(random: _WebsiteRandom(sample.$1));
      expect(seed, sample.$2);
      for (final upscale in [false, true]) {
        final result = GeneratePayloadUseCase(
          payloadConfig: configFor('nai-diffusion-5-full', 'teapot'),
          i2iPlan: sourcePlan,
          seedOverride: seed,
          enhanceOptions: EnhanceRequestOptions(upscale: upscale),
        )();
        expect(result.payload['parameters']['seed'], seed);
        expect(result.payload['parameters']['extra_noise_seed'], seed - 1);
      }
    }
  });

  test('Max separates request, output and billing sizes from website evidence',
      () {
    final config = EnhanceConfig();
    config.setPreparedImage(Uint8List(1), width: 1216, height: 832);
    expect(config.maxSelected, isFalse);
    config.selectMax();
    expect(config.requestSize('nai-diffusion-5-full'),
        const GenerationSize(width: 1216, height: 832));
    expect(config.outputSize('nai-diffusion-5-full'),
        const GenerationSize(width: 2144, height: 1467));
    expect(config.costSize('nai-diffusion-5-full'),
        const GenerationSize(width: 2144, height: 1440));
    expect(config.usesMax('nai-diffusion-4-5-full'), isFalse);
    expect(config.usesMax('nai-diffusion-5-curated'), isTrue);
    config.setScale(1.5);
    expect(config.outputSize('nai-diffusion-5-full'),
        const GenerationSize(width: 1856, height: 1280));
    expect(config.maxSelected, isFalse);
  });

  test('result Enhance estimate reflects imported model and reset scale',
      () async {
    await GetIt.I.reset();
    final config = configFor('nai-diffusion-4-5-full', '');
    config.settings.subscriptionStatusKnown = true;
    config.enhanceConfig.setScale(1);
    GetIt.I.registerSingleton(config);
    final actions = ResultActions(
        content: InfoCardContent(
      title: 'synthetic.png',
      info: '',
      imageBytes: Uint8List(1),
      additionalInfo: const {
        'width': 1216,
        'height': 832,
        'steps': 28,
        'model': 'nai-diffusion-5-full'
      },
    ));
    // Import selects 1.5x, not the prior source's 1x setting.
    expect(actions.estimateEnhanceCost()?.anlas, 35);
    expect(config.enhanceConfig.scale, 1);
    await GetIt.I.reset();
  });

  test('Max rejects excessive area and extreme ratios without enabling it', () {
    final config = EnhanceConfig();
    for (final size in [(2048, 1536), (8, 512), (100000, 16)]) {
      config.setPreparedImage(Uint8List(1), width: size.$1, height: size.$2);
      expect(config.canUseMax('nai-diffusion-5-full'), isFalse);
    }
    config.setPreparedImage(Uint8List(1), width: 512, height: 512);
    expect(config.canUseMax('nai-diffusion-5-full'), isTrue);
    expect(config.availableScales, [1, 1.5, 2]);
    config.selectMax();
    config.removeImage();
    expect(config.canUseMax('nai-diffusion-5-full'), isFalse);
  });

  test('Max payload matches captured website fields without mutating settings',
      () {
    final config = configFor('nai-diffusion-5-full', 'a blue bird');
    final before = jsonEncode(config.toJson());
    final result = GeneratePayloadUseCase(
      payloadConfig: config,
      i2iPlan: sourcePlan,
      seedOverride: 1234,
      enhanceOptions: const EnhanceRequestOptions(upscale: true),
    )();
    final p = result.payload['parameters'] as Map<String, dynamic>;
    expect(result.payload['action'], 'img2img');
    expect(p['upscaled_enhance'], isTrue);
    expect(p['width'], 1216);
    expect(p['height'], 832);
    expect(p['n_samples'], 1);
    expect(p['noise_schedule'], 'karras');
    expect(p['color_correct'], isFalse);
    expect(p, isNot(contains('skip_cfg_above_sigma')));
    expect(p, isNot(contains('add_original_image')));
    expect(result.payload['input'], isNot(contains('upscaled, blurry')));
    expect(p['v4_prompt']['caption']['base_caption'], result.payload['input']);
    expect(jsonEncode(config.toJson()), before);
  });

  test(
      'standard Enhance places hidden words before Text and does not duplicate',
      () {
    for (final model in ['nai-diffusion-5-full', 'nai-diffusion-4-5-full']) {
      final config = configFor(model, 'a sign, Text: HELLO');
      final result = GeneratePayloadUseCase(
        payloadConfig: config,
        i2iPlan: sourcePlan,
        enhanceOptions: const EnhanceRequestOptions(),
      )();
      final prompt = result.payload['input'] as String;
      expect(prompt.indexOf('upscaled, blurry'),
          lessThan(prompt.indexOf('Text:')));
      final again = const EnhanceRequestOptions().prompt(prompt, model);
      expect(again, prompt);
      expect(result.payload['parameters'], isNot(contains('upscaled_enhance')));
    }
  });

  test(
      'portrait Enhance preserves conditioning size but aligns final API dimensions',
      () {
    const plan = I2iRequestPlan(
      imageB64: 'portrait',
      maskB64: null,
      width: 1248,
      height: 1824,
      strength: .5,
      noise: 0,
      addOriginalImage: false,
      composite: null,
      summary: '832x1216 at 1.5x',
    );
    final result = GeneratePayloadUseCase(
      payloadConfig: configFor('nai-diffusion-5-full', 'a teapot'),
      i2iPlan: plan,
      seedOverride: 42,
      enhanceOptions: const EnhanceRequestOptions(),
    )();
    expect(result.payload['parameters']['width'], 1280);
    expect(result.payload['parameters']['height'], 1856);
    expect(result.payload['parameters']['image'], 'portrait');
    expect(plan.width, 1248);
    expect(plan.height, 1824);
  });

  test('ordinary generation retains its own schedule and no Enhance words', () {
    final config = configFor('nai-diffusion-5-full', 'a blue bird');
    config.paramConfig.noiseSchedule = 'native';
    final result = GeneratePayloadUseCase(payloadConfig: config)();
    expect(result.payload['parameters']['noise_schedule'], 'native');
    expect(result.payload['input'], isNot(contains('upscaled, blurry')));
    expect(result.payload['parameters'], isNot(contains('upscaled_enhance')));
  });

  test(
      'Enhance preparation scales PNG and preserves V5 alpha without changing source',
      () async {
    final source = img.Image(width: 32, height: 32, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(255, 0, 0, 128));
    final bytes = Uint8List.fromList(img.encodePng(source));
    final original = List<int>.of(bytes);
    for (final transparent in [true, false]) {
      final plan = await preparePlainImg2ImgBytesInBackground(
        imageBytes: bytes,
        sourceWidth: 32,
        sourceHeight: 32,
        targetWidth: 64,
        targetHeight: 64,
        strength: .5,
        noise: 0,
        addOriginalImage: false,
        transparentBackground: transparent,
      );
      final decoded = img.decodePng(base64Decode(plan.imageB64))!;
      expect(decoded.width, 64);
      expect(decoded.height, 64);
      expect(decoded.getPixel(20, 20).a, transparent ? 128 : 255);
      expect(bytes, original);
    }
  });
}
