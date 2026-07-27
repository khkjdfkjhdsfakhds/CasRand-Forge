import 'package:flutter/material.dart';

/// Keeps long destination names from deciding the width of the entire rail.
///
/// The visible label may wrap to two lines (and only then ellipsize), while
/// the tooltip always preserves the complete destination name.
class CompactNavigationRailLabel extends StatelessWidget {
  static const double width = 136;

  final String label;

  const CompactNavigationRailLabel({
    super.key,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: SizedBox(
        width: width,
        child: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          softWrap: true,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
