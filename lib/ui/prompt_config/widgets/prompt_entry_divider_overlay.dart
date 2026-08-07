part of 'prompt_entry_editor.dart';

class _PromptEntryDividerOverlayPainter extends CustomPainter {
  _PromptEntryDividerOverlayPainter({
    required this.controller,
    required this.scrollController,
    required this.style,
    required this.commentStyle,
    required this.color,
    required this.textDirection,
    required this.textScaler,
    required this.contentPadding,
  })  : documentRevision = controller.layoutRevision,
        super(repaint: scrollController);

  final _PromptDocumentController controller;
  final ScrollController scrollController;
  final TextStyle style;
  final TextStyle commentStyle;
  final Color color;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final EdgeInsets contentPadding;
  final int documentRevision;
  int _cachedRevision = -1;
  double _cachedLayoutWidth = -1;
  List<double> _cachedDividerYPositions = const [];
  int _layoutPassCount = 0;

  @visibleForTesting
  int get debugLayoutPassCount => _layoutPassCount;

  @override
  void paint(Canvas canvas, Size size) {
    if (controller.boundaryOffsets.isEmpty) return;

    final layoutWidth = math.max(
      0.0,
      size.width - 4 - contentPadding.horizontal,
    );
    if (_cachedRevision != controller.layoutRevision ||
        _cachedLayoutWidth != layoutWidth) {
      _cachedDividerYPositions = _layoutDividerYPositions(layoutWidth);
      _cachedRevision = controller.layoutRevision;
      _cachedLayoutWidth = layoutWidth;
    }

    final scrollOffset =
        scrollController.hasClients ? scrollController.offset : 0.0;
    final firstVisible = _lowerBound(
      _cachedDividerYPositions,
      scrollOffset,
    );
    for (var index = firstVisible;
        index < _cachedDividerYPositions.length;
        index++) {
      final y = _cachedDividerYPositions[index] - scrollOffset;
      if (y > size.height) break;
      PromptEntryDividerPainter.paintDashedLine(
        canvas,
        startX: contentPadding.left,
        endX: size.width - contentPadding.right,
        y: y,
        color: color,
      );
    }
  }

  List<double> _layoutDividerYPositions(double layoutWidth) {
    _layoutPassCount++;
    final textPainter = TextPainter(
      text: controller.documentSpan(
        style: style,
        commentStyle: commentStyle,
        withComposing: true,
      ),
      textDirection: textDirection,
      textScaler: textScaler,
      textWidthBasis: TextWidthBasis.parent,
    )..layout(maxWidth: layoutWidth);
    final result = controller.sortedBoundaryOffsets
        .map(
          (boundary) =>
              contentPadding.top +
              textPainter
                  .getOffsetForCaret(
                    TextPosition(offset: boundary + 1),
                    Rect.zero,
                  )
                  .dy -
              PromptEntryDivider.height / 2,
        )
        .toList(growable: false);
    textPainter.dispose();
    return result;
  }

  int _lowerBound(List<double> values, double target) {
    var low = 0;
    var high = values.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (values[middle] < target) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  @override
  bool shouldRepaint(_PromptEntryDividerOverlayPainter oldDelegate) =>
      oldDelegate.documentRevision != documentRevision ||
      oldDelegate.style != style ||
      oldDelegate.commentStyle != commentStyle ||
      oldDelegate.color != color ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.contentPadding != contentPadding;
}
