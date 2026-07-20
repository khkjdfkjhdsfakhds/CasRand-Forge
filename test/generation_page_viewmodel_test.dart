import 'package:flutter_command/flutter_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

class _SchedulingViewmodel extends GenerationPageViewmodel {
  int nextCommandCalls = 0;

  @override
  void nextCommand() {
    nextCommandCalls++;
  }
}

void main() {
  setUp(() async {
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton(CommandStatus());
    GetIt.instance.registerSingleton(
      PayloadConfig(
        rootPromptConfig: PromptConfig(strs: [], prompts: []),
        negativePromptConfig: PromptConfig(
          shuffled: false,
          strs: ['test negative prompt'],
          prompts: [],
        ),
        characterConfigList: [],
        savedPromptConfigList: [],
        paramConfig: ParamConfig(
          sizes: const [GenerationSize(width: 832, height: 1216)],
          randomSeed: true,
          seed: 42,
        ),
        settings: Settings.fromJson({
          'generation_count': 0,
          'generation_interval': 10,
        }),
        overridePrompt: '',
        useOverridePrompt: false,
        useCharacterPromptWithOverride: false,
      ),
    );
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  test('adding a prompt command refreshes the generation page immediately', () {
    final viewmodel = GenerationPageViewmodel();
    var notificationCount = 0;
    viewmodel.addListener(() => notificationCount++);

    final command = Command.createSyncNoParam(
      () => const InfoCardContent(
        title: 'prompt',
        info: 'generated prompt',
        additionalInfo: {},
      ),
      initialValue: InfoCardContent.fromEmpty(),
    );

    viewmodel.addAndRunCommand(command);

    expect(viewmodel.commandList, contains(command));
    expect(notificationCount, 1);
    expect(command.value.title, 'prompt');
  });

  test('generation settings update the existing config fields', () {
    final viewmodel = GenerationPageViewmodel();
    final payloadConfig = GetIt.I<PayloadConfig>();

    viewmodel.setRandomSeedEnabled(false);
    viewmodel.setSeed('123456');
    viewmodel.setGenerationInterval('12');
    viewmodel.setGenerationCount('20');

    expect(payloadConfig.paramConfig.randomSeed, isFalse);
    expect(payloadConfig.paramConfig.seed, 123456);
    expect(payloadConfig.settings.generationIntervalSec, 12);
    expect(payloadConfig.settings.generationCount, 20);
  });

  test('invalid numeric settings leave the previous values unchanged', () {
    final viewmodel = GenerationPageViewmodel();
    final payloadConfig = GetIt.I<PayloadConfig>();

    viewmodel.setSeed('not-a-number');
    viewmodel.setGenerationInterval('invalid');
    viewmodel.setGenerationCount('invalid');
    viewmodel.setGenerationInterval('-1');
    viewmodel.setGenerationCount('-1');

    expect(payloadConfig.paramConfig.seed, 42);
    expect(payloadConfig.settings.generationIntervalSec, 10);
    expect(payloadConfig.settings.generationCount, 0);
  });

  test('size selection stays non-empty and rounds manual sizes to 64', () {
    final viewmodel = GenerationPageViewmodel();
    final paramConfig = GetIt.I<PayloadConfig>().paramConfig;
    const initialSize = GenerationSize(width: 832, height: 1216);

    viewmodel.removeSize(initialSize);
    expect(paramConfig.sizes, [initialSize]);

    viewmodel.addManualSize('833', '1217');
    expect(
      paramConfig.sizes,
      contains(const GenerationSize(width: 896, height: 1280)),
    );

    viewmodel.addManualSize('invalid', '1024');
    expect(paramConfig.sizes, hasLength(2));

    viewmodel.addSize(initialSize);
    expect(paramConfig.sizes, hasLength(2));
  });

  testWidgets('generation waits for the configured interval between images', (
    tester,
  ) async {
    final viewmodel = _SchedulingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();
    GetIt.I<PayloadConfig>().settings.generationIntervalSec = 1;
    commandStatus.isGenerationActive.value = true;

    viewmodel.scheduleNextGeneration();

    expect(commandStatus.isWaitingForNextGeneration.value, isTrue);
    await tester.pump(const Duration(milliseconds: 999));
    expect(viewmodel.nextCommandCalls, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(viewmodel.nextCommandCalls, 1);
    expect(commandStatus.isWaitingForNextGeneration.value, isFalse);
    viewmodel.dispose();
  });

  test('zero interval starts the next image immediately', () {
    final viewmodel = _SchedulingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();
    GetIt.I<PayloadConfig>().settings.generationIntervalSec = 0;
    commandStatus.isGenerationActive.value = true;

    viewmodel.scheduleNextGeneration();

    expect(viewmodel.nextCommandCalls, 1);
    expect(commandStatus.isWaitingForNextGeneration.value, isFalse);
    viewmodel.dispose();
  });

  testWidgets('stopping generation cancels the pending interval', (
    tester,
  ) async {
    final viewmodel = _SchedulingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();
    GetIt.I<PayloadConfig>().settings.generationIntervalSec = 1;
    commandStatus.isGenerationActive.value = true;

    viewmodel.scheduleNextGeneration();
    viewmodel.stopGeneration();
    await tester.pump(const Duration(seconds: 1));

    expect(viewmodel.nextCommandCalls, 0);
    expect(commandStatus.isGenerationActive.value, isFalse);
    expect(commandStatus.isWaitingForNextGeneration.value, isFalse);
    viewmodel.dispose();
  });

  testWidgets('finite generation stops and unlimited generation continues', (
    tester,
  ) async {
    final viewmodel = _SchedulingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();
    final settings = GetIt.I<PayloadConfig>().settings;
    settings.generationIntervalSec = 1;
    settings.generationCount = 2;
    commandStatus.currentGenerationCount = 2;
    commandStatus.isGenerationActive.value = true;

    viewmodel.continueAfterGenerationAttempt();

    expect(commandStatus.isGenerationActive.value, isFalse);
    expect(commandStatus.isWaitingForNextGeneration.value, isFalse);

    settings.generationCount = 0;
    commandStatus.currentGenerationCount = 0;
    commandStatus.isGenerationActive.value = true;
    viewmodel.continueAfterGenerationAttempt();

    expect(commandStatus.isWaitingForNextGeneration.value, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(viewmodel.nextCommandCalls, 1);
    viewmodel.dispose();
  });

  testWidgets('a failed attempt still waits before retrying', (tester) async {
    final viewmodel = _SchedulingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();
    final settings = GetIt.I<PayloadConfig>().settings;
    settings.generationIntervalSec = 1;
    settings.generationCount = 2;
    commandStatus.currentGenerationCount = 1;
    commandStatus.isGenerationActive.value = true;

    // Failed attempts do not increment currentGenerationCount, but they still
    // pass through the same post-attempt interval before a retry.
    viewmodel.continueAfterGenerationAttempt();

    expect(commandStatus.isWaitingForNextGeneration.value, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(viewmodel.nextCommandCalls, 1);
    viewmodel.dispose();
  });
}
