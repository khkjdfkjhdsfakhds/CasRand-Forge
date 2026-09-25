import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:nai_casrand/core/constants/parameters.dart' as parameters;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/prompt_token_snapshot.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/prompt_token_usage.dart';

Map<String, dynamic> metadata(String model, String prompt) => {
      'model': model,
      'input': prompt,
      'negative_prompt': 'bad',
    };

void main() {
  test('metadata preserves rendered text and aligns asymmetric character lists',
      () {
    for (final model in [
      ...parameters.models,
      ...parameters.inpaintModelMapping.values
    ]) {
      expect(
          PromptTokenSnapshot.fromMetadata(metadata(model, 'a'))?.model, model);
    }
    final snapshot = PromptTokenSnapshot.fromMetadata({
      ...metadata('nai-diffusion-5-full', 'fallback'),
      'v4_prompt': const {
        'caption': {
          'base_caption': 'actual teXt:hello',
          'char_captions': [
            {'char_caption': 'character prompt'}
          ]
        }
      },
    })!;
    expect(
        snapshot.texts, ['actual teXt:hello', 'character prompt', 'bad', '']);
    expect(PromptTokenSnapshot.fromMetadata({'model': 'unknown', 'input': 'a'}),
        isNull);
    expect(PromptTokenSnapshot.fromMetadata({'model': 'nai-diffusion-5-full'}),
        isNull);
    expect(
        PromptTokenSnapshot.fromMetadata(
            {...metadata('nai-diffusion-5-full', 'a'), 'req_type': 'colorize'}),
        isNull);
    expect(
        PromptTokenSnapshot.fromMetadata({
          ...metadata('nai-diffusion-5-full', 'a'),
          'v4_prompt': const {
            'caption': {
              'char_captions': [42]
            }
          }
        }),
        isNull);
  });

  testWidgets('gallery counts viewed image and discards previous late result',
      (tester) async {
    final requests = <Completer<List<int>>>[];
    final texts = <List<String>>[];
    await tester.pumpWidget(MaterialApp(
        home: InfoDetailPage.gallery(
      contents: [
        InfoCardContent(
            title: 'first',
            info: '',
            additionalInfo: metadata('nai-diffusion-5-full', 'first image')),
        InfoCardContent(
            title: 'second',
            info: '',
            additionalInfo:
                metadata('nai-diffusion-5-curated', 'second image')),
      ],
      initialIndex: 0,
      tokenCounter: (model, text) {
        texts.add(text);
        final result = Completer<List<int>>();
        requests.add(result);
        return result.future;
      },
    )));
    expect(requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    expect(texts.single, ['first image', 'bad']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(texts.last, ['second image', 'bad']);
    requests[1].complete([7, 3]);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byKey(const Key('prompt-token-positive-fill')))
            .value,
        7 / 703);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byKey(const Key('prompt-token-negative-fill')))
            .value,
        3 / 703);
    await tester.tap(find.byKey(const Key('prompt-token-positive')));
    await tester.pumpAndSettle();
    expect(find.textContaining('7/703'), findsOneWidget);
    requests[0].complete([900, 800]);
    await tester.pumpAndSettle();
    expect(find.textContaining('900'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('missing metadata has no invented editor count', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PromptTokenUsage(
      metadata: const {},
      counter: (_, __) async {
        calls++;
        return [0, 0];
      },
    ))));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('failure can retry and narrow character details fit',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: PromptTokenUsage(
      metadata: metadata('nai-diffusion-5-full', 'a'),
      counter: (_, __) async {
        if (++calls == 1) throw StateError('unavailable');
        return [2, 1];
      },
    )))));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(
        tester
            .widgetList<Tooltip>(find.byType(Tooltip))
            .every((t) => t.message!.contains('prompt_tokens_failed')),
        isTrue);
    await tester.tap(find.byKey(const Key('prompt-token-positive')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(calls, 2);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byKey(const Key('prompt-token-positive-fill')))
            .value,
        2 / 1471);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'slim bars show role details on hover, preserve totals and clamp overflow',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PromptTokenUsage(
      metadata: {
        ...metadata('nai-diffusion-5-full', 'a'),
        'v4_prompt': const {
          'caption': {
            'base_caption': 'a',
            'char_captions': [
              {'char_caption': 'b'}
            ]
          }
        },
      },
      counter: (_, __) async => [1500, 20, 1, 0],
    ))));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    final bar = find.byKey(const Key('prompt-token-positive-fill'));
    expect(tester.getSize(bar).height, 4);
    expect(tester.widget<LinearProgressIndicator>(bar).value, 1);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(bar));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.textContaining('1520/1471'), findsOneWidget);
    expect(find.textContaining('prompt_tokens_character: 20'), findsOneWidget);
    await gesture.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
