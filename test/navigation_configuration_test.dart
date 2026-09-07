import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/navigation_configuration.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';

void main() {
  test('destination metadata is complete and persistence IDs are unique', () {
    expect(
      AppDestination.values.map((destination) => destination.persistenceId),
      hasLength(
        AppDestination.values
            .map((destination) => destination.persistenceId)
            .toSet()
            .length,
      ),
    );
    for (final destination in AppDestination.values) {
      expect(destination.persistenceId, isNotEmpty);
      expect(destination.labelKey, isNotEmpty);
      expect(destination.shortLabelKey, isNotEmpty);
      expect(destination.descriptionKey, isNotEmpty);
    }
  });

  test('new navigation shows three required entries and orders all seven', () {
    final configuration = NavigationConfiguration.fromJson({});

    expect(configuration.schemaVersion, 2);
    expect(configuration.destinations, [
      AppDestination.generation,
      AppDestination.config,
      AppDestination.settings,
    ]);
    expect(configuration.orderedDestinations, AppDestination.values);
  });

  test('version one favorites migrate without More and keep relative order',
      () {
    final configuration = NavigationConfiguration.fromJson({
      'navigation_schema_version': 1,
      'navigation_destinations': [
        'settings',
        'more',
        'image_to_image',
        'generation_config',
        'image_generation',
      ],
    });

    expect(configuration.destinations, [
      AppDestination.settings,
      AppDestination.imageToImage,
      AppDestination.config,
      AppDestination.generation,
    ]);
    expect(configuration.orderedDestinations, [
      AppDestination.settings,
      AppDestination.vibeReference,
      AppDestination.enhance,
      AppDestination.directorTools,
      AppDestination.imageToImage,
      AppDestination.config,
      AppDestination.generation,
    ]);
  });

  test('legacy visibility switches seed optional navigation entries', () {
    final configuration = NavigationConfiguration.fromJson({
      'show_image_to_image_page': true,
      'show_vibe_reference_page': false,
      'show_enhance_page': true,
      'show_director_tools_page': false,
    });

    expect(configuration.contains(AppDestination.imageToImage), isTrue);
    expect(configuration.contains(AppDestination.vibeReference), isFalse);
    expect(configuration.contains(AppDestination.enhance), isTrue);
    expect(configuration.contains(AppDestination.directorTools), isFalse);
  });

  test('disabled entries keep their ordered position across a JSON round trip',
      () {
    final configuration = NavigationConfiguration.fromJson({});
    expect(configuration.move(2, 0), isTrue);
    expect(configuration.setEnabled(AppDestination.enhance, true), isTrue);
    expect(configuration.setEnabled(AppDestination.enhance, false), isTrue);

    final restored = NavigationConfiguration.fromJson(configuration.toJson());

    expect(restored.orderedDestinations, configuration.orderedDestinations);
    expect(restored.destinations, configuration.destinations);
    expect(restored.orderedDestinations.first, AppDestination.imageToImage);
    expect(restored.contains(AppDestination.enhance), isFalse);
  });

  test('saved navigation repairs unknown, duplicate and missing entries', () {
    final configuration = NavigationConfiguration.fromJson({
      'navigation_schema_version': 2,
      'navigation_order': [
        'enhance',
        'unknown_future_destination',
        'enhance',
        'settings',
      ],
      'navigation_destinations': [
        'enhance',
        'unknown_future_destination',
      ],
    });

    expect(configuration.orderedDestinations.toSet(),
        AppDestination.values.toSet());
    expect(configuration.orderedDestinations, hasLength(7));
    expect(configuration.destinations.first, AppDestination.enhance);
    expect(configuration.destinations,
        containsAll(NavigationConfiguration.defaultDestinations));
  });
}
