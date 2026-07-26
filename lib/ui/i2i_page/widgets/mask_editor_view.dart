import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';

class MaskEditorResult {
  /// Rasterized mask PNG (white = repaint) at image resolution; null when the
  /// mask ended up empty.
  final Uint8List? maskBytes;
  final List<MaskStroke> strokes;

  const MaskEditorResult({required this.maskBytes, required this.strokes});
}

/// Fullscreen freehand mask editor for inpainting.
class MaskEditorView extends StatefulWidget {
  final Uint8List imageBytes;
  final int imageWidth;
  final int imageHeight;
  final List<MaskStroke> initialStrokes;

  const MaskEditorView({
    super.key,
    required this.imageBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.initialStrokes,
  });

  static Future<MaskEditorResult?> open(
    BuildContext context, {
    required Uint8List imageBytes,
    required int imageWidth,
    required int imageHeight,
    required List<MaskStroke> initialStrokes,
  }) {
    return Navigator.of(context).push<MaskEditorResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => MaskEditorView(
          imageBytes: imageBytes,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          initialStrokes: initialStrokes,
        ),
      ),
    );
  }

  @override
  State<MaskEditorView> createState() => _MaskEditorViewState();
}

class _MaskEditorViewState extends State<MaskEditorView> {
  late List<MaskStroke> _strokes;
  final List<MaskStroke> _redoStack = [];
  MaskStroke? _activeStroke;
  bool _isErase = false;
  late double _brushSize;

  @override
  void initState() {
    super.initState();
    _strokes = List.of(widget.initialStrokes);
    _brushSize =
        (widget.imageWidth / 16).clamp(16.0, 256.0).toDouble();
  }

