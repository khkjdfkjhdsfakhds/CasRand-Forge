import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/ui/generation_page/widgets/classic_info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';

late Map<String, dynamic> _translations;

class _Translations extends AssetLoader {
  const _Translations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      _translations;
}

Widget _app(Widget child) => EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'fixture',
      assetLoader: const _Translations(),
      startLocale: const Locale('en'),
      saveLocale: false,
      child: Builder(
          builder: (context) => MaterialApp(
                locale: context.locale,
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                home: Scaffold(
                    body: SizedBox(width: 600, height: 260, child: child)),
              )),
    );

InfoCardContent _content(String info) => InfoCardContent(
      title: 'Task 1',
      info: info,
      additionalInfo: const {},
      tokenLabel: 'Account B',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    _translations =
        jsonDecode(await rootBundle.loadString('assets/l10n/en.json'))
            as Map<String, dynamic>;
  });
  setUp(() async {
    await GetIt.I.reset();
    GetIt.I.registerSingleton(CommandStatus());
    GetIt.I.registerSingleton(PayloadConfig(
      rootPromptConfig: PromptConfig(strs: [], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(
          sizes: const [GenerationSize(width: 832, height: 1216)],
          randomSeed: false,
          seed: 42),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    ));
  });
  tearDown(() async {
    await GetIt.I.reset();
  });

  testWidgets('evicting a card detaches retry listeners and clears status',
      (tester) async {
    final status = GetIt.I<CommandStatus>();
    final original = Command.createAsyncNoParam(() async => _content('old'),
        initialValue: _content('old'));
    final retry = Command.createAsyncNoParam(() async => _content('done'),
        initialValue: _content('retry'));
    addTearDown(original.dispose);
    addTearDown(retry.dispose);
    status.setProgress(original, taskNumber: 1, totalTaskCount: 2);
    status.bindAttempt(original, retry);
    status.setOutcomeUnknown(original);
    status.removeProgress(original);
    expect(status.progressFor(original), isNull);
    expect(status.waitingFor(original), isNull);
    expect(status.outcomeUnknownFor(original), isNull);
    var notifications = 0;
    status.addListener(() {
      notifications++;
    });
    retry.execute();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(notifications, 0,
        reason: 'No retired attempt may retain the card binding.');
  });

  for (final classic in [true, false]) {
    Widget card(Command<void, InfoCardContent> command) => classic
        ? ClassicInfoCard(command: command)
        : InfoCard(command: command);
    testWidgets(
        '${classic ? 'classic' : 'waterfall'} error card identifies its account',
        (tester) async {
      final command = Command.createAsyncNoParam(() async => _content('failed'),
          initialValue: _content('failed'));
      addTearDown(command.dispose);
      await tester.pumpWidget(_app(card(command)));
      await tester.pumpAndSettle();
      expect(find.text('Account B'), findsOneWidget);
    });
    testWidgets(
        '${classic ? 'classic' : 'waterfall'} stable card follows its retry attempt',
        (tester) async {
      final status = GetIt.I<CommandStatus>();
      final original = Command.createAsyncNoParam(
          () async => _content('old failure'),
          initialValue: _content('old failure'));
      final result = Completer<InfoCardContent>();
      final retry = Command.createAsyncNoParam(() => result.future,
          initialValue: _content('preparing'));
      addTearDown(original.dispose);
      addTearDown(retry.dispose);
      await tester.pumpWidget(_app(card(original)));
      await tester.pumpAndSettle();
      status.bindAttempt(original, retry);
      retry.execute();
      await tester.pump(const Duration(milliseconds: 1));
      final showedLoading =
          find.byType(CircularProgressIndicator).evaluate().length;
      final showedOldError = find.text('old failure').evaluate().length;
      result.complete(_content('recovered'));
      await tester.pump(const Duration(milliseconds: 1));
      original.value = retry.value;
      status.unbindAttempt(original);
      await tester.pumpAndSettle();
      expect(showedLoading, 1);
      expect(showedOldError, 0);
      expect(find.text('recovered'), findsOneWidget);
      expect(find.text('Account B'), findsOneWidget);
    });
    testWidgets(
        '${classic ? 'classic' : 'waterfall'} wait and unknown states replace stale errors',
        (tester) async {
      final status = GetIt.I<CommandStatus>();
      final command = Command.createAsyncNoParam(
          () async => _content('old failure'),
          initialValue: _content('old failure'));
      addTearDown(command.dispose);
      await tester.pumpWidget(_app(card(command)));
      await tester.pumpAndSettle();
      status.setWaiting(command,
          retryAt: DateTime.now().add(const Duration(seconds: 60)),
          message: 'Rate limited');
      await tester.pump();
      expect(find.textContaining('Rate limited'), findsOneWidget);
      expect(find.textContaining('Retry in 60s'), findsOneWidget);
      expect(find.text('old failure'), findsNothing);
      expect(find.text('Account B'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.textContaining('Retry in 55s'), findsOneWidget);
      status.setOutcomeUnknown(command);
      await tester.pump();
      expect(
          find.text('Outcome unknown; automatic retry paused'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Account B'), findsOneWidget);
      status.clearState(command);
      await tester.pump();
    });
    testWidgets(
        '${classic ? 'classic' : 'waterfall'} card follows direct content changes',
        (tester) async {
      final command = Command.createAsyncNoParam(
          () async => _content('old failure'),
          initialValue: _content('old failure'));
      addTearDown(command.dispose);
      await tester.pumpWidget(_app(card(command)));
      await tester.pumpAndSettle();
      command.value = _content('new result');
      await tester.pump();
      expect(find.text('new result'), findsOneWidget);
      expect(find.text('old failure'), findsNothing);
    });
  }
}
