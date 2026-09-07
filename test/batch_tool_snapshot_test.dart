import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/batch_tool_snapshot.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';
import 'package:nai_casrand/data/use_cases/enhance_request_options.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

import 'enhance_max_test.dart' show configFor, sourcePlan;

class _PreviewViewmodel extends GenerationPageViewmodel {
  @override
  Future<void> refreshSubscriptionSnapshot() async {}
}

BatchToolSnapshot _enhance(PayloadConfig config) => BatchToolSnapshot.enhance(
      enhanceBatch: const I2iRequestBatch(
          plans: [sourcePlan], serial: true, summary: 'Enhance'),
      parameters: config.paramConfig,
      upscale: true,
      outputWidth: 2144,
      outputHeight: 1467,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => GetIt.I.reset());

  test('tool snapshot owns parameters and cancel restores random resources',
      () {
    final config = configFor('nai-diffusion-5-full', 'a teapot');
    config.i2iEnabled = true;
    config.vibeEnabled = true;
    config.preciseReferenceEnabled = true;
    final randomBefore = jsonEncode(config.randomProfile.toJson());
    final tool = _enhance(config);
    final steps = tool.parameters.steps;
    config.activateBatchTool(tool);
    expect(config.promptMode, PromptMode.fixed);
    tool.parameters.steps = 2;
    expect(tool.parameters.steps, steps);
    config.deactivateBatchTool();
    expect(config.promptMode, PromptMode.random);
    expect(config.activeBatchTool, isNull);
    expect(config.enhanceBatchTool, same(tool));
    expect(
        config.i2iEnabled &&
            config.vibeEnabled &&
            config.preciseReferenceEnabled,
        isTrue);
    expect(jsonEncode(config.randomProfile.toJson()), randomBefore);
    expect(jsonEncode(config.toJson()), isNot(contains(sourcePlan.imageB64)));
    config.activateBatchTool(tool);
    config.loadJson(config.toJson());
    expect(config.activeBatchTool, isNull);
    expect(config.enhanceBatchTool, isNull);
  });

  test('Max preview uses frozen billing size and ignores paused resources',
      () async {
    final config = configFor('nai-diffusion-5-full', 'a teapot');
    config.settings.subscriptionStatusKnown = true;
    config.settings.subscriptionActive = false;
    final tool = _enhance(config);
    config.activateBatchTool(tool);
    config.paramConfig.steps = 50;
    config.paramConfig.nSamples = 8;
    config.i2iEnabled = true;
    config.vibeEnabled = true;
    GetIt.I.registerSingleton(config);
    GetIt.I.registerSingleton(CommandStatus());
    final vm = _PreviewViewmodel();
    vm.refreshCostEstimate();
    await Future<void>.delayed(Duration.zero);
    final size =
        EnhanceRequestOptions.costSize(sourcePlan.width, sourcePlan.height);
    expect(
        vm.nextCostEstimate.value?.anlas,
        estimateAnlasCost(
                width: size.width,
                height: size.height,
                steps: tool.parameters.steps,
                action: 'img2img',
                strength: .5,
                model: tool.parameters.model,
                subscriptionActive: false)
            .anlas);
    expect(vm.nextCostIsUpperBound, isFalse);
    vm.dispose();
  });

  test(
      'Director preview needs no subscription and charges once for three images',
      () async {
    final config = configFor('nai-diffusion-5-full', 'unused');
    config.settings.subscriptionStatusKnown = false;
    config.activateBatchTool(BatchToolSnapshot.director(payload: const {
      'req_type': 'bg-removal',
      'image': 'image',
      'width': 1024,
      'height': 1024
    }, label: 'Remove Background', outputWidth: 1024, outputHeight: 1024));
    GetIt.I.registerSingleton(config);
    GetIt.I.registerSingleton(CommandStatus());
    final vm = _PreviewViewmodel();
    vm.refreshCostEstimate();
    await Future<void>.delayed(Duration.zero);
    expect(vm.nextCostEstimate.value?.anlas, 65);
    expect(vm.nextCostEstimate.value?.isFreeUnderOpus, isFalse);
    expect(config.activeBatchTool!.usesPrompt, isFalse);
    vm.dispose();
  });
}