  double get _maxBrushSize =>
      max(64.0, widget.imageWidth / 2).clamp(64.0, 512.0).toDouble();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('mask_editor_title')),
        leading: IconButton(
          key: const Key('mask-editor-cancel'),
          icon: const Icon(Icons.close),
          tooltip: tr('cancel'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            key: const Key('mask-editor-undo'),
            icon: const Icon(Icons.undo),
            tooltip: tr('mask_editor_undo'),
            onPressed: _strokes.isEmpty ? null : _undo,
          ),
          IconButton(
            key: const Key('mask-editor-redo'),
            icon: const Icon(Icons.redo),
            tooltip: tr('mask_editor_redo'),
            onPressed: _redoStack.isEmpty ? null : _redo,
          ),
          IconButton(
            key: const Key('mask-editor-clear'),
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: tr('mask_editor_clear'),
            onPressed: _strokes.isEmpty ? null : _clear,
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const Key('mask-editor-done'),
            onPressed: _finish,
            icon: const Icon(Icons.check),
            label: Text(tr('confirm')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black26,
              child: LayoutBuilder(
                builder: (context, constraints) => _buildCanvas(constraints),
              ),
            ),
          ),
          _buildToolbar(),
        ],
      ),
    );
  }

  Widget _buildCanvas(BoxConstraints constraints) {
    final imageW = widget.imageWidth.toDouble();
    final imageH = widget.imageHeight.toDouble();
    final scale = min(
      constraints.maxWidth / imageW,
      constraints.maxHeight / imageH,
    );
    final displayW = imageW * scale;
    final displayH = imageH * scale;
    final offsetX = (constraints.maxWidth - displayW) / 2;
    final offsetY = (constraints.maxHeight - displayH) / 2;

    Offset toImageSpace(Offset local) {
      return Offset(
        ((local.dx - offsetX) / scale).clamp(0.0, imageW),
        ((local.dy - offsetY) / scale).clamp(0.0, imageH),
      );
    }

    return GestureDetector(
      onPanStart: (details) {
        setState(() {
          _redoStack.clear();
          _activeStroke = MaskStroke(
            isErase: _isErase,
            brushSize: _brushSize,
            points: [toImageSpace(details.localPosition)],
          );
          _strokes.add(_activeStroke!);
        });
      },
      onPanUpdate: (details) {
        final stroke = _activeStroke;
        if (stroke == null) return;
        setState(() {
          stroke.points.add(toImageSpace(details.localPosition));
        });
      },
      onPanEnd: (_) => _activeStroke = null,
      onPanCancel: () => _activeStroke = null,
      child: Stack(
        children: [
          Positioned(
            left: offsetX,
            top: offsetY,
            width: displayW,
            height: displayH,
            child: Image.memory(
              widget.imageBytes,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            ),
          ),
          Positioned(
            left: offsetX,
            top: offsetY,
            width: displayW,
            height: displayH,
            child: CustomPaint(
              painter: MaskOverlayPainter(
                strokes: _strokes,
                imageWidth: imageW,
                imageHeight: imageH,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.brush),
                    label: Text(tr('mask_editor_brush')),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.auto_fix_normal),
                    label: Text(tr('mask_editor_eraser')),
                  ),
                ],
                selected: {_isErase},
                onSelectionChanged: (selection) {
                  setState(() => _isErase = selection.first);
                },
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Text(tr('mask_editor_brush_size')),
                    Expanded(
                      child: Slider(
                        value: _brushSize.clamp(8.0, _maxBrushSize),
                        min: 8.0,
                        max: _maxBrushSize,
                        onChanged: (value) {
                          setState(() => _brushSize = value);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: Text(
                        _brushSize.round().toString(),
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _undo() {
    setState(() {
      _redoStack.add(_strokes.removeLast());
    });
  }

  void _redo() {
    setState(() {
      _strokes.add(_redoStack.removeLast());
    });
  }

  void _clear() {
    setState(() {
      _redoStack.clear();
      _strokes.clear();
    });
  }

  Future<void> _finish() async {
    final hasPaint = _strokes.any((stroke) => !stroke.isErase);
    if (!hasPaint) {
      Navigator.of(context).pop(
        const MaskEditorResult(maskBytes: null, strokes: []),
      );
      return;
    }
    final maskBytes = await rasterizeMaskStrokes(
      strokes: _strokes,
      imageWidth: widget.imageWidth,
      imageHeight: widget.imageHeight,
    );
    if (!mounted) return;
    Navigator.of(context).pop(
      MaskEditorResult(maskBytes: maskBytes, strokes: List.of(_strokes)),
    );
  }
}

/// Draws the mask strokes as a translucent red overlay. The painter works in
/// display space; strokes are stored in image space and scaled here.
class MaskOverlayPainter extends CustomPainter {
  final List<MaskStroke> strokes;
  final double imageWidth;
  final double imageHeight;

  MaskOverlayPainter({
    required this.strokes,
    required this.imageWidth,
    required this.imageHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (strokes.isEmpty) return;
    final scale = min(size.width / imageWidth, size.height / imageHeight);
    // Strokes render opaque inside the layer (so erase works via clear);
    // the layer paint applies the translucency on restore.
    canvas.saveLayer(
      Offset.zero & size,
      Paint()..color = const Color(0x8AFFFFFF),
    );
    canvas.scale(scale);
    for (final stroke in strokes) {
      final paint = Paint()
        ..color = const Color(0xFFE53935)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = stroke.brushSize;
      if (stroke.isErase) {
        paint.blendMode = BlendMode.clear;
      }
      _drawStroke(canvas, stroke, paint);
    }
    canvas.restore();
  }

  void _drawStroke(Canvas canvas, MaskStroke stroke, Paint paint) {
    if (stroke.points.isEmpty) return;
    if (stroke.points.length == 1) {
      final fill = Paint()
        ..color = paint.color
        ..blendMode = paint.blendMode
        ..style = PaintingStyle.fill;
      canvas.drawCircle(stroke.points.first, stroke.brushSize / 2, fill);
      return;
    }
    paint.style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (final point in stroke.points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(MaskOverlayPainter oldDelegate) => true;
}

/// Rasterizes strokes into a black/white PNG at image resolution
/// (white = repaint). Erase strokes paint black in order.
Future<Uint8List> rasterizeMaskStrokes({
  required List<MaskStroke> strokes,
  required int imageWidth,
  required int imageHeight,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, imageWidth.toDouble(), imageHeight.toDouble()),
    Paint()..color = const Color(0xFF000000),
  );
  for (final stroke in strokes) {
    final color =
        stroke.isErase ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    if (stroke.points.length == 1) {
      canvas.drawCircle(
        stroke.points.first,
        stroke.brushSize / 2,
        Paint()..color = color,
      );
      continue;
    }
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = stroke.brushSize;
    final path = Path()
      ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (final point in stroke.points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(imageWidth, imageHeight);
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw Exception('Failed to rasterize mask.');
    }
    return byteData.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
