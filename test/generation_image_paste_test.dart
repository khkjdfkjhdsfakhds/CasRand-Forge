import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_image_paste_area.dart';
import 'package:nai_casrand/ui/navigation/view_models/metadata_drop_area_viewmodel.dart';
import 'package:nai_casrand/ui/navigation/widgets/image_import_dialog.dart';

class _Translations extends AssetLoader {
  final Map<String, dynamic> values;
  const _Translations(this.values);
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => values;
}

void main() {
  late Map<String, dynamic> translations;
  late MetadataDropAreaViewmodel imports;
  late ImageImportCandidate image;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/shared_preferences'),
            (call) async =>
                call.method == 'getAll' ? <String, Object>{} : true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': 'hello'};
      }
      return null;
    });
    await EasyLocalization.ensureInitialized();
    translations =
        jsonDecode(await rootBundle.loadString('assets/l10n/en.json'))
            as Map<String, dynamic>;
  });
  setUp(() {
    imports = MetadataDropAreaViewmodel(
        payloadConfig: PayloadConfig(
            rootPromptConfig: PromptConfig(strs: [], prompts: []),
            negativePromptConfig: PromptConfig(strs: [], prompts: []),
            characterConfigList: [],
            savedPromptConfigList: [],
            overridePrompt: '',
            useOverridePrompt: false,
            useCharacterPromptWithOverride: false,
            paramConfig: ParamConfig(model: 'nai-diffusion-5-full'),
            settings: Settings.fromJson({})));
    image = ImageImportCandidate(
        bytes:
            Uint8List.fromList(img.encodePng(img.Image(width: 96, height: 64))),
        fileName: 'test.png');
  });
  tearDown(() => imports.dispose());
  Future<void> host(WidgetTester tester, ClipboardImageReader reader,
      {TextEditingController? controller,
      ImageMetadataExtractor? metadata,
      bool ignoreWhenTextEditing = false}) async {
    await tester.pumpWidget(EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'unused',
        saveLocale: false,
        assetLoader: _Translations(translations),
        child: Builder(
            builder: (context) => MaterialApp(
                locale: context.locale,
                supportedLocales: context.supportedLocales,
                localizationsDelegates: context.localizationDelegates,
                home: GenerationImagePasteArea(
                    clipboardReader: reader,
                    importViewmodel: imports,
                    metadataExtractor: metadata ?? (_) async => null,
                    ignoreWhenTextEditing: ignoreWhenTextEditing,
                    child: Scaffold(
                        body: Column(children: [
                      TextField(controller: controller),
                      Builder(
                          builder: (context) => TextButton(
                              onPressed: () => showDialog<void>(
                                  context: context,
                                  builder: (_) => const AlertDialog(
                                      content: Text('another modal'))),
                              child: const Text('modal'))),
                    ])))))));
    await tester.pumpAndSettle();
  }

  Future<void> paste(WidgetTester tester, {bool control = false}) async {
    final modifier =
        control ? LogicalKeyboardKey.controlLeft : LogicalKeyboardKey.metaLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  Future<void> waitDialog(WidgetTester tester) async {
    for (var i = 0;
        i < 40 && find.byType(ImageImportDialog).evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    expect(find.byType(ImageImportDialog), findsOneWidget);
  }

  testWidgets(
      'Cmd+V and Ctrl+V open the shared import chooser once, with async metadata',
      (tester) async {
    var reads = 0;
    final read = Completer<ImageImportCandidate?>();
    final metadata = Completer<String?>();
    await host(tester, () {
      reads++;
      return read.future;
    }, metadata: (_) => metadata.future);
    await paste(tester);
    await paste(tester, control: true);
    expect(find.byKey(const Key('generation-paste-loading')), findsOneWidget);
    expect(reads, 1);
    read.complete(image);
    metadata.complete(null);
    await waitDialog(tester);
    expect(find.byKey(const Key('image-import-preview')), findsOneWidget);
    expect(find.byKey(const Key('image-import-enhance')), findsOneWidget);
    expect(find.byKey(const Key('image-import-director')), findsOneWidget);
    await paste(tester);
    expect(reads, 1);
    await tester.pumpAndSettle();
    expect(imports.payloadConfig.i2iConfig.hasImage, isFalse);
    Navigator.of(tester.element(find.byType(ImageImportDialog))).pop();
    await tester.pumpAndSettle();
    await paste(tester, control: true);
    await waitDialog(tester);
    expect(reads, 2);
  });

  testWidgets('text paste still replaces the active selection in a text field',
      (tester) async {
    final controller = TextEditingController(text: 'before after');
    addTearDown(controller.dispose);
    await host(tester, () async => null, controller: controller);
    await tester.tap(find.byType(TextField));
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
    await Clipboard.setData(const ClipboardData(text: 'hello'));
    await paste(tester);
    await tester.pumpAndSettle();
    expect(controller.text, 'hello after');
    expect(find.byType(ImageImportDialog), findsNothing);
  });

  testWidgets('image clipboard wins over text focus without changing text',
      (tester) async {
    final controller = TextEditingController(text: 'keep this');
    addTearDown(controller.dispose);
    await host(tester, () async => image, controller: controller);
    await tester.tap(find.byType(TextField));
    await Clipboard.setData(const ClipboardData(text: '/path/from/image'));
    await paste(tester);
    await waitDialog(tester);
    expect(controller.text, 'keep this');
  });

  testWidgets(
      'ignoreWhenTextEditing: true ignores image clipboard when text is focused',
      (tester) async {
    var reads = 0;
    final controller = TextEditingController(text: 'keep this');
    addTearDown(controller.dispose);
    await host(
      tester,
      () async {
        reads++;
        return image;
      },
      controller: controller,
      ignoreWhenTextEditing: true,
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await paste(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(reads, 0);
    expect(find.byType(ImageImportDialog), findsNothing);
  });

  testWidgets('other modal and an unmounted page do not consume image paste',
      (tester) async {
    var reads = 0;
    await host(tester, () async {
      reads++;
      return image;
    });
    await tester.tap(find.text('modal'));
    await tester.pumpAndSettle();
    await paste(tester);
    expect(reads, 0);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pumpAndSettle();
    await paste(tester);
    expect(reads, 0);
  });

  testWidgets(
      'pending clipboard result is discarded after leaving the generation page',
      (tester) async {
    final read = Completer<ImageImportCandidate?>();
    await host(tester, () => read.future);
    await paste(tester);
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('other page'))));
    read.complete(image);
    await tester.pumpAndSettle();
    expect(find.byType(ImageImportDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read failure is visible and permits retry', (tester) async {
    var fails = true;
    await host(tester, () async {
      if (fails) throw StateError('clipboard read failed');
      return image;
    });
    await paste(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(translations['image_import_action_failed'] as String),
        findsWidgets);
    fails = false;
    await paste(tester);
    await waitDialog(tester);
  });
}
