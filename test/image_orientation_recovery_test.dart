import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/director_tool_config.dart';
import 'package:nai_casrand/data/models/enhance_config.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/use_cases/prepare_director_tool_request_use_case.dart';

Uint8List _jpeg(int orientation, {int width = 400, int height = 200}) {
  final source = img.Image(width: width, height: height, numChannels: 3);
  img.fillRect(source,
      x1: 0,
      y1: 0,
      x2: width ~/ 2 - 1,
      y2: height - 1,
      color: img.ColorRgb8(240, 20, 20));
  img.fillRect(source,
      x1: width ~/ 2,
      y1: 0,
      x2: width - 1,
      y2: height - 1,
      color: img.ColorRgb8(20, 20, 240));
  source.exif.imageIfd.orientation = orientation;
  return Uint8List.fromList(img.encodeJpg(source, quality: 100));
}

PayloadConfig _payload() => PayloadConfig(
    rootPromptConfig: PromptConfig(strs: [], prompts: []),
    negativePromptConfig: PromptConfig(strs: [], prompts: []),
    characterConfigList: [],
    savedPromptConfigList: [],
    paramConfig: ParamConfig(),
    settings: Settings.fromJson({}),
    overridePrompt: '',
    useOverridePrompt: true,
    useCharacterPromptWithOverride: false);

void main() {
  for (final orientation in [1, 2, 3, 4, 5, 6, 7, 8]) {
    test(
        'IMG-05 all source configs honor EXIF orientation $orientation without changing bytes',
        () {
      final bytes = _jpeg(orientation);
      final i2i = I2IConfig()..setImage(bytes);
      final enhance = EnhanceConfig()..setImage(bytes);
      final director = DirectorToolConfig()..setImage(bytes);
      final portrait = orientation >= 5;
      for (final dimensions in [
        (i2i.width, i2i.height),
        (enhance.width, enhance.height),
        (director.width, director.height)
      ]) {
        expect(dimensions, portrait ? (200, 400) : (400, 200));
      }
      expect(i2i.imageBytes, same(bytes));
      expect(enhance.imageBytes, same(bytes));
      expect(director.imageBytes, same(bytes));
    });
  }
  test(
      'IMG-05 rotated Director request keeps portrait pixels as well as dimensions',
      () async {
    final bytes = _jpeg(6);
    final config = DirectorToolConfig()..setImage(bytes);
    final prepared = await const PrepareDirectorToolRequestUseCase()(
        imageBytes: bytes, width: config.width, height: config.height);
    final output = img.decodePng(base64Decode(prepared.imageB64))!;
    expect((output.width, output.height), (724, 1448));
    final top = output.getPixel(output.width ~/ 2, output.height ~/ 4);
    final bottom = output.getPixel(output.width ~/ 2, output.height * 3 ~/ 4);
    expect(top.r, greaterThan(top.b));
    expect(bottom.b, greaterThan(bottom.r));
  });
  for (final action in [
    ImageHandoffAction.imageToImage,
    ImageHandoffAction.enhance,
    ImageHandoffAction.directorTools
  ]) {
    testWidgets(
        'IMG-05 real handoff worker uses oriented dimensions and bounded preview: $action',
        (tester) async {
      final payload = _payload();
      final coordinator = ImageHandoffCoordinator(
          payloadConfig: payload, navigation: NavigationRequest());
      final bytes = _jpeg(6, width: 1200, height: 600);
      await tester.pumpWidget(const SizedBox());
      switch (action) {
        case ImageHandoffAction.imageToImage:
          coordinator.useAsBaseImage(bytes);
        case ImageHandoffAction.enhance:
          coordinator.sendToEnhance(bytes, metadata: const {});
        case ImageHandoffAction.directorTools:
          coordinator.sendToDirectorTools(bytes);
        case ImageHandoffAction.inpaint:
          throw StateError('not part of this fixture');
      }
      tester.binding.scheduleFrame();
      await tester.pump();
      for (var attempt = 0;
          attempt < 200 && coordinator.phase == ImageHandoffPhase.preparing;
          attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(coordinator.phase, ImageHandoffPhase.idle,
          reason: '${coordinator.error}');
      switch (action) {
        case ImageHandoffAction.imageToImage:
          expect(
              (payload.i2iConfig.width, payload.i2iConfig.height), (600, 1200));
          expect(payload.i2iConfig.imageBytes, same(bytes));
          final preview = img.decodePng(payload.i2iConfig.previewImageBytes!)!;
          expect((preview.width, preview.height), (256, 512));
        case ImageHandoffAction.enhance:
          expect((payload.enhanceConfig.width, payload.enhanceConfig.height),
              (600, 1200));
        case ImageHandoffAction.directorTools:
          expect((
            payload.directorToolConfig.width,
            payload.directorToolConfig.height
          ), (
            600,
            1200
          ));
        case ImageHandoffAction.inpaint:
          break;
      }
      coordinator.dispose();
    });
  }
}
