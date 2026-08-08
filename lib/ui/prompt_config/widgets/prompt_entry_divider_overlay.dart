part of 'prompt_entry_editor.dart';

class _PromptEntryDividerOverlayPainter extends CustomPainter {
  _PromptEntryDividerOverlayPainter({
    required this.controller,
    required this.scrollController,
    required this.color,
    required this.editorLayoutKey,
  })  : documentRevision = controller.layoutRevision,
        super(repaint: scrollController);

  final _PromptDocumentController controller;
  final ScrollController scrollController;
  final Color color;
  final GlobalKey editorLayoutKey;
  final int documentRevision;
  int _cachedRevision = -1;
  double _cachedLayoutWidth = -1;
  List<double> _cachedDividerYPositions = const [];
  int _layoutPassCount = 0;

  @visibleForTesting
  int get debugLayoutPassCount => _layoutPassCount;

  @visibleForTesting
  List<double> get debugDividerYPositions =>
      List.unmodifiable(_cachedDividerYPositions);

  @override
  void paint(Canvas canvas, Size size) {
    if (controller.boundaryOffsets.isEmpty) return;

    final layoutWidth = math.max(0.0, size.width);
    if (_cachedRevision != controller.layoutRevision ||
        _cachedLayoutWidth != layoutWidth) {
      _cachedDividerYPositions = _layoutDividerYPositions();
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
        startX: _PromptEntryEditorState._contentPadding.left,
        endX: size.width - _PromptEntryEditorState._contentPadding.right,
        y: y,
        color: color,
      );
    }
  }

  List<double> _layoutDividerYPositions() {
    _layoutPassCount++;
    final editorBox = editorLayoutKey.currentContext?.findRenderObject();
    if (editorBox is! RenderBox) return const [];
    final renderEditable = _findRenderEditable(editorBox);
    if (renderEditable == null) return const [];
    final scrollOffset =
        scrollController.hasClients ? scrollController.offset : 0.0;
    return controller.sortedBoundaryOffsets.map((boundary) {
      final before = renderEditable.getLocalRectForCaret(
        TextPosition(offset: boundary, affinity: TextAffinity.upstream),
      );
      final after = renderEditable.getLocalRectForCaret(
        TextPosition(offset: boundary + 1),
      );
      final beforeBottom = editorBox.globalToLocal(
        renderEditable.localToGlobal(before.bottomLeft),
      );
      final afterTop = editorBox.globalToLocal(
        renderEditable.localToGlobal(after.topLeft),
      );
      return (beforeBottom.dy + afterTop.dy) / 2 + scrollOffset;
    }).toList(growable: false);
  }

  RenderEditable? _findRenderEditable(RenderObject root) {
    RenderEditable? result;
    void visit(RenderObject child) {
      if (result != null) return;
      if (child is RenderEditable) {
        result = child;
        return;
      }
      child.visitChildren(visit);
    }

    root.visitChildren(visit);
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
      oldDelegate.color != color ||
      oldDelegate.editorLayoutKey != editorLayoutKey;
}
