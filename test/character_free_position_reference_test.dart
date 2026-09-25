import 'dart:convert';
import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      translations;
}

late Map<String, dynamic> testTranslations;

const _canvasKey = Key('character-free-canvas');
const _positionTileKey = Key('character-position-tile');

Widget _app(Widget home) {
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

PromptTabViewmodel _viewmodel(List<CharacterConfig> characters) {
  return PromptTabViewmodel(
    promptConfig: PromptConfig(strs: [], prompts: []),
    negativePromptConfig: PromptConfig(strs: [], prompts: []),
    characterConfigList: characters,
    savedConfigList: [],
    paramConfig: ParamConfig(
      model: 'nai-diffusion-5-full',
      autoPosition: false,
      sizes: const [GenerationSize(width: 1216, height: 832)],
    ),
  );
}

Future<void> _pumpPromptTab(
  WidgetTester tester,
  List<CharacterConfig> characters,
) async {
  await tester.binding.setSurfaceSize(const Size(1200, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester
      .pumpWidget(_app(PromptTabView(viewmodel: _viewmodel(characters))));
  await tester.pumpAndSettle();
}

Future<void> _openPositionDialog(WidgetTester tester, int index) async {
  final tile = find.byKey(_positionTileKey).at(index);
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

Future<void> _closeDialog(WidgetTester tester) async {
  await tester.tap(find.text('Confirm'));
  await tester.pumpAndSettle();
}

/// Center of the marker that carries [label] inside the free-position canvas.
Offset _markerCenter(WidgetTester tester, String label) {
  final marker =
      find.descendant(of: find.byKey(_canvasKey), matching: find.text(label));
  expect(marker, findsOneWidget);
  return tester.getCenter(marker);
}

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
        negativePromptConfig: PromptConfig(strs: [], prompts: []),
        characterConfigList: [],
        savedPromptConfigList: [],
        paramConfig: ParamConfig(
          sizes: const [GenerationSize(width: 832, height: 1216)],
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

  for (final imageSize in const [
    Size(1024, 1536),
    Size(1536, 1024),
    Size(1024, 1024),
    Size(256, 4096),
    Size(4096, 256)
  ]) {
    for (final windowSize in const [
      Size(1000, 700),
      Size(390, 700),
      Size(800, 450)
    ]) {
      testWidgets(
          'canvas $imageSize fits in $windowSize without dialog scrolling',
          (tester) async {
        final characters = [CharacterConfig.fromEmpty()];
        final vm = _viewmodel(characters);
        vm.paramConfig.sizes = [
          GenerationSize(
              width: imageSize.width.toInt(), height: imageSize.height.toInt())
        ];
        await tester.binding.setSurfaceSize(windowSize);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_app(PromptTabView(viewmodel: vm)));
        await tester.pumpAndSettle();
        await _openPositionDialog(tester, 0);
        final canvas = tester.getRect(find.byKey(_canvasKey));
        final dialog = tester.getRect(find.byType(AlertDialog));
        expect(canvas.top, greaterThanOrEqualTo(dialog.top));
        expect(canvas.bottom, lessThanOrEqualTo(dialog.bottom));
        expect(canvas.width / canvas.height,
            closeTo(imageSize.aspectRatio, 0.001));
        for (final state in tester.stateList<ScrollableState>(find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(Scrollable)))) {
          if (state.position.axis == Axis.vertical) {
            expect(state.position.maxScrollExtent, 0);
          }
        }
      });
    }
  }

  testWidgets('marks a character positioned after the cards were built',
      (tester) async {
    final characters = [
      // No explicit position of its own: nothing to mark on the canvas.
      CharacterConfig.fromEmpty()..positions = [],
      CharacterConfig.fromEmpty(),
      CharacterConfig.fromEmpty(),
    ];
    await _pumpPromptTab(tester, characters);

    // Place character 3 through its own canvas, exactly like a user drag. The
    // sibling cards are not rebuilt by that edit.
    await _openPositionDialog(tester, 2);
    final canvas = find.byKey(_canvasKey);
    final rect = tester.getRect(canvas);
    final gesture = await tester.startGesture(rect.topLeft);
    await gesture.moveTo(
      rect.topLeft + Offset(rect.width * 0.25, rect.height * 0.35),
    );
    await gesture.up();
    await tester.pump();
    expect(characters[2].freeCenter, isNotNull);
    await _closeDialog(tester);

    // Editing character 2 must show where character 3 now sits.
    await _openPositionDialog(tester, 1);
    final edited = tester.getRect(find.byKey(_canvasKey));
    final dot = _markerCenter(tester, '3');
    expect(dot.dx - edited.left, closeTo(edited.width * 0.25, 2));
    expect(dot.dy - edited.top, closeTo(edited.height * 0.35, 2));
    // Character 1 has no position of its own, so it stays unmarked.
    expect(
      find.descendant(of: find.byKey(_canvasKey), matching: find.text('1')),
      findsNothing,
    );
  });

  testWidgets('draws other characters as opaque readable markers',
      (tester) async {
    final characters = [
      CharacterConfig.fromEmpty()..freeCenter = const Point<double>(0.2, 0.3),
      CharacterConfig.fromEmpty(),
      CharacterConfig.fromEmpty()..freeCenter = const Point<double>(0.8, 0.7),
    ];
    await _pumpPromptTab(tester, characters);
    await _openPositionDialog(tester, 1);

    final marker =
        find.descendant(of: find.byKey(_canvasKey), matching: find.text('1'));
    final container = tester.widget<Container>(
      find.ancestor(of: marker, matching: find.byType(Container)).first,
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.color!.a, 1.0,
        reason: 'a translucent marker vanishes on the light canvas');
    expect(decoration.border!.top.color, isNot(Colors.white));
  });

  testWidgets('folds legacy grid positions of other characters into the canvas',
      (tester) async {
    final characters = [
      CharacterConfig.fromEmpty()..positions = [const Point<int>(1, 1)],
      CharacterConfig.fromEmpty(),
      CharacterConfig.fromEmpty()..freeCenter = const Point<double>(0.8, 0.2),
    ];
    await _pumpPromptTab(tester, characters);
    await _openPositionDialog(tester, 1);

    final canvas = tester.getRect(find.byKey(_canvasKey));
    final gridDot = _markerCenter(tester, '1');
    expect(
      gridDot.dx - canvas.left,
      closeTo(canvas.width * CharacterConfig.gridToNormalized[1]!, 2),
    );
    expect(
      gridDot.dy - canvas.top,
      closeTo(canvas.height * CharacterConfig.gridToNormalized[1]!, 2),
    );
    final freeDot = _markerCenter(tester, '3');
    expect(freeDot.dx - canvas.left, closeTo(canvas.width * 0.8, 2));
    expect(freeDot.dy - canvas.top, closeTo(canvas.height * 0.2, 2));
  });

  testWidgets('clicking a reference marker switches the draggable character',
      (tester) async {
    final characters = [
      CharacterConfig.fromEmpty()..freeCenter = const Point<double>(0.2, 0.3),
      CharacterConfig.fromEmpty()..freeCenter = const Point<double>(0.8, 0.7),
    ];
    await _pumpPromptTab(tester, characters);
    await _openPositionDialog(tester, 1);

    await tester.tap(find.byKey(const Key('character-free-marker-1')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('free-x-input')))
          .controller!
          .text,
      '0.200',
    );

    final canvas = tester.getRect(find.byKey(_canvasKey));
    final gesture = await tester.startGesture(canvas.topLeft);
    await gesture.moveTo(
      canvas.topLeft + Offset(canvas.width * 0.4, canvas.height * 0.6),
    );
    await gesture.up();
    await tester.pump();

    expect(characters[0].freeCenter!.x, closeTo(0.4, 0.02));
    expect(characters[0].freeCenter!.y, closeTo(0.6, 0.02));
    expect(characters[1].freeCenter, const Point<double>(0.8, 0.7));
  });
}
