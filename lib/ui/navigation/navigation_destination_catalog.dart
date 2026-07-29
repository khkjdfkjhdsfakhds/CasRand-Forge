import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';

class NavigationDestinationDefinition {
  final AppDestination destination;
  final String labelKey;
  final String shortLabelKey;
  final String descriptionKey;
  final IconData icon;

  const NavigationDestinationDefinition({
    required this.destination,
    required this.labelKey,
    required this.shortLabelKey,
    required this.descriptionKey,
    required this.icon,
  });
}

const navigationDestinationCatalog = <NavigationDestinationDefinition>[
  NavigationDestinationDefinition(
    destination: AppDestination.generation,
    labelKey: 'generation',
    shortLabelKey: 'navigation_short_generation',
    descriptionKey: 'navigation_description_generation',
    icon: Icons.create,
  ),
  NavigationDestinationDefinition(
    destination: AppDestination.config,
    labelKey: 'prompt_config',
    shortLabelKey: 'navigation_short_config',
    descriptionKey: 'navigation_description_config',
    icon: Icons.tune,
  ),
  NavigationDestinationDefinition(
    destination: AppDestination.more,
    labelKey: 'navigation_more',
    shortLabelKey: 'navigation_short_more',
    descriptionKey: 'navigation_description_more',
    icon: Icons.apps,
  ),
  NavigationDestinationDefinition(
    destination: AppDestination.settings,
    labelKey: 'settings',
    shortLabelKey: 'navigation_short_settings',
    descriptionKey: 'navigation_description_settings',
    icon: Icons.settings,
  ),
  NavigationDestinationDefinition(
    destination: AppDestination.imageToImage,
    labelKey: 'i2i_inpaint',
    shortLabelKey: 'navigation_short_i2i',
    descriptionKey: 'navigation_description_i2i',
    icon: Icons.brush,
  ),
  NavigationDestinationDefinition(
    destination: AppDestination.vibeReference,
    labelKey: 'vibe_transfer',
    shortLabelKey: 'navigation_short_reference',
    descriptionKey: 'navigation_description_reference',
    icon: Icons.auto_awesome_motion_outlined,
  ),
  NavigationDestinationDefinition(
    destination: AppDestination.enhance,
    labelKey: 'enhance_section',
    shortLabelKey: 'navigation_short_enhance',
    descriptionKey: 'navigation_description_enhance',
    icon: Icons.auto_awesome,
  ),
  NavigationDestinationDefinition(
    destination: AppDestination.directorTools,
    labelKey: 'director_tool',
    shortLabelKey: 'navigation_short_director',
    descriptionKey: 'navigation_description_director',
    icon: Icons.auto_fix_high,
  ),
];

const optionalNavigationDestinations = <AppDestination>[
  AppDestination.imageToImage,
  AppDestination.vibeReference,
  AppDestination.enhance,
  AppDestination.directorTools,
];

NavigationDestinationDefinition navigationDefinition(
  AppDestination destination,
) =>
    navigationDestinationCatalog.firstWhere(
      (definition) => definition.destination == destination,
    );
