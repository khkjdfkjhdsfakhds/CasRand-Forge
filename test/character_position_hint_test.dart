import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/ui/character_config/view_models/character_config_viewmodel.dart';
import 'package:nai_casrand/ui/character_config/widgets/character_config_view.dart';

class _Loader extends AssetLoader {
  _Loader(this.words);
  final Map<String, dynamic> words;
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => words;
}

const _words = <String, dynamic>{
  'auto_position': 'AI choice',
  'character_position': 'Position',
};

CharacterConfigViewmodel _viewmodel(CharacterConfig config) =>
    CharacterConfigViewmodel(
      config: config,
      paramConfig: ParamConfig(
        model: 'nai-diffusion-4-5-full',
        autoPosition: false,
      ),
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'fixture',
    assetLoader: _Loader(_words),
    startLocale: const Locale('en'),
    saveLocale: false,
    child: Builder(
      builder: (context) => MaterialApp(
        locale: context.locale,
        supportedLocales: context.supportedLocales,
        localizationsDelegates: context.localizationDelegates,
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  ));
  await tester.pumpAndSettle();
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
  });

  testWidgets('marks the grid cells other characters occupy', (tester) async {
    final first = CharacterConfig.fromEmpty()
      ..positions = [const Point(1, 5)];
    final second = CharacterConfig.fromEmpty()
      ..positions = [const Point(3, 3)];
    final edited = CharacterConfig.fromEmpty()
      ..positions = [const Point(3, 3)];

    await _pump(
      tester,
      CharacterPositionView(
        viewmodel: _viewmodel(edited),
        allCharacters: [first, second, edited],
        characterIndex: 2,
      ),
    );

    expect(find.text('A5\n#1'), findsOneWidget);
    expect(find.text('C3\n#2'), findsOneWidget);
    // The edited character is never listed among the markers.
    expect(find.text('C3\n#3'), findsNothing);
  });

  testWidgets('folds a V5 free point into the cell it maps to',
      (tester) async {
    final free = CharacterConfig.fromEmpty()
      ..positions = []
      ..freeCenter = const Point<double>(0.9, 0.9);
    final edited = CharacterConfig.fromEmpty();

    await _pump(
      tester,
      CharacterPositionView(
        viewmodel: _viewmodel(edited),
        allCharacters: [free, edited],
        characterIndex: 1,
      ),
    );

    expect(find.text('E5\n#1'), findsOneWidget);
  });

  testWidgets('does not invent a C3 marker for characters without a position',
      (tester) async {
    final empty = CharacterConfig.fromEmpty()
      ..positions = []
      ..freeCenter = null;
    final edited = CharacterConfig.fromEmpty();

    await _pump(
      tester,
      CharacterPositionView(
        viewmodel: _viewmodel(edited),
        allCharacters: [empty, edited],
        characterIndex: 1,
      ),
    );

    expect(find.textContaining('#1'), findsNothing);
    // The edited character still shows its own filled-in default cell.
    expect(find.text('C3'), findsOneWidget);
  });
}
