import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/ui/prompt_config/view_models/prompt_config_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_config_view.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_entry_editor.dart';

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

  testWidgets('cascaded string dialog saves structured entries and true count',
      (
    tester,
  ) async {
    final config = PromptConfig(
      shuffled: false,
      strs: const ['one', '# saved note'],
      prompts: [],
    );
    final viewModel = PromptConfigViewModel(config: config);

    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/l10n',
        fallbackLocale: const Locale('en'),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(
              body: PromptConfigView(viewModel: viewModel),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('String Values: 1 items'), findsOneWidget);
    expect(find.text('one'), findsOneWidget);
    expect(find.text('# saved note'), findsOneWidget);
    expect(
      find.byKey(const Key('prompt-preview-divider-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('prompt-preview-divider-1')),
      findsNothing,
    );
    await tester.tap(find.text('String Values: 1 items'));
    await tester.pumpAndSettle();

    expect(find.byType(PromptEntryEditor), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('prompt-entry-field-0')),
      'first\nsecond',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(config.strs, ['first', 'second', '# saved note']);
    expect(find.text('String Values: 2 items'), findsOneWidget);
  });

  testWidgets('prompt editor uses the phone dialog for editing content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AlertDialog(
            content: SizedBox(
              width: 262,
              height: 624,
              child: PromptEntryEditor(
                initialEntries: const ['one'],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const Key('prompt-entry-help')), findsNothing);
    expect(find.byKey(const Key('insert-prompt-line-break')), findsNothing);
    expect(find.byKey(const Key('next-prompt-entry')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
