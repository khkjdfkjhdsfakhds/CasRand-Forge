import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';

class NavigationDestinationDefinition {
  final AppDestination destination;
  final IconData icon;

  const NavigationDestinationDefinition({
    required this.destination,
    required this.icon,
  });

  String get labelKey => destination.labelKey;
  String get shortLabelKey => destination.shortLabelKey;
  String get descriptionKey => destination.descriptionKey;
}

final optionalNavigationDestinations = AppDestination.values
    .where((destination) => !destination.isMandatory)
    .toList(growable: false);

NavigationDestinationDefinition navigationDefinition(
  AppDestination destination,
) {
  final icon = switch (destination.icon) {
    AppDestinationIcon.create => Icons.create,
    AppDestinationIcon.tune => Icons.tune,
    AppDestinationIcon.brush => Icons.brush,
    AppDestinationIcon.reference => Icons.auto_awesome_motion_outlined,
    AppDestinationIcon.enhance => Icons.auto_awesome,
    AppDestinationIcon.directorTools => Icons.auto_fix_high,
    AppDestinationIcon.settings => Icons.settings,
  };
  return NavigationDestinationDefinition(destination: destination, icon: icon);
}
