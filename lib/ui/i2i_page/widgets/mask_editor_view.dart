import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart' show CropRect;

class MaskEditorResult {
  /// Rasterized mask PNG (white = repaint) at image resolution; null when the
  /// mask ended up empty.
  final Uint8List? maskBytes;
  final List<MaskStroke> strokes;

  /// Hand-drawn focus frame in image pixels, or null for automatic framing.
  final CropRect? focusFrame;

  const MaskEditorResult({
    required this.maskBytes,
    required this.strokes,
    this.focusFrame,
  });
}

enum _EditorTool { brush, erase, frame }

/// Fullscreen mask editor for inpainting: freehand repaint strokes, plus an
/// optional hand-drawn focus frame that overrides Autocrop.
class MaskEditorView extends StatefulWidget {
  final Uint8List imageBytes;
  final int imageWidth;
  final int imageHeight;
  final List<MaskStroke> initialStrokes;
  final CropRect? initialFocusFrame;

  const MaskEditorView({
    super.key,
    required this.imageBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.initialStrokes,
    this.initialFocusFrame,
  });

  static Future<MaskEditorResult?> open(
    BuildContext context, {
    required Uint8List imageBytes,
    required int imageWidth,
    required int imageHeight,
    required List<MaskStroke> initialStrokes,
    CropRect? initialFocusFrame,
  }) {
    return Navigator.of(context).push<MaskEditorResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => MaskEditorView(
          imageBytes: imageBytes,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          initialStrokes: initialStrokes,
          initialFocusFrame: initialFocusFrame,
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
  _EditorTool _tool = _EditorTool.brush;
  late double _brushSize;

  Rect? _focusFrame;
  Offset? _frameDragStart;

  /// Cursor position in canvas-local display coordinates, for the brush
  /// preview circle. Null when the pointer is outside the canvas.
  Offset? _hoverPosition;

  @override
  void initState() {
    super.initState();
    _strokes = List.of(widget.initialStrokes);
    _brushSize = (widget.imageWidth / 16).clamp(16.0, 256.0).toDouble();
    final initialFrame = widget.initialFocusFrame;
    if (initialFrame != null) {
      _focusFrame = Rect.fromLTWH(
        initialFrame.x.toDouble(),
        initialFrame.y.toDouble(),
        initialFrame.w.toDouble(),
        initialFrame.h.toDouble(),
      );
    }
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

    final showBrushPreview = _tool != _EditorTool.frame;
    final hover = _hoverPosition;

    return MouseRegion(
      cursor: _tool == _EditorTool.frame
          ? SystemMouseCursors.precise
          : MouseCursor.defer,
      onHover: (event) => setState(() => _hoverPosition = event.localPosition),
      onExit: (_) => setState(() => _hoverPosition = null),
      child: GestureDetector(
        onPanStart: (details) {
          final point = toImageSpace(details.localPosition);
          if (_tool == _EditorTool.frame) {
            setState(() {
              _frameDragStart = point;
              _focusFrame = Rect.fromPoints(point, point);
            });
            return;
          }
          setState(() {
            _redoStack.clear();
            _activeStroke = MaskStroke(
              isErase: _tool == _EditorTool.erase,
              brushSize: _brushSize,
              points: [point],
            );
            _strokes.add(_activeStroke!);
          });
        },
        onPanUpdate: (details) {
          final point = toImageSpace(details.localPosition);
          if (_tool == _EditorTool.frame) {
            final start = _frameDragStart;
            if (start == null) return;
            setState(() {
              _focusFrame = Rect.fromPoints(start, point);
            });
            return;
          }
          final stroke = _activeStroke;
          if (stroke == null) return;
          setState(() {
            stroke.points.add(point);
            _hoverPosition = details.localPosition;
          });
        },
        onPanEnd: (_) => _endGesture(),
        onPanCancel: _endGesture,
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
                  focusFrame: _focusFrame,
                  brushPreviewPoint: showBrushPreview && hover != null
                      ? hover - Offset(offsetX, offsetY)
                      : null,
                  brushPreviewRadius: _brushSize / 2 * scale,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _endGesture() {
    if (_tool == _EditorTool.frame) {
      setState(() {
        _frameDragStart = null;
        final frame = _focusFrame;
        // A sub-16px drag is a slip, not a frame.
        if (frame != null && (frame.width < 16 || frame.height < 16)) {
          _focusFrame = null;
        }
      });
      return;
    }
    _activeStroke = null;
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
              SegmentedButton<_EditorTool>(
                segments: [
                  ButtonSegment(
                    value: _EditorTool.brush,
                    icon: const Icon(Icons.brush),
                    label: Text(tr('mask_editor_brush')),
                  ),
                  ButtonSegment(
                    value: _EditorTool.erase,
                    icon: const Icon(Icons.auto_fix_normal),
                    label: Text(tr('mask_editor_eraser')),
                  ),
                  ButtonSegment(
                    value: _EditorTool.frame,
                    icon: const Icon(Icons.crop_free),
                    label: Text(tr('mask_editor_frame')),
                  ),
                ],
                selected: {_tool},
                onSelectionChanged: (selection) {
                  setState(() => _tool = selection.first);
                },
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _tool == _EditorTool.frame
                    ? Row(
                        children: [
                          Expanded(
                            child: Text(
                              _focusFrame == null
                                  ? tr('mask_editor_frame_hint')
                                  : tr('mask_editor_frame_set'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          TextButton.icon(
                            key: const Key('mask-editor-clear-frame'),
                            onPressed: _focusFrame == null
                                ? null
                                : () => setState(() => _focusFrame = null),
                            icon: const Icon(Icons.close),
                            label: Text(tr('inpaint_clear_frame')),
                          ),
                        ],
                      )
                    : Row(
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
                          TextButton(
                            key: const Key('mask-editor-brush-size-input'),
                            onPressed: () => showSliderValueInputDialog(
                              context: context,
                              title: tr('mask_editor_brush_size'),
                              value: _brushSize,
                              min: 8,
                              max: _maxBrushSize,
                              divisions: (_maxBrushSize - 8).round(),
                              decimalPlaces: 0,
                              inputKey:
                                  const Key('mask-editor-brush-size-field'),
                              onChanged: (value) {
                                setState(() => _brushSize = value);
                              },
                            ),
                            child: Text(_brushSize.round().toString()),
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

  CropRect? get _focusFrameAsCropRect {
    final frame = _focusFrame;
    if (frame == null) return null;
    final left = frame.left.floor().clamp(0, widget.imageWidth);
    final top = frame.top.floor().clamp(0, widget.imageHeight);
    final right = frame.right.ceil().clamp(0, widget.imageWidth);
    final bottom = frame.bottom.ceil().clamp(0, widget.imageHeight);
    if (right - left < 8 || bottom - top < 8) return null;
    return CropRect(x: left, y: top, w: right - left, h: bottom - top);
  }

  Future<void> _finish() async {
    final hasPaint = _strokes.any((stroke) => !stroke.isErase);
    if (!hasPaint) {
      Navigator.of(context).pop(
        const MaskEditorResult(maskBytes: null, strokes: [], focusFrame: null),
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
      MaskEditorResult(
        maskBytes: maskBytes,
        strokes: List.of(_strokes),
        focusFrame: _focusFrameAsCropRect,
      ),
    );
  }
}

/// Draws the mask strokes as a translucent red overlay, and the focus frame
/// as a highlighted rectangle with the outside dimmed. The painter works in
/// display space; strokes and frame are stored in image space and scaled here.
class MaskOverlayPainter extends CustomPainter {
  final List<MaskStroke> strokes;
  final double imageWidth;
  final double imageHeight;
  final Rect? focusFrame;

  /// Brush preview circle, in display space. Null hides the preview.
  final Offset? brushPreviewPoint;
  final double brushPreviewRadius;

  MaskOverlayPainter({
    required this.strokes,
    required this.imageWidth,
    required this.imageHeight,
    this.focusFrame,
    this.brushPreviewPoint,
    this.brushPreviewRadius = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = min(size.width / imageWidth, size.height / imageHeight);
    if (strokes.isNotEmpty) {
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

    final frame = focusFrame;
    if (frame != null) {
      final display = Rect.fromLTRB(
        frame.left * scale,
        frame.top * scale,
        frame.right * scale,
        frame.bottom * scale,
      );
      // Dim everything outside the frame so the kept context reads clearly.
      final outside = Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(display),
      );
      canvas.drawPath(outside, Paint()..color = const Color(0x66000000));
      canvas.drawRect(
        display,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0
          ..color = const Color(0xFFFFFFFF),
      );
      canvas.drawRect(
        display,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFF2196F3),
      );
    }

    // Brush size preview under the cursor, white-on-dark double ring so it
    // reads on any image.
    final preview = brushPreviewPoint;
    if (preview != null && brushPreviewRadius > 0) {
      canvas.drawCircle(
        preview,
        brushPreviewRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = const Color(0xB3FFFFFF),
      );
      canvas.drawCircle(
        preview,
        brushPreviewRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = const Color(0x88000000),
      );
    }
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
    final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
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
    final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
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
