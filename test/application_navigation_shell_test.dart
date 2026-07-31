import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/navigation_configuration.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/ui/navigation/widgets/application_navigation_shell.dart';

void main() {
  late Map<String, dynamic> translations;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    translations = jsonDecode(
      await rootBundle.loadString('assets/l10n/en.json'),
    ) as Map<String, dynamic>;
  });

  Widget app({
    required NavigationConfiguration configuration,
    required NavigationRequest request,
    GlobalKey<ApplicationNavigationShellState>? shellKey,
    ValueChanged<AppDestination>? onDestinationOpened,
    PreferredSizeWidget? appBar,
  }) {
    return EasyLocalization(
      key: UniqueKey(),
      supportedLocales: const [Locale('en')],
      path: 'test',
      assetLoader: _TestAssetLoader(translations),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      saveLocale: false,
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: Scaffold(
            body: ApplicationNavigationShell(
              key: shellKey,
              configuration: configuration,
              navigationRequest: request,
              onDestinationOpened: onDestinationOpened,
              appBar: appBar,
              pages: {
                for (final destination in AppDestination.values)
                  destination: Center(
                    key: ValueKey('page-${destination.name}'),
                    child: Text('page-${destination.name}'),
                  ),
              },
            ),
          ),
        ),
      ),
    );
  }

  NavigationConfiguration allDestinations() =>
      NavigationConfiguration.fromJson({
        'navigation_schema_version': 2,
        'navigation_order': AppDestination.values
            .map((destination) => destination.persistenceId)
            .toList(),
        'navigation_destinations': AppDestination.values
            .map((destination) => destination.persistenceId)
            .toList(),
      });

  for (final width in [320.0, 390.0]) {
    testWidgets('three default phone destinations fill ${width}px width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        app(
          configuration: NavigationConfiguration.fromJson({}),
          request: NavigationRequest(),
        ),
      );
      await tester.pumpAndSettle();

      final indicators = [
        for (final destination in const [
          AppDestination.generation,
          AppDestination.config,
          AppDestination.settings,
        ])
          tester.getRect(
            find.byKey(
              ValueKey('navigation-${destination.name}-indicator'),
            ),
          ),
      ];
      expect(indicators.first.left, closeTo(0, 0.01));
      expect(indicators.last.right, closeTo(width, 0.01));
      for (final indicator in indicators) {
        expect(indicator.width, closeTo(width / 3, 0.01));
      }
      expect(find.byKey(const ValueKey('navigation-more')), findsNothing);
    });
  }

  testWidgets('settings directory opens a transient page and returns', (
    tester,
  ) async {
    final configuration = allDestinations();
    final request = NavigationRequest();
    final shellKey = GlobalKey<ApplicationNavigationShellState>();

    await tester.pumpWidget(
      app(
        configuration: configuration,
        request: request,
        shellKey: shellKey,
      ),
    );
    await tester.pumpAndSettle();

    request.goToFromSettingsDirectory(AppDestination.imageToImage);
    await tester.pumpAndSettle();

    expect(find.text('page-imageToImage'), findsOneWidget);
    expect(configuration.contains(AppDestination.imageToImage), isTrue);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('navigation-settings')))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );

    expect(shellKey.currentState!.returnToSettingsIfTransient(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('page-settings'), findsOneWidget);
  });

  testWidgets('hidden contextual destination stays hidden and selects settings',
      (
    tester,
  ) async {
    final configuration = NavigationConfiguration.fromJson({});
    final request = NavigationRequest();
    final shellKey = GlobalKey<ApplicationNavigationShellState>();

    await tester.pumpWidget(
      app(
        configuration: configuration,
        request: request,
        shellKey: shellKey,
      ),
    );
    await tester.pumpAndSettle();

    request.goTo(AppDestination.enhance);
    await tester.pumpAndSettle();

    expect(find.text('page-enhance'), findsOneWidget);
    expect(configuration.contains(AppDestination.enhance), isFalse);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('navigation-settings')))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(shellKey.currentState!.returnToSettingsIfTransient(), isTrue);
  });

  testWidgets('contextual open selects an enabled destination', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final request = NavigationRequest();

    await tester.pumpWidget(
      app(configuration: allDestinations(), request: request),
    );
    await tester.pumpAndSettle();
    request.goTo(AppDestination.directorTools);
    await tester.pumpAndSettle();

    expect(find.text('page-directorTools'), findsOneWidget);
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('navigation-directorTools')),
          )
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    final target = tester.getRect(
      find.byKey(const ValueKey('navigation-directorTools-indicator')),
    );
    expect(target.left, greaterThanOrEqualTo(0));
    expect(target.right, lessThanOrEqualTo(390));
  });

  testWidgets('duplicate opens are suppressed and a newer target wins', (
    tester,
  ) async {
    final request = NavigationRequest();
    final opened = <AppDestination>[];

    await tester.pumpWidget(
      app(
        configuration: allDestinations(),
        request: request,
        onDestinationOpened: opened.add,
      ),
    );
    await tester.pumpAndSettle();

    request.goTo(AppDestination.enhance);
    request.goTo(AppDestination.enhance);
    request.goTo(AppDestination.directorTools);
    await tester.pumpAndSettle();

    expect(opened, [AppDestination.enhance, AppDestination.directorTools]);
    expect(find.text('page-directorTools'), findsOneWidget);
  });

  testWidgets('phone overflow is discoverable and scrollable', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      app(
        configuration: allDestinations(),
        request: NavigationRequest(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('phone-navigation-overflow-cue-end')),
      findsOneWidget,
    );
    await tester.drag(
      find.byKey(const ValueKey('phone-navigation-scroll')),
      const Offset(-1000, 0),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('phone-navigation-overflow-cue-start')),
      findsOneWidget,
    );
  });

  testWidgets('desktop navigation matches the compact Material 3 rail', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      app(
        configuration: allDestinations(),
        request: NavigationRequest(),
      ),
    );
    await tester.pumpAndSettle();

    final generationEntry = find.byKey(
      const ValueKey('navigation-generation-indicator'),
    );
    final selectedIndicator = find.byKey(
      const ValueKey('navigation-generation-selection-indicator'),
    );
    final longLabel = tester.widget<Text>(
      find.text('Vibe Transfer / Precise Reference'),
    );

    expect(tester.getSize(generationEntry), const Size(80, 64));
    expect(tester.getTopLeft(generationEntry).dy, 8);
    expect(tester.getSize(selectedIndicator), const Size(56, 32));
    expect(longLabel.maxLines, 1);
    expect(longLabel.softWrap, isFalse);
    expect(longLabel.overflow, TextOverflow.ellipsis);
  });

  testWidgets('desktop app bar offsets navigation and content', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      app(
        configuration: NavigationConfiguration.fromJson({}),
        request: NavigationRequest(),
        appBar: AppBar(
          key: const ValueKey('app-bar'),
          title: const Text('title'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getBottomLeft(find.byKey(const ValueKey('app-bar'))).dy, 56);
    expect(
      tester
          .getTopLeft(
            find.byKey(
              const ValueKey('navigation-generation-indicator'),
            ),
          )
          .dy,
      64,
    );
    expect(tester.getTopLeft(find.byKey(const ValueKey('page-generation'))).dy,
        56);
  });
}

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      translations;
}
