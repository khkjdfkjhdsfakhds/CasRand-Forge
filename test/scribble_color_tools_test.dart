import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/scribble_document.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/scribble_color_picker.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/scribble_editor_view.dart';

class _Translations extends AssetLoader {
  final Map<String, dynamic> values;
  const _Translations(this.values);
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => values;
}

Uint8List sourcePng({int alpha = 255}) {
  final image = img.Image(width: 96, height: 64, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(20, 80, 160, alpha));
  return Uint8List.fromList(img.encodePng(image));
}

Future<void> finishAsync(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue, reason: 'Native image work should finish');
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, String name) async {
  final dir = Platform.environment['CASRAND_QA_DIR'];
  if (dir == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('qa')));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  late Map<String, dynamic> translations;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true);
    await EasyLocalization.ensureInitialized();
    translations = jsonDecode(await rootBundle.loadString('assets/l10n/zh-CN.json')) as Map<String, dynamic>;
  });

  Future<void> host(WidgetTester tester, WidgetBuilder builder, {Size size = const Size(1000, 760)}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(EasyLocalization(supportedLocales: const [Locale('zh', 'CN')],
      path: 'unused', saveLocale: false, assetLoader: _Translations(translations),
      child: Builder(builder: (context) => RepaintBoundary(key: const Key('qa'), child: MaterialApp(
        theme: ThemeData(colorSchemeSeed: Colors.pink), locale: context.locale,
        supportedLocales: context.supportedLocales, localizationsDelegates: context.localizationDelegates,
        home: Builder(builder: builder))))));
    await tester.pumpAndSettle();
  }

  test('eyedropper equals full-resolution composite including alpha and erasure', () async {
    for (final alpha in [255, 128, 0]) {
      final document = ScribbleDocument(originalBytes: sourcePng(alpha: alpha), width: 96, height: 64, strokes: [
        ScribbleStroke(points: const [Offset(10, 20), Offset(80, 20)], color: const Color(0x80ff2000), width: 18),
        ScribbleStroke(points: const [Offset(45, 20)], color: Colors.black, width: 12, erase: true),
      ]);
      final rendered = img.decodePng(await renderScribbleDocument(document))!;
      for (final point in [const Offset(20, 20), const Offset(45, 20), const Offset(90, 60), const Offset(10, 11)]) {
        final actual = await sampleScribbleColor(document, point);
        final expected = rendered.getPixel(point.dx.toInt(), point.dy.toInt());
        final argb = actual!.toARGB32();
        expect((argb >> 24) & 255, closeTo(expected.a, 1));
        if (expected.a > 0) {
          expect((argb >> 16) & 255, closeTo(expected.r, 1));
          expect((argb >> 8) & 255, closeTo(expected.g, 1));
          expect(argb & 255, closeTo(expected.b, 1));
        }
      }
      expect(await sampleScribbleColor(document, const Offset(-1, 0)), isNull);
      expect(await sampleScribbleColor(document, const Offset(96, 64)), isNull);
    }
  });

  testWidgets('color plane, hue, alpha and HEX produce the chosen color at narrow width', (tester) async {
    Color? selected;
    await host(tester, (context) => Scaffold(body: TextButton(onPressed: () async {
      selected = await showDialog<Color>(context: context, builder: (_) => const ScribbleColorPicker(initial: Colors.black));
    }, child: const Text('open'))), size: const Size(360, 800));
    await tester.tap(find.text('open')); await tester.pumpAndSettle();
    final plane = tester.getRect(find.byKey(const Key('scribble-color-plane')));
    await tester.tapAt(plane.topRight - const Offset(1, -1));
    await tester.pump();
    final hue = tester.widget<Slider>(find.byKey(const Key('scribble-hue')));
    hue.onChanged!(.5); await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('scribble-hex'))).controller!.text, startsWith('0'));
    tester.widget<Slider>(find.byKey(const Key('scribble-alpha'))).onChanged!(.4);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('scribble-hex')), '#3366CC'); await tester.pump();
    await capture(tester, 'color-picker-narrow');
    await tester.tap(find.byKey(const Key('scribble-color-confirm'))); await tester.pumpAndSettle();
    expect(selected!.toARGB32(), 0x663366cc);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid HEX cannot confirm and cancel leaves the color unchanged', (tester) async {
    Color? selected;
    await host(tester, (context) => Scaffold(body: TextButton(onPressed: () async {
      selected = await showDialog<Color>(context: context, builder: (_) => const ScribbleColorPicker(initial: Colors.green));
    }, child: const Text('open'))));
    await tester.tap(find.text('open')); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scribble-hex')), 'hello'); await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('scribble-color-confirm'))).onPressed, isNull);
    await tester.tap(find.text('取消')); await tester.pumpAndSettle();
    expect(selected, isNull);
  });

  testWidgets('picker samples without a stroke, returns to brush and preserves undo', (tester) async {
    ScribbleEditorResult? result;
    final original = sourcePng();
    await host(tester, (context) => Scaffold(body: TextButton(onPressed: () async {
      result = await ScribbleEditorView.open(context, document: ScribbleDocument(originalBytes: original, width: 96, height: 64));
    }, child: const Text('open'))));
    await tester.tap(find.text('open')); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scribble-picker'))); await tester.pump();
    await tester.tap(find.byKey(const Key('scribble-canvas'))); await tester.pump();
    expect(find.byKey(const Key('scribble-sampling')), findsOneWidget);
    await finishAsync(tester, () => find.byKey(const Key('scribble-sampling')).evaluate().isEmpty);
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('scribble-brush'))).selected, isTrue);
    expect(tester.widget<IconButton>(find.byKey(const Key('scribble-undo'))).onPressed, isNull);
    expect(find.textContaining('#1450A0'), findsOneWidget);
    await tester.tap(find.byKey(const Key('scribble-canvas'))); await tester.pump();
    await capture(tester, 'editor');
    await tester.tap(find.byKey(const Key('scribble-undo'))); await tester.pump();
    await tester.tap(find.byKey(const Key('scribble-redo'))); await tester.pump();
    await tester.tap(find.byKey(const Key('scribble-save'))); await tester.pump();
    await finishAsync(tester, () => result != null);
    expect(result!.document.strokes, hasLength(1));
    expect(result!.document.strokes.single.color.toARGB32(), 0xff1450a0);
  });

  testWidgets('Ctrl click temporarily picks from erased artwork without changing the eraser', (tester) async {
    await host(tester, (_) => ScribbleEditorView(document: ScribbleDocument(originalBytes: sourcePng(), width: 96, height: 64)));
    await tester.tap(find.byKey(const Key('scribble-canvas'))); await tester.pump();
    await tester.tap(find.byKey(const Key('scribble-eraser'))); await tester.pump();
    await tester.tap(find.byKey(const Key('scribble-canvas'))); await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.byKey(const Key('scribble-canvas')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft); await tester.pump();
    await finishAsync(tester, () => find.byKey(const Key('scribble-sampling')).evaluate().isEmpty);
    expect(find.textContaining('#1450A0'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('scribble-eraser'))).selected, isTrue);
    await tester.tap(find.byKey(const Key('scribble-clear'))); await tester.pump();
    await tester.tap(find.byKey(const Key('scribble-undo'))); await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(const Key('scribble-clear'))).onPressed, isNotNull);
  });
}
