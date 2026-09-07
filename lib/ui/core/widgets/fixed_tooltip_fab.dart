import 'package:flutter/material.dart';

/// An icon-only FAB whose label is available through hover or long-press.
class FixedTooltipFab extends StatelessWidget {
  const FixedTooltipFab({
    super.key,
    required this.heroTag,
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.buttonKey,
  });

  final Object? heroTag;
  final VoidCallback? onPressed;
  final Widget icon;
  final Widget label;
  final String tooltip;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      key: buttonKey,
      heroTag: heroTag,
      onPressed: onPressed,
      tooltip: tooltip,
      isExtended: false,
      icon: icon,
      label: label,
    );
  }
}
