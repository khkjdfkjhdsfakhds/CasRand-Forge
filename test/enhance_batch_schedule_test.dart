import 'dart:typed_data';
import 'package:nai_casrand/data/models/director_tool_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/batch_tool_snapshot.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'enhance_max_test.dart' show configFor;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in PromptMode.values) {
    for (final count in [0, 3]) {
      for (final variant in ['enhance', ...toolTypes.map((t) => t.type)]) {
        final kind = variant == 'enhance'
            ? BatchToolKind.enhance
            : BatchToolKind.director;
        test('$variant send preserves schedule from $mode with count $count',
            () async {
          final c = configFor('nai-diffusion-5-full', 'a teapot');
          c.randomProfile.generationCount = 7;
          c.fixedProfile.generationCount = count;
          c.fixedProfile.generationIntervalSec = 9;
          c.promptMode = mode;
          c.enhanceConfig.setImage(Uint8List.fromList(
              img.encodePng(img.Image(width: 64, height: 64))));
          c.directorToolConfig.setImage(c.enhanceConfig.imageBytes!);
          if (kind == BatchToolKind.director) {
            c.directorToolConfig.setType(variant);
            c.directorToolConfig.setOverrideEnabled(true);
            c.directorToolConfig.setOverridePrompt('tool prompt');
            c.directorToolConfig.setDefry(4);
          }
          final savedFixed = PromptConfig(strs: ['fixed saved'], prompts: []);
          c.fixedProfile.savedPromptConfigList = [savedFixed];
          final savedRandom = PromptConfig(strs: ['random saved'], prompts: []);
          c.randomProfile.savedPromptConfigList = [savedRandom];
          GetIt.I.registerSingleton(c);
          GetIt.I.registerSingleton(CommandStatus());
          final vm =
              GenerationPageViewmodel(preparationFeedbackBarrier: () async {});
          try {
            expect(await vm.sendToolToBatch(kind), isTrue,
                reason: '${vm.toolBatchError}');

            if (kind == BatchToolKind.director) {
              expect(c.activeBatchTool!.directorType, variant);

              if (c.directorToolConfig.withPrompt) {
                expect(c.activeBatchTool!.directorPayload['defry'], 4);
                expect(c.rootPromptConfig.strs.single, 'tool prompt');
                expect(
                    c.activeBatchTool!.directorPayload['prompt'],
                    variant == 'emotion'
                        ? 'neutral;;tool prompt'
                        : 'tool prompt');
              }
            }
            expect(c.fixedProfile.savedPromptConfigList, [same(savedFixed)]);
            expect(c.randomProfile.savedPromptConfigList, [same(savedRandom)]);
            expect(
                identical(c.fixedProfile.savedPromptConfigList,
                    c.randomProfile.savedPromptConfigList),
                isFalse);
            expect(c.generationCount, count);
            expect(c.settings.generationCount, count);
            expect(c.settings.generationIntervalSec, 9);
            expect(c.randomProfile.generationCount, 7);
            expect(c.generationIntervalSec, 9);
            vm.refreshCostEstimate();
            expect(c.settings.generationCount, count);
            expect(c.settings.generationIntervalSec, 9);
            expect(await vm.sendToolToBatch(kind), isTrue);
            expect(c.fixedProfile.savedPromptConfigList, [same(savedFixed)]);
            expect(c.randomProfile.savedPromptConfigList, [same(savedRandom)]);
            expect(
                identical(c.fixedProfile.savedPromptConfigList,
                    c.randomProfile.savedPromptConfigList),
                isFalse);
            expect(c.generationCount, count);
            expect(c.generationIntervalSec, 9);
            c.deactivateBatchTool();
            expect(c.promptMode, mode);
            expect(c.generationCount, mode == PromptMode.fixed ? count : 7);
          } finally {
            vm.dispose();
            await GetIt.I.reset();
          }
        });
      }
    }
  }
}
