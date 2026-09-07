import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_token_snapshot.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/prompt_token_usage.dart';
import 'nai5_selected_compatibility_test.dart' show configFor;

void main() {
  testWidgets('debounce, separate budgets and late model result discard',
      (tester) async {
    final config = configFor('nai-diffusion-5-full')
      ..promptMode = PromptMode.fixed;
    config.paramConfig.model = 'nai-diffusion-5-full';
    final requests = <Completer<List<int>>>[];
    Future<List<int>> count(String model, List<String> text) {
      final result = Completer<List<int>>();
      requests.add(result);
      return result.future;
    }

    Future<void> show() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: PromptTokenUsage(config: config, counter: count))));
      await tester.pump();
    }

    await show();
    expect(requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    expect(requests, hasLength(1));
    config.paramConfig.model = 'nai-diffusion-5-curated';
    await show();
    await tester.pump(const Duration(milliseconds: 200));
    expect(requests, hasLength(2));
    requests[1].complete([7, 3]);
    await tester.pumpAndSettle();
    expect(find.textContaining('7/703'), findsOneWidget);
    expect(find.textContaining('3/703'), findsOneWidget);
    requests[0].complete([900, 800]);
    await tester.pumpAndSettle();
    expect(find.textContaining('900'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('random without task never loads tokenizer', (tester) async {
    final config = configFor('nai-diffusion-5-full');
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PromptTokenUsage(
                config: config,
                snapshots: PromptTokenSnapshots(),
                counter: (_, __) async {
                  calls++;
                  return [0, 0];
                }))));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
    expect(find.text('prompt_tokens_after_generation'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('load failure remains local and retry updates count',
      (tester) async {
    final config = configFor('nai-diffusion-5-full')
      ..promptMode = PromptMode.fixed;
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: PromptTokenUsage(
                    config: config,
                    counter: (_, __) async {
                      if (++calls == 1) throw StateError('unavailable');
                      return [2, 1];
                    })))));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('prompt_tokens_failed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('prompt-token-usage')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt_tokens_retry'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(calls, 2);
    expect(find.textContaining('2/1471'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
