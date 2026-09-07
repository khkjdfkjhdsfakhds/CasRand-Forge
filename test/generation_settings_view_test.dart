import 'package:nai_casrand/data/models/batch_tool_snapshot.dart';
import 'dart:convert';
import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/config_page/view_models/config_page_viewmodel.dart';
import 'package:nai_casrand/ui/config_page/widgets/config_page_view.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_page_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_settings_view.dart';
import 'package:nai_casrand/ui/parameters_config/view_models/parameters_config_viewmodel.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/parameters_conifg_view.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';
import 'package:nai_casrand/ui/settings_page/widgets/settings_page_view.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

class _NoNetworkGenerationPageViewmodel extends GenerationPageViewmodel {
  @override
  void nextCommand() {}
}

late Map<String, dynamic> testTranslations;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    final source = await rootBundle.loadString('assets/l10n/en.json');
    testTranslations = jsonDecode(source) as Map<String, dynamic>;
  });

  setUp(() async {
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton(CommandStatus());
    GetIt.instance.registerSingleton(NavigationRequest());
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

  Widget localizedApp(Widget home) {
    return EasyLocalization(
      key: UniqueKey(),
      supportedLocales: const [Locale('en')],
      path: 'test',
      assetLoader: _TestAssetLoader(testTranslations),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      saveLocale: false,
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: home,
        ),
      ),
    );
  }

  testWidgets(
      'advanced tool toggle is reachable at 390 width and restores random mode',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>();
    config.activateBatchTool(BatchToolSnapshot.director(payload: const {
      'req_type': 'lineart',
      'image': 'source',
      'width': 1024,
      'height': 1024
    }, label: 'Line Art', outputWidth: 1024, outputHeight: 1024));
    final vm = _NoNetworkGenerationPageViewmodel();
    await tester.pumpWidget(localizedApp(GenerationPageView(viewmodel: vm)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('active-batch-tool-summary')), findsOneWidget);
    await tester.tap(find.byKey(const Key('advanced-features-fab')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('batch-director-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(config.activeBatchTool, isNull);
    expect(config.promptMode, PromptMode.random);
    expect(tester.takeException(), isNull);
    vm.dispose();
  });

  testWidgets('moved settings appear together on the generation page', (
    tester,
  ) async {
    final viewmodel = _NoNetworkGenerationPageViewmodel();
    await tester.pumpWidget(
      localizedApp(
        Scaffold(body: GenerationSettingsView(viewmodel: viewmodel)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Image size (multiple selections)'), findsOneWidget);
    expect(find.text('Use Random Seed'), findsOneWidget);
    expect(find.text('Generation count'), findsOneWidget);
    expect(
      find.text('Generation interval (seconds; at least 2 recommended)'),
      findsOneWidget,
    );
    expect(find.text('Batch settings'), findsNothing);
    expect(find.text('Fixed Seed'), findsNothing);
    expect(find.text('Override random prompts'), findsNothing);

    final displayMode = tester.widget<SegmentedButton<String>>(
      find.descendant(
        of: find.byKey(const Key('generation-settings-display-mode')),
        matching: find.byType(SegmentedButton<String>),
      ),
    );
    expect(displayMode.segments.map((segment) => segment.value), [
      'classic',
      'waterfall',
    ]);
    expect(displayMode.selected, {'classic'});

    final orderedSettings = [
      find.text('Generation count'),
      find.text('Generation interval (seconds; at least 2 recommended)'),
      find.text('Image size (multiple selections)'),
      find.text('Use Random Seed'),
      // Display style comes first, and the column count belongs under it
      // because it now applies to both result layouts.
      find.text('Result display style'),
      find.text('Columns per row: 2'),
    ];
    final verticalOffsets =
        orderedSettings.map((finder) => tester.getTopLeft(finder).dy).toList();
    expect(verticalOffsets, orderedEquals(List.of(verticalOffsets)..sort()));
    await tester.tap(
      find.byKey(const Key('generation-settings-random-seed')),
    );
    await tester.pump();

    expect(GetIt.I<PayloadConfig>().paramConfig.randomSeed, isFalse);
    expect(find.text('Fixed Seed'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Fixed Seed')).dy,
      lessThan(tester.getTopLeft(find.text('Columns per row: 2')).dy),
    );

    await tester.tap(
      find.byKey(const Key('generation-settings-fixed-seed')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(GetIt.I<PayloadConfig>().paramConfig.seed, isNull);

    viewmodel.startGeneration();
    await tester.pump();

    expect(GetIt.I<PayloadConfig>().paramConfig.seed, 0);
    expect(
      find.descendant(
        of: find.byKey(const Key('generation-settings-fixed-seed')),
        matching: find.text('0'),
      ),
      findsOneWidget,
    );
    viewmodel.stopGeneration();

    expect(find.text('Request per batch'), findsNothing);
    expect(find.text('Interval between batches (seconds)'), findsNothing);
  });

  testWidgets('prompt mode button explains and preserves both profiles', (
    tester,
  ) async {
    final config = GetIt.I<PayloadConfig>();
    config.fixedProfile.rootPromptConfig =
        PayloadConfig.fixedPromptConfig('preserved prompt');
    config.randomProfile.paramConfig.steps = 17;
    config.fixedProfile.paramConfig.steps = 31;

    await tester.pumpWidget(
      localizedApp(
        GenerationPageView(viewmodel: GenerationPageViewmodel()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.shuffle), findsOneWidget);
    await tester.tap(find.byKey(const Key('prompt-mode-switch')));
    await tester.pumpAndSettle();

    expect(find.text('Switch generation profile'), findsOneWidget);
    expect(
      find.textContaining('other profile will not be deleted'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('prompt-mode-dont-ask-again')));
    await tester.tap(find.byKey(const Key('prompt-mode-confirm-switch')));
    await tester.pumpAndSettle();

    expect(config.promptMode, PromptMode.fixed);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(config.settings.confirmPromptModeSwitch, isFalse);
    expect(config.overridePrompt, 'preserved prompt');
    expect(config.paramConfig.steps, 31);
    expect(config.randomProfile.paramConfig.steps, 17);
  });

  testWidgets('fixed prompt mode exposes its separate prompt fields', (
    tester,
  ) async {
    final config = GetIt.I<PayloadConfig>();
    config.promptMode = PromptMode.fixed;
    config.overridePrompt = 'preserved prompt';
    config.fixedProfile.characterConfigList = [CharacterConfig.fromEmpty()];

    await tester.pumpWidget(
      localizedApp(
        PromptTabView(
          viewmodel: PromptTabViewmodel(payloadConfig: config),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fixed-prompt profile is active'), findsOneWidget);
    expect(find.byKey(const Key('fixed-positive-prompt')), findsOneWidget);
    expect(find.byKey(const Key('fixed-negative-prompt')), findsOneWidget);
    expect(find.byKey(const Key('character-gender-tile')), findsOneWidget);
    expect(find.byKey(const Key('character-positive-prompt')), findsOneWidget);
    expect(find.byKey(const Key('character-negative-prompt')), findsOneWidget);
    expect(config.overridePrompt, 'preserved prompt');
  });

  testWidgets('prompt settings mode button shows a tooltip without expanding', (
    tester,
  ) async {
    final config = GetIt.I<PayloadConfig>();
    await tester.pumpWidget(
      localizedApp(
        PromptTabView(
          viewmodel: PromptTabViewmodel(payloadConfig: config),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('prompt-mode-switch'));
    final collapsedWidth = tester.getSize(button).width;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(button));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.getSize(button).width, collapsedWidth);
    expect(find.text('Random prompts'), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('image size selector still supports preset and manual sizes', (
    tester,
  ) async {
    final viewmodel = GenerationPageViewmodel();
    await tester.pumpWidget(
      localizedApp(
        Scaffold(body: GenerationSettingsView(viewmodel: viewmodel)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('generation-settings-image-size')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Edit : Image size (multiple selections)'),
      findsOneWidget,
    );
    expect(find.text('Selected sizes'), findsOneWidget);
    expect(find.text('Preset sizes'), findsOneWidget);
    expect(find.text('Enter a custom size'), findsOneWidget);
    final expectedPresetOrder = [
      '832 × 1216',
      '1216 × 832',
      '1024 × 1024',
      '1024 × 1536',
      '1536 × 1024',
      '1472 × 1472',
      '768 × 1344',
      '1344 × 768',
    ];
    for (final preset in expectedPresetOrder) {
      expect(find.widgetWithText(OutlinedButton, preset), findsOneWidget);
    }
    expect(
      tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(OutlinedButton),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data)
          .toList(),
      expectedPresetOrder,
    );
    expect(
      find.widgetWithText(OutlinedButton, '704 × 1472'),
      findsNothing,
    );
    expect(
      find.widgetWithText(OutlinedButton, '1472 × 704'),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const Key('manual-size-width')),
      '833',
    );
    await tester.enterText(
      find.byKey(const Key('manual-size-height')),
      '1217',
    );
    final addButton = find.byKey(const Key('manual-size-add'));
    await tester.ensureVisible(addButton);
    await tester.pumpAndSettle();
    await tester.tap(addButton);
    await tester.pump();

    expect(find.text('896 × 1280'), findsOneWidget);
  });

  testWidgets('invalid manual image size stays open and shows feedback', (
    tester,
  ) async {
    final viewmodel = GenerationPageViewmodel();
    await tester.pumpWidget(
      localizedApp(
        Scaffold(body: GenerationSettingsView(viewmodel: viewmodel)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('generation-settings-image-size')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('manual-size-width')), '0');
    await tester.enterText(find.byKey(const Key('manual-size-height')), '1024');
    final addButton = find.byKey(const Key('manual-size-add'));
    await tester.ensureVisible(addButton);
    await tester.pumpAndSettle();
    await tester.tap(addButton);
    await tester.pump();

    expect(find.byKey(const Key('manual-size-error')), findsOneWidget);
    expect(find.text('Width and height must be greater than zero.'),
        findsOneWidget);
    expect(
      viewmodel.payloadConfig.paramConfig.sizes,
      isNot(contains(const GenerationSize(width: 0, height: 1024))),
    );
  });

  testWidgets('old pages no longer expose the moved settings', (tester) async {
    await tester.pumpWidget(
      localizedApp(
        ParametersConfigView(viewmodel: ParametersConfigViewmodel()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Image Size (W × H)'), findsNothing);
    expect(find.text('Use Random Seed'), findsNothing);
    expect(find.text('Unwanted content'), findsNothing);
    expect(find.text("AI's Choice"), findsNothing);

    await tester.pumpWidget(localizedApp(SettingsPageView()));
    await tester.pumpAndSettle();

    expect(find.text('Batch settings'), findsNothing);
  });

  testWidgets('sampling steps slider supports up to 50 steps', (tester) async {
    await tester.pumpWidget(
      localizedApp(
        ParametersConfigView(viewmodel: ParametersConfigViewmodel()),
      ),
    );
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(find.byType(Slider).first);

    expect(slider.max, 50);
    expect(slider.divisions, 50);

    await tester.tap(find.text('Sample Steps: 28'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sampling-steps-input')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('sampling-steps-input')),
      '37',
    );
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(GetIt.I<PayloadConfig>().paramConfig.steps, 37);
    expect(find.text('Sample Steps: 37'), findsOneWidget);
  });

  testWidgets('negative prompt stays below the dynamic character area', (
    tester,
  ) async {
    final viewmodel = PromptTabViewmodel(
      promptConfig: PromptConfig(
        shuffled: false,
        comment: 'Base config',
        strs: ['positive'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        type: 'config',
        shuffled: false,
        comment: 'Negative config',
        strs: [],
        prompts: [
          PromptConfig(
            shuffled: false,
            comment: 'Negative content',
            strs: ['negative'],
            prompts: [],
          ),
        ],
      ),
      characterConfigList: [],
      savedConfigList: [],
      paramConfig: ParamConfig(),
    );

    await tester.pumpWidget(localizedApp(PromptTabView(viewmodel: viewmodel)));
    await tester.pumpAndSettle();

    final baseSection = find.byKey(const Key('base-prompt-section'));
    final negativeSection = find.byKey(const Key('negative-prompt-section'));
    expect(baseSection, findsOneWidget);
    expect(negativeSection, findsOneWidget);
    expect(
      tester.getTopLeft(baseSection).dy,
      lessThan(tester.getTopLeft(negativeSection).dy),
    );

    final negativeConfig = find.byKey(const Key('negative-prompt-config'));
    expect(negativeConfig, findsOneWidget);
    expect(
      find.descendant(of: negativeConfig, matching: find.byIcon(Icons.add)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: negativeConfig, matching: find.byIcon(Icons.paste)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: negativeConfig, matching: find.byIcon(Icons.cached)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: negativeConfig, matching: find.byIcon(Icons.remove)),
      findsOneWidget,
    );

    expect(viewmodel.negativePromptConfig.prompts, hasLength(1));
    await tester.tap(
      find.descendant(of: negativeConfig, matching: find.byIcon(Icons.add)),
    );
    await tester.pump();
    expect(viewmodel.negativePromptConfig.prompts, hasLength(2));

    viewmodel.addCharacter();
    await tester.pumpAndSettle();

    final characterSection =
        find.byKey(const Key('character-prompt-section-0'));
    final baseY = tester.getTopLeft(baseSection).dy;
    final characterY = tester.getTopLeft(characterSection).dy;
    final negativeY = tester.getTopLeft(negativeSection).dy;
    expect(characterSection, findsOneWidget);
    expect(baseY, lessThan(characterY));
    expect(characterY, lessThan(negativeY));
    expect(find.text('负面内容'), findsOneWidget);
  });

  testWidgets('prompt types use separate cards and swapped negative titles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewmodel = PromptTabViewmodel(
      promptConfig: PromptConfig(
        shuffled: false,
        comment: 'Base config',
        strs: ['positive'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        comment: '负面内容',
        strs: ['negative'],
        prompts: [],
      ),
      characterConfigList: [CharacterConfig.fromEmpty()],
      savedConfigList: [],
      paramConfig: ParamConfig(),
    );

    await tester.pumpWidget(localizedApp(PromptTabView(viewmodel: viewmodel)));
    await tester.pumpAndSettle();

    final sections = [
      find.byKey(const Key('base-prompt-section')),
      find.byKey(const Key('character-prompt-section-0')),
      find.byKey(const Key('negative-prompt-section')),
    ];
    final sectionColors = <Color?>[];
    for (final section in sections) {
      expect(section, findsOneWidget);
      final sectionMaterial = tester
          .widgetList<Material>(
            find.descendant(of: section, matching: find.byType(Material)),
          )
          .firstWhere(
            (material) =>
                material.shape is RoundedRectangleBorder &&
                (material.shape as RoundedRectangleBorder).side !=
                    BorderSide.none,
          );
      sectionColors.add(sectionMaterial.color);
    }

    expect(sectionColors.toSet(), hasLength(3));
    expect(find.text('Negative Prompt'), findsOneWidget);
    expect(find.text('负面内容'), findsNWidgets(2));
    expect(find.byIcon(Icons.edit_note), findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
    expect(find.byIcon(Icons.block), findsOneWidget);
    expect(find.text('Character 1'), findsOneWidget);
    expect(find.text('Character #0'), findsNothing);
    expect(
      find.text('Tap properties to edit, scroll if information is cropped'),
      findsNothing,
    );

    final positionTile = find.byKey(const Key('character-position-tile'));
    final genderTile = find.byKey(const Key('character-gender-tile'));
    final positivePrompt = find.byKey(const Key('character-positive-prompt'));
    final negativePrompt = find.byKey(const Key('character-negative-prompt'));
    expect(positionTile, findsOneWidget);
    expect(genderTile, findsOneWidget);
    expect(positivePrompt, findsOneWidget);
    expect(negativePrompt, findsOneWidget);
    expect(
      tester.getTopLeft(positionTile).dy,
      lessThan(tester.getTopLeft(positivePrompt).dy),
    );
    expect(
      tester.getTopLeft(genderTile).dy,
      lessThan(tester.getTopLeft(positivePrompt).dy),
    );
    expect(
      tester.getTopLeft(positivePrompt).dy,
      lessThan(tester.getTopLeft(negativePrompt).dy),
    );
  });

  testWidgets('character position is single-select and AI choice disables grid',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final character = CharacterConfig.fromEmpty();
    final paramConfig = ParamConfig(model: 'nai-diffusion-4-5-full');
    final viewmodel = PromptTabViewmodel(
      promptConfig: PromptConfig(strs: [], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [character],
      savedConfigList: [],
      paramConfig: paramConfig,
    );
    await tester.pumpWidget(localizedApp(PromptTabView(viewmodel: viewmodel)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('character-position-tile')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('character-position-grid')), findsOneWidget);
    expect(find.byKey(const Key('auto-position-checkbox')), findsOneWidget);
    expect(character.positions, [CharacterConfig.defaultPosition]);
    expect(paramConfig.autoPosition, isTrue);
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(
              of: find.byKey(const Key('character-position-grid')),
              matching: find.byType(Opacity),
            ),
          )
          .opacity,
      0.35,
    );

    await tester.tap(
      find.byKey(const Key('character-position-D4')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(character.positions, [CharacterConfig.defaultPosition]);

    await tester.tap(find.byKey(const Key('auto-position-checkbox')));
    await tester.pump();
    expect(paramConfig.autoPosition, isFalse);

    await tester.tap(find.byKey(const Key('character-position-D4')));
    await tester.pump();
    expect(character.positions, [const Point<int>(4, 4)]);

    await tester.tap(find.byKey(const Key('character-position-A1')));
    await tester.pump();
    expect(character.positions, [const Point<int>(1, 1)]);
    await tester.tap(find.byKey(const Key('character-position-A1')));
    await tester.pump();
    expect(character.positions, [const Point<int>(1, 1)]);

    await tester.tap(find.byKey(const Key('auto-position-checkbox')));
    await tester.pump();
    expect(paramConfig.autoPosition, isTrue);
    final opacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.byKey(const Key('character-position-grid')),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, 0.35);
    await tester.tap(
      find.byKey(const Key('character-position-E5')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(character.positions, [const Point<int>(1, 1)]);

    character.positions.clear();
    await tester.tap(find.byKey(const Key('auto-position-checkbox')));
    await tester.pump();
    expect(paramConfig.autoPosition, isFalse);
    expect(character.positions, [CharacterConfig.defaultPosition]);
  });

  testWidgets('V5 manual position exposes AI choice and can switch back',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final character = CharacterConfig.fromEmpty()
      ..freeCenter = const Point<double>(0.244, 0.541);
    final paramConfig = ParamConfig(
      model: 'nai-diffusion-5-full',
      autoPosition: false,
    );
    final viewmodel = PromptTabViewmodel(
      promptConfig: PromptConfig(strs: [], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [character],
      savedConfigList: [],
      paramConfig: paramConfig,
    );
    await tester.pumpWidget(localizedApp(PromptTabView(viewmodel: viewmodel)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('character-position-tile')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('character-free-canvas')), findsOneWidget);
    expect(find.byKey(const Key('auto-position-checkbox')), findsOneWidget);
    expect(find.text("AI's Choice"), findsOneWidget);

    await tester.tap(find.byKey(const Key('auto-position-checkbox')));
    await tester.pump();

    expect(paramConfig.autoPosition, isTrue);
    expect(character.freeCenter, isNull);
    expect(find.byKey(const Key('character-free-canvas')), findsNothing);
    expect(find.byKey(const Key('character-position-grid')), findsOneWidget);
    expect(find.byKey(const Key('auto-position-checkbox')), findsOneWidget);
  });

  testWidgets('gender starts blank and Other removes a selected binary prefix',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final character = CharacterConfig.fromEmpty()
      ..positivePromptConfig.strs = ['portrait'];
    final viewmodel = PromptTabViewmodel(
      promptConfig: PromptConfig(strs: [], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [character],
      savedConfigList: [],
      paramConfig: ParamConfig(),
    );
    await tester.pumpWidget(localizedApp(PromptTabView(viewmodel: viewmodel)));
    await tester.pumpAndSettle();

    expect(character.gender, CharacterConfig.genderUnset);
    expect(find.text('Other'), findsNothing);
    await tester.tap(find.byKey(const Key('character-gender-tile')));
    await tester.pumpAndSettle();
    expect(find.text('Female'), findsOneWidget);
    expect(find.text('Male'), findsOneWidget);
    expect(find.text('Other'), findsAtLeastNWidgets(1));
    await tester.tap(find.byKey(const Key('character-gender-female')));
    await tester.pumpAndSettle();
    expect(character.positivePromptConfig.strs.single, 'girl, portrait');

    await tester.tap(find.byKey(const Key('character-gender-tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('character-gender-other')));
    await tester.pumpAndSettle();
    expect(character.positivePromptConfig.strs.single, 'portrait');
  });

  test('legacy character manager supports at most six characters', () {
    final viewmodel = PromptTabViewmodel(
      promptConfig: PromptConfig(strs: [], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [],
      savedConfigList: [],
      paramConfig: ParamConfig(model: 'nai-diffusion-4-5-full'),
    );

    for (var i = 0; i < 7; i++) {
      viewmodel.addCharacter();
    }

    expect(viewmodel.characterConfigList, hasLength(6));
  });

  testWidgets('character manager uses prompt title and numbered-only rows', (
    tester,
  ) async {
    final firstCharacter = CharacterConfig.fromEmpty();
    firstCharacter.positivePromptConfig.comment = 'Prompt';
    final secondCharacter = CharacterConfig.fromEmpty();
    secondCharacter.positivePromptConfig.comment = 'Custom title';
    final viewmodel = PromptTabViewmodel(
      promptConfig: PromptConfig(strs: [], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [firstCharacter, secondCharacter],
      savedConfigList: [],
      paramConfig: ParamConfig(),
    );

    await tester.pumpWidget(localizedApp(PromptTabView(viewmodel: viewmodel)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.group));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(
        of: dialog,
        matching: find.text('Manage Character Prompts'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('Character 1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('Character 2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('Character 1 Prompt')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.text('Character 2 Custom title'),
      ),
      findsNothing,
    );
  });

  testWidgets('configuration tabs keep their simplified order', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        ConfigPageView(viewmodel: ConfigPageViewmodel()),
      ),
    );
    await tester.pumpAndSettle();

    final labels = tester
        .widgetList<Tab>(find.byType(Tab))
        .map((tab) => tab.text)
        .toList();
    expect(
      labels,
      ['Prompt Config', 'Generation Parameters'],
    );
  });

  testWidgets(
      'run all combinations locks generation count to total combinations', (
    tester,
  ) async {
    final payloadConfig = GetIt.instance<PayloadConfig>();
    payloadConfig.rootPromptConfig = PromptConfig(
      type: 'config',
      selectionMethod: 'all',
      strs: [],
      prompts: [
        PromptConfig(
          selectionMethod: 'single',
          strs: ['tag1', 'tag2', 'tag3'], // 1: random is not exhaustive
          prompts: [],
        ),
        PromptConfig(
          selectionMethod: 'single',
          strs: ['style1', 'style2'], // 1: random is not exhaustive
          prompts: [],
        ),
      ],
    ); // Total = 1 * 1 = 1

    final viewmodel = GenerationPageViewmodel();
    expect(viewmodel.totalCombinations, 1);

    await tester.pumpWidget(
      localizedApp(
        Scaffold(
          body: GenerationSettingsView(viewmodel: viewmodel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Total combinations: 1'), findsOneWidget);
    expect(find.text('Run all combinations'), findsOneWidget);

    final checkboxFinder = find.byKey(
      const Key('generation-settings-lock-all-combinations'),
    );
    expect(checkboxFinder, findsOneWidget);

    // Tap to lock to all combinations
    await tester.tap(checkboxFinder);
    await tester.pumpAndSettle();

    expect(viewmodel.lockToAllCombinations, isTrue);
    expect(payloadConfig.settings.generationCount, 1);
    expect(
        find.descendant(
          of: find.byKey(const Key('generation-settings-count')),
          matching: find.text('1'),
        ),
        findsOneWidget);

    // Verify count tile is disabled
    final countTile = tester.widget<ListTile>(
      find.descendant(
        of: find.byKey(const Key('generation-settings-count')),
        matching: find.byType(ListTile),
      ),
    );
    expect(countTile.enabled, isFalse);

    // Tap to unlock
    await tester.tap(checkboxFinder);
    await tester.pumpAndSettle();

    expect(viewmodel.lockToAllCombinations, isFalse);
    expect(payloadConfig.settings.lockToAllCombinations, isFalse);
    final countTileUnlocked = tester.widget<ListTile>(
      find.descendant(
        of: find.byKey(const Key('generation-settings-count')),
        matching: find.byType(ListTile),
      ),
    );
    expect(countTileUnlocked.enabled, isTrue);
  });

  testWidgets('run all combinations memory state is restored from settings', (
    tester,
  ) async {
    final payloadConfig = GetIt.I<PayloadConfig>();
    payloadConfig.settings.lockToAllCombinations = true;
    payloadConfig.rootPromptConfig = PromptConfig(
      selectionMethod: 'all',
      strs: [],
      prompts: [
        PromptConfig(
          selectionMethod: 'single_sequential',
          strs: ['A', 'B', 'C'],
          prompts: [],
        ),
      ],
    );

    final viewmodel = _NoNetworkGenerationPageViewmodel();
    await tester.pumpWidget(
      localizedApp(
        Scaffold(
          body: GenerationSettingsView(viewmodel: viewmodel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(viewmodel.lockToAllCombinations, isTrue);
    final checkbox = tester.widget<CheckboxListTile>(
      find.byKey(const Key('generation-settings-lock-all-combinations')),
    );
    expect(checkbox.value, isTrue);
  });
  testWidgets(
      'oversized full cycle stays exact and does not start a truncated batch',
      (tester) async {
    final config = GetIt.I<PayloadConfig>();
    config.rootPromptConfig = PromptConfig(
        type: 'config',
        selectionMethod: 'all',
        strs: [],
        prompts: [
          PromptConfig(
              selectionMethod: 'single_sequential',
              num: 4000000000,
              strs: ['A'],
              prompts: []),
          PromptConfig(
              selectionMethod: 'single_sequential',
              num: 4000000001,
              strs: ['B'],
              prompts: []),
        ]);
    final viewmodel = _NoNetworkGenerationPageViewmodel();
    addTearDown(viewmodel.dispose);
    viewmodel.setLockToAllCombinations(true);
    await tester.pumpWidget(localizedApp(
        Scaffold(body: GenerationSettingsView(viewmodel: viewmodel))));
    await tester.pumpAndSettle();
    expect(find.textContaining('16000000004000000000'), findsWidgets);
    expect(find.textContaining('exceeds'), findsOneWidget);
    final originalCount = config.settings.generationCount;
    viewmodel.startGeneration();
    expect(config.settings.generationCount, originalCount);
    expect(viewmodel.commandStatus.isGenerationActive.value, isFalse);
    expect(viewmodel.commandList, isEmpty);
  });

  testWidgets(
      'locked count display refreshes from current settings without consuming sequence',
      (tester) async {
    final config = GetIt.I<PayloadConfig>();
    config.rootPromptConfig = PromptConfig(
        selectionMethod: 'single_sequential',
        strs: ['A', 'B', 'C'],
        prompts: []);
    final viewmodel = _NoNetworkGenerationPageViewmodel();
    addTearDown(viewmodel.dispose);
    viewmodel.setLockToAllCombinations(true);
    await tester.pumpWidget(localizedApp(
        Scaffold(body: GenerationSettingsView(viewmodel: viewmodel))));
    await tester.pumpAndSettle();
    config.rootPromptConfig.num = 2;
    config.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Total combinations: 6'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('generation-settings-count')),
            matching: find.text('6')),
        findsOneWidget);
    expect(config.rootPromptConfig.getPrmpts().toPrompt(), 'A');
    expect(config.rootPromptConfig.getPrmpts().toPrompt(), 'A');
  });
}
