import 'package:flutter/foundation.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';

AppDestination? _destinationForId(Object? value) {
  for (final destination in AppDestination.values) {
    if (destination.persistenceId == value) return destination;
  }
  return null;
}

class NavigationConfiguration extends ChangeNotifier {
  static const currentSchemaVersion = 2;

  static final defaultDestinations = AppDestination.values
      .where((destination) => destination.isMandatory)
      .toList(growable: false);

  static final defaultOrder = AppDestination.values.toList(growable: false);

  final int schemaVersion;
  final List<AppDestination> _order;
  final Set<AppDestination> _enabledOptional;

  List<AppDestination> get orderedDestinations => List.unmodifiable(_order);

  List<AppDestination> get destinations => _order
      .where(
        (destination) =>
            destination.isMandatory || _enabledOptional.contains(destination),
      )
      .toList(growable: false);

  NavigationConfiguration._({
    required this.schemaVersion,
    required List<AppDestination> order,
    required Set<AppDestination> enabledOptional,
  })  : _order = List.of(order),
        _enabledOptional = Set.of(enabledOptional);

  factory NavigationConfiguration.fromJson(Map<String, dynamic> json) {
    if (json['navigation_schema_version'] == currentSchemaVersion &&
        json['navigation_order'] is List &&
        json['navigation_destinations'] is List) {
      return NavigationConfiguration._(
        schemaVersion: currentSchemaVersion,
        order: _repairOrder(json['navigation_order'] as List),
        enabledOptional: _parseEnabled(
          json['navigation_destinations'] as List,
        ),
      );
    }

    if (json['navigation_schema_version'] == 1 &&
        json['navigation_destinations'] is List) {
      final legacy = json['navigation_destinations'] as List;
      return NavigationConfiguration._(
        schemaVersion: currentSchemaVersion,
        order: _migrateVersionOneOrder(legacy),
        enabledOptional: _parseEnabled(legacy),
      );
    }

    return NavigationConfiguration._(
      schemaVersion: currentSchemaVersion,
      order: defaultOrder,
      enabledOptional: _legacyVisibility(json),
    );
  }

  static List<AppDestination> _repairOrder(List<dynamic> values) {
    final parsed = <AppDestination>[];
    for (final value in values) {
      final destination = _destinationForId(value);
      if (destination != null && !parsed.contains(destination)) {
        parsed.add(destination);
      }
    }
    for (final destination in defaultOrder) {
      if (!parsed.contains(destination)) parsed.add(destination);
    }
    return parsed;
  }

  static Set<AppDestination> _parseEnabled(List<dynamic> values) => values
      .map(_destinationForId)
      .whereType<AppDestination>()
      .where((destination) => !destination.isMandatory)
      .toSet();

  static List<AppDestination> _migrateVersionOneOrder(List<dynamic> values) {
    final order = <AppDestination>[];
    final knownValues =
        values.map(_destinationForId).whereType<AppDestination>();
    final missingOptional = defaultOrder.where(
      (destination) =>
          !destination.isMandatory && !knownValues.contains(destination),
    );
    var insertedMissing = false;
    for (final value in values) {
      if (value == 'more') {
        order.addAll(missingOptional.where((item) => !order.contains(item)));
        insertedMissing = true;
        continue;
      }
      final destination = _destinationForId(value);
      if (destination != null && !order.contains(destination)) {
        order.add(destination);
      }
    }
    if (!insertedMissing) {
      order.addAll(missingOptional.where((item) => !order.contains(item)));
    }
    for (final destination in defaultOrder) {
      if (!order.contains(destination)) order.add(destination);
    }
    return order;
  }

  static Set<AppDestination> _legacyVisibility(Map<String, dynamic> json) {
    final legacyKeys = <AppDestination, String>{
      AppDestination.imageToImage: 'show_image_to_image_page',
      AppDestination.vibeReference: 'show_vibe_reference_page',
      AppDestination.enhance: 'show_enhance_page',
      AppDestination.directorTools: 'show_director_tools_page',
    };
    if (!legacyKeys.values.any(json.containsKey)) return {};
    return {
      for (final entry in legacyKeys.entries)
        if (json[entry.value] == true) entry.key,
    };
  }

  Map<String, dynamic> toJson() => {
        'navigation_schema_version': schemaVersion,
        'navigation_order': orderedDestinations
            .map((destination) => destination.persistenceId)
            .toList(growable: false),
        'navigation_destinations': destinations
            .map((destination) => destination.persistenceId)
            .toList(growable: false),
      };

  bool contains(AppDestination destination) =>
      destination.isMandatory || _enabledOptional.contains(destination);

  bool setEnabled(AppDestination destination, bool enabled) {
    if (destination.isMandatory) return false;
    final changed = enabled
        ? _enabledOptional.add(destination)
        : _enabledOptional.remove(destination);
    if (changed) notifyListeners();
    return changed;
  }

  /// Replaces loaded navigation data without invalidating listeners held by
  /// the application shell.
  void replaceWith(NavigationConfiguration other) {
    if (listEquals(_order, other._order) &&
        setEquals(_enabledOptional, other._enabledOptional)) {
      return;
    }
    _order
      ..clear()
      ..addAll(other._order);
    _enabledOptional
      ..clear()
      ..addAll(other._enabledOptional);
    notifyListeners();
  }

  bool addFavorite(AppDestination destination) => setEnabled(destination, true);

  bool insertFavorite(AppDestination destination, int index) {
    if (destination.isMandatory || _enabledOptional.contains(destination)) {
      return false;
    }
    final oldIndex = _order.indexOf(destination);
    if (oldIndex >= 0) {
      _order.removeAt(oldIndex);
      if (oldIndex < index) index--;
    }
    _order.insert(index.clamp(0, _order.length), destination);
    _enabledOptional.add(destination);
    notifyListeners();
    return true;
  }

  bool removeFavorite(AppDestination destination) =>
      setEnabled(destination, false);

  bool move(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _order.length ||
        newIndex < 0 ||
        newIndex >= _order.length ||
        oldIndex == newIndex) {
      return false;
    }
    final destination = _order.removeAt(oldIndex);
    _order.insert(newIndex, destination);
    notifyListeners();
    return true;
  }

  bool reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _order.length) return false;
    if (newIndex < 0 || newIndex > _order.length) return false;
    if (newIndex > oldIndex) newIndex--;
    return move(oldIndex, newIndex);
  }
}
