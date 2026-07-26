import 'package:flutter/foundation.dart';

/// Top-level destinations, in navigation order.
enum AppDestination {
  generation,
  imageToImage,
  directorTools,
  config,
  settings;

  /// Position in the navigation rail / bottom bar.
  int get destinationIndex => AppDestination.values.indexOf(this);
}

/// What the Img2Img page should open with after a jump.
enum I2iEntryMode {
  /// Just set the base image.
  baseImage,

  /// Set the base image and open the mask editor.
  inpaint,

  /// Set the base image and focus the Enhance section.
  enhance,

}

/// Lets a page ask the navigation shell to switch destinations, so result
/// actions ("use as base image", "enhance", ...) can hand off to another page.
class NavigationRequest {
  /// Destination the shell should switch to, or null when idle.
  final ValueNotifier<AppDestination?> requestedDestination =
      ValueNotifier(null);

  /// How the Img2Img page should present itself on arrival.
  I2iEntryMode i2iEntryMode = I2iEntryMode.baseImage;

  void goTo(AppDestination destination) {
    requestedDestination.value = destination;
  }

  void goToI2i(I2iEntryMode mode) {
    i2iEntryMode = mode;
    requestedDestination.value = AppDestination.imageToImage;
  }

  /// Called by the shell once it has handled the request.
  void consume() {
    requestedDestination.value = null;
  }
}
