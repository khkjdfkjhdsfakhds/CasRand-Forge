import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/precise_reference/view_models/precise_reference_list_viewmodel.dart';

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

  test('estimates extra Anlas for active references only', () {
    final payloadConfig = GetIt.I<PayloadConfig>();
    payloadConfig.preciseReferenceConfigList.addAll([
      PreciseReferenceConfig(imageB64: 'a', fileName: 'a.png'),
      PreciseReferenceConfig(
        imageB64: 'b',
        fileName: 'b.png',
        enabled: false,
      ),
    ]);
    final viewmodel = PreciseReferenceListViewmodel();
    viewmodel.setFeatureEnabled(true);

    expect(viewmodel.isSupported, isTrue);
    expect(viewmodel.activeReferenceCount, 1);
    expect(viewmodel.estimatedExtraAnlas, 10);
  });

  test('strength and fidelity setters clamp to zero-one range', () {
    final payloadConfig = GetIt.I<PayloadConfig>();
    final config = PreciseReferenceConfig(imageB64: 'a', fileName: 'a.png');
    payloadConfig.preciseReferenceConfigList.add(config);
    final viewmodel = PreciseReferenceListViewmodel();

    viewmodel.setStrength(config, -1);
    viewmodel.setFidelity(config, 2);

    expect(config.strength, 0.0);
    expect(config.fidelity, 1.0);
  });

  test('manual disable survives additions, then deleting all resets it',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final sourceImage = img.Image(width: 64, height: 64);
    img.fill(sourceImage, color: img.ColorRgb8(0, 120, 255));
    final bytes = Uint8List.fromList(img.encodePng(sourceImage));
    final payloadConfig = GetIt.I<PayloadConfig>();
    final viewmodel = PreciseReferenceListViewmodel();

    await viewmodel.addReferenceBytes(bytes, 'first.png');
    expect(payloadConfig.preciseReferenceEnabled, isTrue);
    viewmodel.setFeatureEnabled(false);
    await viewmodel.addReferenceBytes(bytes, 'second.png');
    expect(payloadConfig.preciseReferenceEnabled, isFalse);

    viewmodel.removeConfigAtIndex(1);
    viewmodel.removeConfigAtIndex(0);
    expect(payloadConfig.preciseReferenceEnabled, isFalse);
    await viewmodel.addReferenceBytes(bytes, 'third.png');
    expect(payloadConfig.preciseReferenceEnabled, isTrue);
  });

  test('imported image is preprocessed to an official reference canvas',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final sourceImage = img.Image(width: 256, height: 256);
    img.fill(sourceImage, color: img.ColorRgb8(255, 0, 0));
    final config = await PreciseReferenceConfig.fromBytes(
      Uint8List.fromList(img.encodePng(sourceImage)),
      'square.png',
    );

    final processedImage = img.decodePng(config.imageBytes)!;

    expect(processedImage.width, 1472);
    expect(processedImage.height, 1472);
  });
}
