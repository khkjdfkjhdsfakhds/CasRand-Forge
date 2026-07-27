import 'package:flutter/foundation.dart';

/// Top-level destinations, in navigation order.
enum AppDestination {
  generation,
  config,
  imageToImage,
  vibeReference,
  enhance,
  directorTools,
  settings;
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

  /// Incremented when optional workspace visibility changes, so the shell can
  /// rebuild its dynamic rail/bar without coupling it to the settings page.
  final ValueNotifier<int> visibilityRevision = ValueNotifier(0);

  /// How the Img2Img page should present itself on arrival.
  I2iEntryMode i2iEntryMode = I2iEntryMode.baseImage;

  void goTo(AppDestination destination) {
    requestedDestination.value = destination;
  }

  void goToI2i(I2iEntryMode mode) {
    i2iEntryMode = mode;
    requestedDestination.value = AppDestination.imageToImage;
  }

  void notifyVisibilityChanged() {
    visibilityRevision.value++;
  }

  /// Reads the entry mode once and resets it, so re-visiting the Img2Img page
  /// later does not replay the last jump (e.g. reopen the mask editor).
  I2iEntryMode takeI2iEntryMode() {
    final mode = i2iEntryMode;
    i2iEntryMode = I2iEntryMode.baseImage;
    return mode;
  }

  /// Called by the shell once it has handled the request.
  void consume() {
    requestedDestination.value = null;
  }
}
