import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    final previewDivider = tester.getRect(
      find.byKey(const Key('prompt-preview-divider-0')),
    );
    final previewFirstEntry = tester.renderObject<RenderParagraph>(
      find.text('one'),
    );
    final previewSecondEntry = tester.renderObject<RenderParagraph>(
      find.text('# saved note'),
    );
    final previewFirstBox = previewFirstEntry
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 3),
        )
        .first;
    final previewSecondBox = previewSecondEntry
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 12),
        )
        .first;
    final expectedTopGap = previewDivider.center.dy -
        previewFirstEntry.localToGlobal(Offset(0, previewFirstBox.bottom)).dy;
    final expectedBottomGap =
        previewSecondEntry.localToGlobal(Offset(0, previewSecondBox.top)).dy -
            previewDivider.center.dy;
    await tester.tap(find.text('String Values: 1 items'));
    await tester.pumpAndSettle();

    expect(find.byType(PromptEntryEditor), findsOneWidget);
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final firstEntryCaret = editable.getLocalRectForCaret(
      const TextPosition(offset: 3, affinity: TextAffinity.upstream),
    );
    final secondEntryCaret = editable.getLocalRectForCaret(
      const TextPosition(offset: 4),
    );
    final editorDividerPaint =
        find.byKey(const Key('prompt-entry-divider-overlay'));
    final editorDivider = tester.renderObject<RenderBox>(editorDividerPaint);
    final dynamic editorDividerPainter =
        tester.widget<CustomPaint>(editorDividerPaint).painter;
    final dividerY = editorDivider
        .localToGlobal(
          Offset(
            0,
            editorDividerPainter.debugDividerYPositions.first as double,
          ),
        )
        .dy;
    final firstEntryBottom = editable
        .localToGlobal(
          firstEntryCaret.bottomLeft,
        )
        .dy;
    final secondEntryTop = editable
        .localToGlobal(
          secondEntryCaret.topLeft,
        )
        .dy;

    final actualTopGap = dividerY - firstEntryBottom;
    final actualBottomGap = secondEntryTop - dividerY;
    expect(actualTopGap, closeTo(expectedTopGap, 0.5));
    expect(actualBottomGap, closeTo(expectedBottomGap, 0.5));
    await tester.enterText(
      find.byKey(const Key('prompt-entry-editor')),
      'first\nsecond\n# saved note',
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
