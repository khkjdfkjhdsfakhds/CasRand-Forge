import 'package:flutter/foundation.dart';

/// Top-level destinations, in navigation order.
enum AppDestination {
  generation(
    persistenceId: 'image_generation',
    mandatory: true,
    labelKey: 'generation',
    shortLabelKey: 'navigation_short_generation',
    descriptionKey: 'navigation_description_generation',
    icon: AppDestinationIcon.create,
  ),
  config(
    persistenceId: 'generation_config',
    mandatory: true,
    labelKey: 'prompt_config',
    shortLabelKey: 'navigation_short_config',
    descriptionKey: 'navigation_description_config',
    icon: AppDestinationIcon.tune,
  ),
  imageToImage(
    persistenceId: 'image_to_image',
    labelKey: 'i2i_inpaint',
    shortLabelKey: 'navigation_short_i2i',
    descriptionKey: 'navigation_description_i2i',
    icon: AppDestinationIcon.brush,
  ),
  vibeReference(
    persistenceId: 'vibe_reference',
    labelKey: 'vibe_transfer',
    shortLabelKey: 'navigation_short_reference',
    descriptionKey: 'navigation_description_reference',
    icon: AppDestinationIcon.reference,
  ),
  enhance(
    persistenceId: 'enhance',
    labelKey: 'enhance_section',
    shortLabelKey: 'navigation_short_enhance',
    descriptionKey: 'navigation_description_enhance',
    icon: AppDestinationIcon.enhance,
  ),
  directorTools(
    persistenceId: 'director_tools',
    labelKey: 'director_tool',
    shortLabelKey: 'navigation_short_director',
    descriptionKey: 'navigation_description_director',
    icon: AppDestinationIcon.directorTools,
  ),
  settings(
    persistenceId: 'settings',
    mandatory: true,
    labelKey: 'settings',
    shortLabelKey: 'navigation_short_settings',
    descriptionKey: 'navigation_description_settings',
    icon: AppDestinationIcon.settings,
  );

  final String persistenceId;
  final bool mandatory;
  final String labelKey;
  final String shortLabelKey;
  final String descriptionKey;
  final AppDestinationIcon icon;

  const AppDestination({
    required this.persistenceId,
    this.mandatory = false,
    required this.labelKey,
    required this.shortLabelKey,
    required this.descriptionKey,
    required this.icon,
  });

  bool get isMandatory => mandatory;
}

enum AppDestinationIcon {
  create,
  tune,
  brush,
  reference,
  enhance,
  directorTools,
  settings,
}

/// What the Img2Img page should open with after a jump.
enum I2iEntryMode {
  /// Just set the base image.
  baseImage,

  /// Set the base image and open the mask editor.
  inpaint,
}

/// Lets a page ask the navigation shell to switch destinations, so result
/// actions ("use as base image", "enhance", ...) can hand off to another page.
class NavigationRequest {
  /// Destination the shell should switch to, or null when idle.
  final ValueNotifier<AppDestination?> requestedDestination =
      ValueNotifier(null);

  /// Incremented when the welcome notice asks the Settings page to open the
  /// combined API and proxy editor immediately after navigation.
  final ValueNotifier<int> apiProxySettingsRevision = ValueNotifier(0);

  /// Incremented for every Img2Img entry request, including requests for the
  /// already-visible destination.
  final ValueNotifier<int> i2iEntryRevision = ValueNotifier(0);

  bool _openApiProxySettingsOnArrival = false;
  bool _openFromSettingsDirectory = false;

  bool get openFromSettingsDirectory => _openFromSettingsDirectory;

  /// How the Img2Img page should present itself on arrival.
  I2iEntryMode i2iEntryMode = I2iEntryMode.baseImage;

  void goTo(AppDestination destination) {
    _openFromSettingsDirectory = false;
    requestedDestination.value = destination;
  }

  void goToFromSettingsDirectory(AppDestination destination) {
    _openFromSettingsDirectory = true;
    requestedDestination.value = destination;
  }

  void goToI2i(I2iEntryMode mode) {
    i2iEntryMode = mode;
    _openFromSettingsDirectory = false;
    requestedDestination.value = AppDestination.imageToImage;
    i2iEntryRevision.value++;
  }

  void goToApiProxySettings() {
    _openApiProxySettingsOnArrival = true;
    _openFromSettingsDirectory = false;
    requestedDestination.value = AppDestination.settings;
    apiProxySettingsRevision.value++;
  }

  /// Reads the entry mode once and resets it, so re-visiting the Img2Img page
  /// later does not replay the last jump (e.g. reopen the mask editor).
  I2iEntryMode takeI2iEntryMode() {
    final mode = i2iEntryMode;
    i2iEntryMode = I2iEntryMode.baseImage;
    return mode;
  }

  bool takeOpenApiProxySettingsRequest() {
    final requested = _openApiProxySettingsOnArrival;
    _openApiProxySettingsOnArrival = false;
    return requested;
  }

  /// Called by the shell once it has handled the request.
  void consume() {
    requestedDestination.value = null;
    _openFromSettingsDirectory = false;
  }
}
