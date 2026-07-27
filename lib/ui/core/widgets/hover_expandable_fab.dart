import 'package:flutter/material.dart';

/// A compact desktop-friendly FAB that keeps an icon-only footprint until the
/// pointer hovers it or keyboard focus reaches it.
class HoverExpandableFab extends StatefulWidget {
  const HoverExpandableFab({
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
  State<HoverExpandableFab> createState() => _HoverExpandableFabState();
}

class _HoverExpandableFabState extends State<HoverExpandableFab> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onPressed == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) {
        if (_hovered) return;
        setState(() => _hovered = true);
      },
      onExit: (_) {
        if (!_hovered) return;
        setState(() => _hovered = false);
      },
      child: Focus(
        onFocusChange: (value) {
          if (_focused == value) return;
          setState(() => _focused = value);
        },
        child: FloatingActionButton.extended(
          key: widget.buttonKey,
          heroTag: widget.heroTag,
          onPressed: widget.onPressed,
          tooltip: widget.tooltip,
          isExtended: _hovered || _focused,
          icon: widget.icon,
          label: widget.label,
        ),
      ),
    );
  }
}
