import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';

void main() {
  test('hidden override prompt remains stored but is not applied', () {
    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['generated root prompt'],
        prompts: [],
      ),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: 'preserved override prompt',
      useOverridePrompt: true,
      useCharacterPromptWithOverride: false,
    );

    final result = GeneratePayloadUseCase(payloadConfig: config)();

    expect(result.payload['input'], 'generated root prompt');
    expect(config.useOverridePrompt, isTrue);
    expect(config.overridePrompt, 'preserved override prompt');
    expect(config.toJson()['use_override_prompt'], isTrue);
    expect(config.toJson()['override_prompt'], 'preserved override prompt');
  });
}
