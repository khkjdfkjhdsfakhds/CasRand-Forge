import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/ui/core/widgets/editable_list_tile.dart';
import 'package:nai_casrand/ui/prompt_config/view_models/prompt_config_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_config_edit_view.dart';

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

  testWidgets('prompt config editor keeps its controls easy to click', (
    tester,
  ) async {
    final viewModel = PromptConfigViewModel(
      config: PromptConfig(
        comment: 'Unnamed config',
        selectionMethod: 'single_sequential',
        num: 3,
        strs: ['first', 'second'],
        prompts: [],
      ),
    );

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
            home: Scaffold(body: PromptConfigEditView(viewModel: viewModel)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EditableListTile), findsOneWidget);
    expect(find.text('Repeat Number'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    final titleTarget = find.byKey(const Key('prompt-config-title-edit'));
    final targetRect = tester.getRect(titleTarget);
    expect(targetRect.height, greaterThanOrEqualTo(kMinInteractiveDimension));
    expect(targetRect.width, greaterThan(300));

    await tester.tapAt(Offset(targetRect.right - 8, targetRect.center.dy));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
  });
}
