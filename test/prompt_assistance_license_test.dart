import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/core/licenses/prompt_assistance_license.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(LicenseRegistry.reset);

  test('registers Danbooru attribution for the About licenses page', () async {
    registerPromptAssistanceLicense();

    final entries = await LicenseRegistry.licenses
        .where(
          (entry) => entry.packages.contains(promptAssistanceLicensePackage),
        )
        .toList();

    expect(entries, hasLength(1));
    final text = entries.single.paragraphs.map((paragraph) => paragraph.text);
    final notice = text.join('\n\n');
    expect(notice, contains('DominikDoom/a1111-sd-webui-tagcomplete'));
    expect(notice, contains('4170882f90b47be130a0ff9314f663c230b9153d'));
    expect(notice, contains('Permission is hereby granted'));
    expect(notice, contains('THE SOFTWARE IS PROVIDED "AS IS"'));
  });

  testWidgets('About dialog opens the registered Danbooru license',
      (tester) async {
    registerPromptAssistanceLicense();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAboutDialog(
              context: context,
              applicationName: 'CasRand Forge',
              applicationVersion: '0.9.5',
            ),
            child: const Text('about'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('about'));
    await tester.pumpAndSettle();

    final licensesButton = find.byWidgetPredicate(
      (widget) =>
          widget is TextButton &&
          widget.child is Text &&
          ((widget.child! as Text).data?.toLowerCase().contains('license') ??
              false),
    );
    expect(licensesButton, findsOneWidget);
    await tester.tap(licensesButton);
    await tester.pumpAndSettle();

    expect(find.textContaining(promptAssistanceLicensePackage), findsOneWidget);
  });
}
