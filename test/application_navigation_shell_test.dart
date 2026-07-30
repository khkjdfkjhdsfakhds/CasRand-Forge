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
    VoidCallback? onConfigurationChanged,
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
              configuration: configuration,
              navigationRequest: request,
              onConfigurationChanged: onConfigurationChanged,
              onDestinationOpened: onDestinationOpened,
              appBar: appBar,
              pages: {
                for (final destination in AppDestination.values)
                  if (destination != AppDestination.more)
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
        'navigation_schema_version': 1,
        'navigation_destinations': const [
          'image_generation',
          'generation_config',
          'more',
          'settings',
          'image_to_image',
          'vibe_reference',
          'enhance',
          'director_tools',
        ],
      });

  testWidgets('favorites can be added, removed, undone, and persisted', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final configuration = NavigationConfiguration.fromJson({});
    final request = NavigationRequest();
    var persistenceCalls = 0;

    await tester.pumpWidget(
      app(
        configuration: configuration,
        request: request,
        onConfigurationChanged: () => persistenceCalls++,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pumpAndSettle();

    final favorite = find.byKey(
      const ValueKey('more-favorite-imageToImage'),
    );
    await tester.ensureVisible(favorite);
    await tester.tap(favorite);
    await tester.pumpAndSettle();

    expect(configuration.contains(AppDestination.imageToImage), isTrue);
    expect(
      find.byKey(const ValueKey('navigation-imageToImage')),
      findsOneWidget,
    );
    expect(find.text('page-imageToImage'), findsNothing);
    expect(persistenceCalls, 1);

    await tester.tap(favorite);
    await tester.pumpAndSettle();

    expect(configuration.contains(AppDestination.imageToImage), isFalse);
    expect(find.text('Undo'), findsOneWidget);
    expect(persistenceCalls, 2);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(configuration.contains(AppDestination.imageToImage), isTrue);
    expect(persistenceCalls, 3);
    expect(
      NavigationConfiguration.fromJson(configuration.toJson()).destinations,
      configuration.destinations,
    );
  });

  testWidgets('removing the open favorite keeps content and selects More', (
    tester,
  ) async {
    final configuration = NavigationConfiguration.fromJson({
      'navigation_schema_version': 1,
      'navigation_destinations': [
        'image_generation',
        'generation_config',
        'image_to_image',
        'more',
        'settings',
      ],
    });
    final request = NavigationRequest();

    await tester.pumpWidget(
      app(configuration: configuration, request: request),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('navigation-imageToImage')),
    );
    await tester.pumpAndSettle();

    configuration.removeFavorite(AppDestination.imageToImage);
    await tester.pumpAndSettle();

    expect(find.text('page-imageToImage'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('navigation-more')))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
  });

  testWidgets('More exposes separate accessible 48px controls', (tester) async {
    final configuration = NavigationConfiguration.fromJson({});
    final request = NavigationRequest();

    await tester.pumpWidget(
      app(configuration: configuration, request: request),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pumpAndSettle();

    final open = find.byKey(const ValueKey('more-open-imageToImage'));
    final favorite = find.byKey(
      const ValueKey('more-favorite-imageToImage'),
    );
    final reorder = find.byKey(
      const ValueKey('more-reorder-generation'),
    );

    expect(tester.getSize(open).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(favorite).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(favorite).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(reorder).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(reorder).height, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(favorite).label,
      contains('Add Img2Img / Inpaint to navigation'),
    );
    expect(
      tester.getSemantics(reorder).label,
      contains('Reorder Image Generation'),
    );
    expect(
      tester.getTopLeft(find.text('All functions')).dy,
      lessThan(tester.getTopLeft(find.text('Current navigation')).dy),
    );
    expect(
      find.text(
        'Tap a function card to open it. Use the button on the right to '
        'show or hide it in the main navigation.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Image Generation, Generation Config, More and Settings are required '
        'and cannot be removed. Drag any item to reorder it.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('removal notification auto-dismisses while undo is available', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final configuration = NavigationConfiguration.fromJson({});

    await tester.pumpWidget(
      app(configuration: configuration, request: NavigationRequest()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pumpAndSettle();

    final favorite = find.byKey(
      const ValueKey('more-favorite-imageToImage'),
    );
    await tester.ensureVisible(favorite);
    await tester.tap(favorite);
    await tester.pumpAndSettle();
    await tester.tap(favorite);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    expect(find.text('Undo'), findsOneWidget);
    final notification = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(notification.persist, isFalse);
    expect(notification.duration, const Duration(seconds: 2));

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('drag handle reorders every navigation entry and persists', (
    tester,
  ) async {
    final configuration = NavigationConfiguration.fromJson({});
    final request = NavigationRequest();
    var persistenceCalls = 0;

    await tester.pumpWidget(
      app(
        configuration: configuration,
        request: request,
        onConfigurationChanged: () => persistenceCalls++,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pumpAndSettle();

    final generationHandle = find.byKey(
      const ValueKey('more-reorder-generation'),
    );
    await tester.ensureVisible(generationHandle);
    await tester.pumpAndSettle();
    await tester.drag(generationHandle, const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(configuration.destinations, [
      AppDestination.config,
      AppDestination.generation,
      AppDestination.more,
      AppDestination.settings,
    ]);
    expect(persistenceCalls, 1);
  });

  testWidgets('phone overflow is discoverable, scrollable, and bounded', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final request = NavigationRequest();

    await tester.pumpWidget(
      app(configuration: allDestinations(), request: request),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('phone-navigation-overflow-cue-end')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('phone-navigation-overflow-cue-start')),
      findsNothing,
    );
    final generationLabel = tester.widget<Text>(find.text('Generate'));
    expect(generationLabel.maxLines, 1);
    expect(generationLabel.softWrap, isFalse);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('navigation-generation-indicator')),
          )
          .height,
      greaterThanOrEqualTo(48),
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
    expect(
      find.byKey(const ValueKey('phone-navigation-overflow-cue-end')),
      findsNothing,
    );
  });

  testWidgets('phone overflow hint is not replayed after configuration rebuild',
      (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final configuration = allDestinations();

    await tester.pumpWidget(
      app(configuration: configuration, request: NavigationRequest()),
    );
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('phone-navigation-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.pixels, 0);

    configuration.removeFavorite(AppDestination.directorTools);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(scrollable.position.pixels, 0);
  });

  testWidgets('phone selected destination is automatically revealed', (
    tester,
  ) async {
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
    final target = tester.getRect(
      find.byKey(const ValueKey('navigation-directorTools-indicator')),
    );
    expect(target.left, greaterThanOrEqualTo(0));
    expect(target.right, lessThanOrEqualTo(390));
  });

  testWidgets('contextual open selects a favorite and reveals its entry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final configuration = allDestinations();
    final request = NavigationRequest();

    await tester.pumpWidget(
      app(configuration: configuration, request: request),
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

  testWidgets('contextual open keeps an unfavorited destination unfavorited', (
    tester,
  ) async {
    final configuration = NavigationConfiguration.fromJson({});
    final originalOrder = List<AppDestination>.of(configuration.destinations);
    final request = NavigationRequest();

    await tester.pumpWidget(
      app(configuration: configuration, request: request),
    );
    await tester.pumpAndSettle();

    request.goTo(AppDestination.enhance);
    await tester.pumpAndSettle();

    expect(find.text('page-enhance'), findsOneWidget);
    expect(configuration.destinations, originalOrder);
    expect(configuration.contains(AppDestination.enhance), isFalse);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('navigation-more')))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
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

  testWidgets('mandatory contextual opens ignore favorite membership', (
    tester,
  ) async {
    final request = NavigationRequest();

    await tester.pumpWidget(
      app(
        configuration: NavigationConfiguration.fromJson({}),
        request: request,
      ),
    );
    await tester.pumpAndSettle();

    request.goTo(AppDestination.settings);
    await tester.pumpAndSettle();

    expect(find.text('page-settings'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('navigation-settings')))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
  });

  testWidgets('desktop overflow has boundary cues and a visible scrollbar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final request = NavigationRequest();

    await tester.pumpWidget(
      app(configuration: allDestinations(), request: request),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('desktop-navigation-scrollbar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('desktop-navigation-overflow-cue-end')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('desktop-navigation-overflow-cue-start')),
      findsNothing,
    );

    await tester.drag(
      find.byKey(const ValueKey('desktop-navigation-scroll')),
      const Offset(0, -1000),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('desktop-navigation-overflow-cue-start')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('desktop-navigation-overflow-cue-end')),
      findsNothing,
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
    final unselectedIndicator = find.byKey(
      const ValueKey('navigation-config-selection-indicator'),
    );
    final longLabel = tester.widget<Text>(
      find.text('Vibe Transfer / Precise Reference'),
    );

    expect(tester.getSize(generationEntry), const Size(80, 64));
    expect(tester.getTopLeft(generationEntry).dy, 8);
    expect(tester.getSize(selectedIndicator), const Size(56, 32));
    expect(
      tester.getCenter(selectedIndicator).dx,
      closeTo(tester.getCenter(generationEntry).dx, 0.01),
    );
    expect(
      tester.getTopLeft(find.text('Image Generation')).dy,
      greaterThan(tester.getBottomLeft(selectedIndicator).dy),
    );

    final selectedDecoration = tester
        .widget<Container>(selectedIndicator)
        .decoration! as BoxDecoration;
    expect(
      selectedDecoration.color,
      Theme.of(tester.element(selectedIndicator))
          .colorScheme
          .secondaryContainer,
    );
    expect(
      selectedDecoration.borderRadius,
      BorderRadius.circular(16),
    );
    expect(tester.widget<Container>(unselectedIndicator).decoration, isNull);

    expect(longLabel.maxLines, 1);
    expect(longLabel.softWrap, isFalse);
    expect(longLabel.overflow, TextOverflow.ellipsis);
    expect(
      tester
          .getSize(
            find.descendant(
              of: selectedIndicator,
              matching: find.byType(Icon),
            ),
          )
          .width,
      24,
    );
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(
              of: find.text('Vibe Transfer / Precise Reference'),
              matching: find.byType(Tooltip),
            ),
          )
          .message,
      'Vibe Transfer / Precise Reference',
    );
  });

  testWidgets('desktop keeps the 0.9.1 header and recalculates body height', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      app(
        configuration: NavigationConfiguration.fromJson({}),
        request: NavigationRequest(),
        appBar: AppBar(
          key: const ValueKey('phone-app-bar'),
          title: const Text('phone title'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final appBar = find.byKey(const ValueKey('phone-app-bar'));
    final generationPage = find.byKey(
      const ValueKey('page-generation'),
    );
    expect(appBar, findsOneWidget);
    expect(tester.getBottomLeft(appBar).dy, 56);
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
    expect(tester.getTopLeft(generationPage).dy, 56);
    expect(tester.getSize(generationPage).height, 744);

    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('more-page-content'))).dy,
      closeTo(64, 0.01),
    );
  });

  testWidgets('phone keeps the app bar above the navigation content', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      app(
        configuration: NavigationConfiguration.fromJson({}),
        request: NavigationRequest(),
        appBar: AppBar(
          key: const ValueKey('phone-app-bar'),
          title: const Text('phone title'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('phone-app-bar')), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('phone-app-bar'))).dy,
      56,
    );
    expect(
      tester
          .getBottomLeft(
            find.byKey(
              const ValueKey('navigation-generation-indicator'),
            ),
          )
          .dy,
      800,
    );

    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pumpAndSettle();
  });

  testWidgets('wide touch layouts keep the app bar without native chrome', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      app(
        configuration: NavigationConfiguration.fromJson({}),
        request: NavigationRequest(),
        appBar: AppBar(
          key: const ValueKey('phone-app-bar'),
          title: const Text('wide touch title'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('phone-app-bar')), findsOneWidget);
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

    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pumpAndSettle();
  });

  testWidgets('navigation without overflow shows no cue or scrollbar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      app(
        configuration: NavigationConfiguration.fromJson({}),
        request: NavigationRequest(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('phone-navigation-overflow-cue-start')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('phone-navigation-overflow-cue-end')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('desktop-navigation-scrollbar')),
      findsNothing,
    );
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('four phone destinations fill ${width}px width',
        (tester) async {
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
          AppDestination.more,
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
        expect(indicator.width, closeTo(width / 4, 0.01));
      }
    });
  }

  for (final size in [const Size(390, 800), const Size(1200, 800)]) {
    testWidgets(
      'default navigation and More directory work at ${size.width}px',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final configuration = NavigationConfiguration.fromJson({});
        final request = NavigationRequest();

        await tester.pumpWidget(
          app(configuration: configuration, request: request),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('navigation-generation')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('navigation-config')), findsOneWidget);
        expect(find.byKey(const ValueKey('navigation-more')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('navigation-settings')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('navigation-imageToImage')),
          findsNothing,
        );

        await tester.tap(find.byKey(const ValueKey('navigation-more')));
        await tester.pumpAndSettle();

        for (final destination in const [
          AppDestination.imageToImage,
          AppDestination.vibeReference,
          AppDestination.enhance,
          AppDestination.directorTools,
        ]) {
          expect(
            find.byKey(ValueKey('more-open-${destination.name}')),
            findsOneWidget,
          );
        }

        await tester.tap(
          find.byKey(const ValueKey('more-open-imageToImage')),
        );
        await tester.pumpAndSettle();

        expect(find.text('page-imageToImage'), findsOneWidget);
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('navigation-more')))
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
        expect(configuration.contains(AppDestination.imageToImage), isFalse);
      },
    );
  }
}

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      translations;
}
