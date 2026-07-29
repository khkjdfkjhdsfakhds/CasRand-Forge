import 'package:flutter/foundation.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';

AppDestination? _destinationForId(Object? value) {
  for (final destination in AppDestination.values) {
    if (destination.persistenceId == value) return destination;
  }
  return null;
}

class NavigationConfiguration extends ChangeNotifier {
  static const currentSchemaVersion = 1;

  static final defaultDestinations = AppDestination.values
      .where((destination) => destination.isMandatory)
      .toList(growable: false);

  final int schemaVersion;
  final List<AppDestination> _destinations;

  List<AppDestination> get destinations => List.unmodifiable(_destinations);

  NavigationConfiguration._({
    required this.schemaVersion,
    required List<AppDestination> destinations,
  }) : _destinations = List.of(destinations);

  factory NavigationConfiguration.fromJson(Map<String, dynamic> json) {
    if (json['navigation_schema_version'] != currentSchemaVersion ||
        json['navigation_destinations'] is! List) {
      return NavigationConfiguration._(
        schemaVersion: currentSchemaVersion,
        destinations: defaultDestinations,
      );
    }

    final parsed = <AppDestination>[];
    for (final value in json['navigation_destinations'] as List) {
      final destination = _destinationForId(value);
      if (destination != null && !parsed.contains(destination)) {
        parsed.add(destination);
      }
    }

    for (final destination in defaultDestinations) {
      if (!parsed.contains(destination)) parsed.add(destination);
    }

    return NavigationConfiguration._(
      schemaVersion: currentSchemaVersion,
      destinations: parsed,
    );
  }

  Map<String, dynamic> toJson() => {
        'navigation_schema_version': schemaVersion,
        'navigation_destinations': destinations
            .map((destination) => destination.persistenceId)
            .toList(growable: false),
      };

  bool contains(AppDestination destination) =>
      _destinations.contains(destination);

  /// Replaces loaded navigation data without invalidating listeners held by
  /// the application shell.
  void replaceWith(NavigationConfiguration other) {
    if (listEquals(_destinations, other._destinations)) return;
    _destinations
      ..clear()
      ..addAll(other._destinations);
    notifyListeners();
  }

  bool addFavorite(AppDestination destination) {
    if (destination.isMandatory || _destinations.contains(destination)) {
      return false;
    }
    _destinations.add(destination);
    notifyListeners();
    return true;
  }

  bool insertFavorite(AppDestination destination, int index) {
    if (destination.isMandatory || _destinations.contains(destination)) {
      return false;
    }
    _destinations.insert(index.clamp(0, _destinations.length), destination);
    notifyListeners();
    return true;
  }

  bool removeFavorite(AppDestination destination) {
    if (destination.isMandatory || !_destinations.remove(destination)) {
      return false;
    }
    notifyListeners();
    return true;
  }

  bool move(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _destinations.length ||
        newIndex < 0 ||
        newIndex >= _destinations.length ||
        oldIndex == newIndex) {
      return false;
    }
    final destination = _destinations.removeAt(oldIndex);
    _destinations.insert(newIndex, destination);
    notifyListeners();
    return true;
  }

  bool reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _destinations.length) return false;
    if (newIndex < 0 || newIndex > _destinations.length) return false;
    if (newIndex > oldIndex) newIndex--;
    return move(oldIndex, newIndex);
  }
}
