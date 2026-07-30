import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/navigation/widgets/navigation_appbar.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

void main() {
  late Map<String, dynamic> testTranslations;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    final source = await rootBundle.loadString('assets/l10n/en.json');
    testTranslations = jsonDecode(source) as Map<String, dynamic>;
  });

  setUp(() async {
    await GetIt.I.reset();
    GetIt.I.registerSingleton(CommandStatus());
    final configService = ConfigService()
      ..packageInfo = PackageInfo(
        appName: 'NAI CasRand Forge',
        packageName: 'nai_casrand',
        version: '0.9.5',
        buildNumber: '59',
      );
    GetIt.I.registerSingleton<ConfigService>(configService);
  });

  tearDown(() async {
    await GetIt.I.reset();
  });

  Widget localizedApp({
    required VoidCallback onRestore,
    Widget? body,
  }) {
    return EasyLocalization(
      key: UniqueKey(),
      supportedLocales: const [Locale('en')],
      path: 'test',
      assetLoader: _TestAssetLoader(testTranslations),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      saveLocale: false,
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: Scaffold(
            appBar: body == null
                ? NavigationAppBar(
                    onRestoreWelcomeMessage: onRestore,
                  )
                : null,
            body: body,
          ),
        ),
      ),
    );
  }

  testWidgets('help dialog orders GitHub, Cyber Merit, then welcome restore', (
    tester,
  ) async {
    var restoreCount = 0;
    await tester.pumpWidget(
      localizedApp(onRestore: () => restoreCount++),
    );
    await tester.pumpAndSettle();

    expect(find.text('NAI CasRand Forge'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-help-button')));
    await tester.pumpAndSettle();

    expect(find.text('NAI CasRand Forge'), findsNWidgets(2));
    expect(find.text('0.9.5'), findsOneWidget);
    expect(
      find.text('https://github.com/khkjdfkjhdsfakhds/CasRand-Forge'),
      findsOneWidget,
    );
    expect(find.text('Cyber Merit'), findsOneWidget);
    expect(find.text('☕️ Buy the author a coffee..'), findsOneWidget);
    expect(find.byKey(const Key('restore-welcome-message')), findsOneWidget);
    expect(find.text('Show welcome message again'), findsOneWidget);

    final githubY = tester.getTopLeft(find.text('GitHub Repository')).dy;
    final donationY = tester.getTopLeft(find.text('Cyber Merit')).dy;
    final restoreY =
        tester.getTopLeft(find.text('Show welcome message again')).dy;
    expect(githubY, lessThan(donationY));
    expect(donationY, lessThan(restoreY));

    await tester.tap(find.byKey(const Key('restore-welcome-message')));
    await tester.pumpAndSettle();

    expect(restoreCount, 1);
    expect(find.byKey(const Key('restore-welcome-message')), findsNothing);
  });

  Finder assetImage(String path) => find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName == path,
      );

  testWidgets('header keeps 0.9.1 content without a colored strip', (
    tester,
  ) async {
    await tester.pumpWidget(localizedApp(onRestore: () {}));
    await tester.pumpAndSettle();

    final appBarFinder = find.byType(AppBar);
    final appBar = tester.widget<AppBar>(appBarFinder);
    final context = tester.element(appBarFinder);
    final icon = assetImage('assets/appicon.png');

    expect(appBar.preferredSize.height, kToolbarHeight);
    expect(appBar.backgroundColor, Theme.of(context).colorScheme.surface);
    expect(appBar.surfaceTintColor, Colors.transparent);
    expect(appBar.shadowColor, Colors.transparent);
    expect(appBar.elevation, 0);
    expect(appBar.scrolledUnderElevation, 0);
    expect(find.text('NAI CasRand Forge'), findsOneWidget);
    expect(find.byKey(const Key('app-help-button')), findsOneWidget);
    expect(tester.getSize(icon).height, 40);
  });

  testWidgets('generation status stays inside the restored header', (
    tester,
  ) async {
    await tester.pumpWidget(localizedApp(onRestore: () {}));
    await tester.pumpAndSettle();

    final commandStatus = GetIt.I<CommandStatus>();
    commandStatus.isGenerationActive.value = true;
    await tester.pump();
    expect(find.text('Generating images...'), findsOneWidget);

    commandStatus.isWaitingForNextGeneration.value = true;
    await tester.pump();
    expect(
      find.text('Waiting before the next image to reduce 429 errors...'),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('navigation-app-bar'))).height,
      kToolbarHeight,
    );
  });

  Future<void> openDonationDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('app-help-button')));
    await tester.pumpAndSettle();
    final donationTile = find.widgetWithText(ListTile, 'Cyber Merit');
    await tester.ensureVisible(donationTile);
    await tester.pumpAndSettle();
    await tester.tap(donationTile);
    await tester.pumpAndSettle();
  }

  testWidgets('donation codes are aligned and fully contained on wide screens',
      (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(localizedApp(onRestore: () {}));
    await tester.pumpAndSettle();

    await openDonationDialog(tester);

    final wechat = assetImage('assets/donation/wechat-pay.png');
    final alipay = assetImage('assets/donation/alipay.jpg');
    expect(wechat, findsOneWidget);
    expect(alipay, findsOneWidget);
    expect(
        find.text(
            '🙏🏻 No, better chip in for some tokens.. They burn too fast...'),
        findsOneWidget);
    final message = tester.widget<Text>(
      find.byKey(const Key('donation-dialog-message')),
    );
    expect(message.style?.fontSize, greaterThanOrEqualTo(16));
    expect(message.style?.height, 1.45);

    final wechatImage = tester.widget<Image>(wechat);
    final alipayImage = tester.widget<Image>(alipay);
    expect(wechatImage.fit, BoxFit.contain);
    expect(alipayImage.fit, BoxFit.contain);
    expect(tester.getSize(wechat), tester.getSize(alipay));
    expect(tester.getTopLeft(wechat).dy, tester.getTopLeft(alipay).dy);
  });

  testWidgets('donation codes stay complete and scrollable on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(localizedApp(onRestore: () {}));
    await tester.pumpAndSettle();

    await openDonationDialog(tester);

    final wechat = find.byKey(const Key('donation-wechat-code'));
    final alipay = find.byKey(const Key('donation-alipay-code'));
    expect(wechat, findsOneWidget);
    expect(alipay, findsOneWidget);
    expect(tester.widget<Image>(wechat).fit, BoxFit.contain);
    expect(tester.widget<Image>(alipay).fit, BoxFit.contain);
    expect(tester.getSize(wechat), tester.getSize(alipay));

    await tester.ensureVisible(alipay);
    await tester.pumpAndSettle();
    final alipayRect = tester.getRect(alipay);
    expect(alipayRect.top, greaterThanOrEqualTo(0));
    expect(alipayRect.bottom, lessThanOrEqualTo(600));
  });

  testWidgets('title keeps the 0.9.1 debug settings gesture', (tester) async {
    await tester.pumpWidget(localizedApp(onRestore: () {}));
    await tester.pumpAndSettle();

    final titleButton = tester.widget<InkWell>(
      find.byKey(const Key('app-title-button')),
    );
    expect(titleButton.onTap, isNotNull);
  });
}
