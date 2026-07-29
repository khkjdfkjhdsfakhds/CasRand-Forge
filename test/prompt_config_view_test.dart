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
}
