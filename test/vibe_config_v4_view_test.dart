import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/ui/vibe_config_v4/viewmodels/vibe_config_v4_viewmodel.dart';
import 'package:nai_casrand/ui/vibe_config_v4/widgets/vibe_config_v4_view.dart';

import 'vibe_test_utils.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

void main() {
  late Map<String, dynamic> translations;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    translations = jsonDecode(
      await rootBundle.loadString('assets/l10n/en.json'),
    ) as Map<String, dynamic>;
  });

  Widget testApp(VibeConfigV4 config) {
    return EasyLocalization(
      key: UniqueKey(),
      supportedLocales: const [Locale('en')],
      path: 'test',
      assetLoader: _TestAssetLoader(translations),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      saveLocale: false,
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: Scaffold(
            body: SizedBox(
              width: 900,
              child: VibeConfigV4View(
                viewmodel: VibeConfigV4Viewmodel(
                  config: config,
                  model: 'nai-diffusion-4-5-full',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows both Vibe controls and pending extraction status',
      (tester) async {
    final config = VibeConfigV4(
      fileName: 'reference.png',
      imageBytes: makeTestPng(),
      referenceStrength: 0.6,
      informationExtracted: 0.7,
    );

    await tester.pumpWidget(testApp(config));
    await tester.pumpAndSettle();

    expect(find.textContaining('Reference Strength: 0.60'), findsOneWidget);
    expect(find.textContaining('Information Extracted: 0.70'), findsOneWidget);
    expect(
      find.text('Will be extracted when generation starts (2 Anlas)'),
      findsOneWidget,
    );
  });

  testWidgets('Information Extracted slider updates the config',
      (tester) async {
    final config = VibeConfigV4(
      fileName: 'reference.png',
      imageBytes: makeTestPng(),
      referenceStrength: 0.6,
      informationExtracted: 0.7,
    );

    await tester.pumpWidget(testApp(config));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(
      find.byKey(const Key('vibe-information-extracted-slider')),
    );
    slider.onChanged!(0.83);
    await tester.pump();

    expect(config.informationExtracted, 0.83);
    expect(find.textContaining('Information Extracted: 0.83'), findsOneWidget);
  });

  testWidgets('Information Extracted direct input uses its own current value',
      (tester) async {
    final config = VibeConfigV4(
      fileName: 'reference.png',
      imageBytes: makeTestPng(),
      referenceStrength: 0.2,
      informationExtracted: 0.7,
    );

    await tester.pumpWidget(testApp(config));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('vibe-information-extracted-edit')),
    );
    await tester.pumpAndSettle();

    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller!.text, '0.70');
    expect(find.textContaining('Information Extracted'), findsWidgets);

    await tester.enterText(find.byType(TextField), '0.55');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(config.informationExtracted, 0.55);
    expect(config.referenceStrength, 0.2);
  });

  testWidgets('shows ready status for a matching imported encoding',
      (tester) async {
    final config = VibeConfigV4(
      fileName: 'encoded.naiv4vibe',
      referenceStrength: 0.6,
      informationExtracted: 0.7,
    );
    config.cacheEncoding(
      model: 'nai-diffusion-4-5-full',
      informationExtracted: 0.7,
      encoding: 'encoded-vibe',
    );

    await tester.pumpWidget(testApp(config));
    await tester.pumpAndSettle();

    expect(
      find.text('Encoding ready for the current model and extraction value'),
      findsOneWidget,
    );
  });
}
