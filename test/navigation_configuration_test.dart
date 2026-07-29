import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/navigation_configuration.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';

void main() {
  test('new navigation starts with the four mandatory destinations in order',
      () {
    final configuration = NavigationConfiguration.fromJson({});

    expect(configuration.schemaVersion, 1);
    expect(configuration.destinations, [
      AppDestination.generation,
      AppDestination.config,
      AppDestination.more,
      AppDestination.settings,
    ]);
  });

  test('saved navigation removes unknown and duplicate entries then repairs it',
      () {
    final configuration = NavigationConfiguration.fromJson({
      'navigation_schema_version': 1,
      'navigation_destinations': [
        'enhance',
        'image_generation',
        'unknown_future_destination',
        'enhance',
        'settings',
      ],
    });

    expect(configuration.destinations, [
      AppDestination.enhance,
      AppDestination.generation,
      AppDestination.settings,
      AppDestination.config,
      AppDestination.more,
    ]);
  });

  test('cleaned navigation has a stable JSON round trip', () {
    final cleaned = NavigationConfiguration.fromJson({
      'navigation_schema_version': 1,
      'navigation_destinations': [
        'director_tools',
        'more',
        'generation_config',
        'settings',
        'image_generation',
      ],
    });

    final restored = NavigationConfiguration.fromJson(cleaned.toJson());

    expect(restored.toJson(), {
      'navigation_schema_version': 1,
      'navigation_destinations': [
        'director_tools',
        'more',
        'generation_config',
        'settings',
        'image_generation',
      ],
    });
  });

  test('favorites can be added removed and all entries reordered', () {
    final configuration = NavigationConfiguration.fromJson({});

    expect(configuration.addFavorite(AppDestination.enhance), isTrue);
    expect(configuration.removeFavorite(AppDestination.generation), isFalse);
    expect(configuration.move(3, 0), isTrue);
    expect(configuration.removeFavorite(AppDestination.enhance), isTrue);

    expect(configuration.destinations, [
      AppDestination.settings,
      AppDestination.generation,
      AppDestination.config,
      AppDestination.more,
    ]);
  });
}
