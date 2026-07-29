import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/use_cases/import_inpaint_mask.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/inpaint_mask_overlay.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/mask_import_dialog.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart'
    show
        CropRect,
        FocusInpaintPlan,
        focusFrameMaxArea,
        defaultContextPx,
        latentGrid,
        maxContextPx,
        minContextPx,
        normalizeContextPx;
import 'package:super_clipboard/super_clipboard.dart';

typedef ClipboardMaskImageReader = Future<Uint8List?> Function();

Future<Uint8List?> readClipboardMaskImage() async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return null;
  final reader = await clipboard.read();
  if (!reader.canProvide(Formats.png)) return null;

  final result = Completer<Uint8List?>();
  final progress = reader.getFile(
    Formats.png,
    (file) async {
      try {
        final bytes = await file.readAll();
        if (!result.isCompleted) result.complete(bytes);
      } catch (error, stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      }
    },
    onError: (error) {
      if (!result.isCompleted) result.completeError(error);
    },
  );
  if (progress == null) return null;
  return result.future;
}

class MaskEditorResult {
  /// Rasterized mask PNG (white = repaint) at image resolution. This is null
  /// when a Focus frame should repaint its whole inner region.
  final Uint8List? maskBytes;
  final List<MaskStroke> strokes;
  final Uint8List? baseMaskBytes;

  /// Hand-drawn focus frame in image pixels, or null for automatic framing.
  final CropRect? focusFrame;
  final int contextPx;

  const MaskEditorResult({
    required this.maskBytes,
    required this.strokes,
    this.baseMaskBytes,
    this.focusFrame,
    this.contextPx = defaultContextPx,
  });
}

enum _EditorTool { brush, erase, frame }

/// NovelAI draws inpainting masks on a canvas scaled down by 8. Pen size is
/// measured in that mask canvas, not in full-resolution image pixels.
const double officialMaskBrushMinSize = 1;
const double officialMaskBrushMaxSize = 50;
const double officialMaskBrushDefaultSize = 4;

class _EditorSnapshot {
  final Uint8List? baseMaskBytes;
  final List<MaskStroke> strokes;
  final Rect? focusFrame;

  const _EditorSnapshot({
    required this.baseMaskBytes,
    required this.strokes,
    required this.focusFrame,
  });
}

/// Fullscreen mask editor for inpainting: freehand repaint strokes, plus an
/// optional hand-drawn focus frame that overrides Autocrop.
class MaskEditorView extends StatefulWidget {
  final Uint8List imageBytes;
  final Uint8List? displayImageBytes;
  final int imageWidth;
  final int imageHeight;
  final Uint8List? initialBaseMaskBytes;
  final List<MaskStroke> initialStrokes;
  final CropRect? initialFocusFrame;
  final int initialContextPx;
  final ClipboardMaskImageReader? clipboardImageReader;

  const MaskEditorView({
    super.key,
    required this.imageBytes,
    this.displayImageBytes,
    required this.imageWidth,
    required this.imageHeight,
    this.initialBaseMaskBytes,
    required this.initialStrokes,
    this.initialFocusFrame,
    this.initialContextPx = defaultContextPx,
    this.clipboardImageReader,
  });

  static Future<MaskEditorResult?> open(
    BuildContext context, {
    required Uint8List imageBytes,
    Uint8List? displayImageBytes,
    required int imageWidth,
    required int imageHeight,
    Uint8List? initialBaseMaskBytes,
    required List<MaskStroke> initialStrokes,
    CropRect? initialFocusFrame,
    int initialContextPx = defaultContextPx,
  }) {
    return Navigator.of(context).push<MaskEditorResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => MaskEditorView(
          imageBytes: imageBytes,
          displayImageBytes: displayImageBytes,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          initialBaseMaskBytes: initialBaseMaskBytes,
          initialStrokes: initialStrokes,
          initialFocusFrame: initialFocusFrame,
          initialContextPx: initialContextPx,
        ),
      ),
    );
  }

  @override
  State<MaskEditorView> createState() => _MaskEditorViewState();
}

class _MaskEditorViewState extends State<MaskEditorView> {
  late List<MaskStroke> _strokes;
  final List<_EditorSnapshot> _undoStack = [];
  final List<_EditorSnapshot> _redoStack = [];
  MaskStroke? _activeStroke;
  _EditorTool _tool = _EditorTool.brush;
  late double _brushSize;
  late MaskBrushShape _brushShape;
  Uint8List? _baseMaskBytes;
  ui.Image? _baseMaskImage;
  bool _isImporting = false;
  Rect? _focusFrame;
  Offset? _frameDragStart;
  late int _contextPx;

  /// Cursor position in canvas-local display coordinates, for the brush
  /// preview circle. Null when the pointer is outside the canvas.
  Offset? _hoverPosition;

  @override
  void initState() {
    super.initState();
    _baseMaskBytes = widget.initialBaseMaskBytes;
    _strokes = List.of(widget.initialStrokes);
    _brushSize = _strokes.isEmpty
        ? officialMaskBrushDefaultSize
        : _strokes.last.brushSize
            .clamp(
              officialMaskBrushMinSize,
              officialMaskBrushMaxSize,
            )
            .toDouble();
    _brushShape =
        _strokes.isEmpty ? MaskBrushShape.circle : _strokes.last.shape;
    _contextPx = normalizeContextPx(widget.initialContextPx);
    final initialFrame = widget.initialFocusFrame;
    if (initialFrame != null) {
      _focusFrame = Rect.fromLTWH(
        initialFrame.x.toDouble(),
        initialFrame.y.toDouble(),
        initialFrame.w.toDouble(),
        initialFrame.h.toDouble(),
      );
    }
    _decodeBaseMaskImage();
  }

  @override
  void dispose() {
    _baseMaskImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compactAppBar = MediaQuery.sizeOf(context).width < 600;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () {
          if (!_isImporting) unawaited(_pasteMask());
        },
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () {
          if (!_isImporting) unawaited(_pasteMask());
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: compactAppBar ? null : Text(tr('mask_editor_title')),
            leading: IconButton(
              key: const Key('mask-editor-cancel'),
              icon: const Icon(Icons.close),
              tooltip: tr('cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            actions: [
              IconButton(
                key: const Key('mask-editor-import'),
                icon: _isImporting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_open_outlined),
                tooltip: tr('mask_import_title'),
                onPressed: _isImporting ? null : _importMask,
              ),
              IconButton(
                key: const Key('mask-editor-undo'),
                icon: const Icon(Icons.undo),
                tooltip: tr('mask_editor_undo'),
                onPressed: _undoStack.isEmpty ? null : _undo,
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
                onPressed:
                    _strokes.isEmpty && _baseMaskBytes == null ? null : _clear,
              ),
              const SizedBox(width: 8),
              if (compactAppBar)
                IconButton(
                  key: const Key('mask-editor-done'),
                  onPressed: _finish,
                  icon: const Icon(Icons.check),
                  tooltip: tr('confirm'),
                )
              else
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
                    builder: (context, constraints) =>
                        _buildCanvas(constraints),
                  ),
                ),
              ),
              _buildToolbar(),
            ],
          ),
        ),
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
        key: const Key('mask-editor-canvas'),
        onPanStart: (details) {
          final point = toImageSpace(details.localPosition);
          if (_tool == _EditorTool.frame) {
            _recordUndo();
            setState(() {
              _frameDragStart = point;
              _focusFrame = Rect.fromPoints(point, point);
            });
            return;
          }
          _recordUndo();
          setState(() {
            _activeStroke = MaskStroke(
              isErase: _tool == _EditorTool.erase,
              brushSize: _brushSize.roundToDouble(),
              shape: _brushShape,
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
              _focusFrame = _limitedFocusFrame(start, point);
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
                widget.displayImageBytes ?? widget.imageBytes,
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
                  rasterMask: _baseMaskImage,
                  strokes: _strokes,
                  imageWidth: imageW,
                  imageHeight: imageH,
                  focusFrames: _focusFrame == null
                      ? const <FocusFrameOverlaySpec>[]
                      : [_focusSpecForRect(_focusFrame!)],
                  brushPreviewPoint: showBrushPreview && hover != null
                      ? hover - Offset(offsetX, offsetY)
                      : null,
                  brushPreviewSize: _brushSize.round(),
                  brushPreviewShape: _brushShape,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Rect _limitedFocusFrame(Offset start, Offset end) {
    final delta = end - start;
    final area = delta.dx.abs() * delta.dy.abs();
    if (area <= focusFrameMaxArea || area == 0) {
      return Rect.fromPoints(start, end);
    }
    final scale = sqrt(focusFrameMaxArea / area);
    return Rect.fromPoints(start, start + delta * scale);
  }

  FocusFrameOverlaySpec _focusSpecForRect(Rect outer) {
    final effective = min(
      _contextPx.toDouble(),
      min(
        max(0.0, (outer.width - latentGrid) / 2),
        max(0.0, (outer.height - latentGrid) / 2),
      ),
    );
    return FocusFrameOverlaySpec(
      outer: outer,
      inner: outer.deflate(effective),
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 900;
            final selector = _buildToolSelector(compact: compact);
            final controls = _buildToolControls();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: compact
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(alignment: Alignment.centerLeft, child: selector),
                        const SizedBox(height: 4),
                        controls,
                      ],
                    )
                  : Row(
                      children: [
                        selector,
                        const SizedBox(width: 12),
                        Expanded(child: controls),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildToolSelector({required bool compact}) {
    ButtonSegment<_EditorTool> segment(
      _EditorTool value,
      IconData icon,
      String label,
    ) {
      return ButtonSegment(
        value: value,
        icon: Tooltip(message: label, child: Icon(icon)),
        label: compact ? null : Text(label),
      );
    }

    return SegmentedButton<_EditorTool>(
      segments: [
        segment(_EditorTool.brush, Icons.brush, tr('mask_editor_brush')),
        segment(
          _EditorTool.erase,
          Icons.auto_fix_normal,
          tr('mask_editor_eraser'),
        ),
        segment(_EditorTool.frame, Icons.crop_free, tr('mask_editor_frame')),
      ],
      selected: {_tool},
      onSelectionChanged: (selection) {
        setState(() => _tool = selection.first);
      },
    );
  }

  Widget _buildToolControls() {
    if (_tool == _EditorTool.frame) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
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
                    : () {
                        _recordUndo();
                        setState(() => _focusFrame = null);
                      },
                icon: const Icon(Icons.close),
                label: Text(tr('inpaint_clear_frame')),
              ),
            ],
          ),
          Row(
            children: [
              Flexible(
                child: Text(
                  tr('inpaint_minimum_context_area'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Expanded(
                child: Slider(
                  key: const Key('mask-editor-context-area'),
                  value: _contextPx.toDouble(),
                  min: minContextPx.toDouble(),
                  max: maxContextPx.toDouble(),
                  divisions: (maxContextPx - minContextPx) ~/ latentGrid,
                  onChanged: (value) => setState(
                    () => _contextPx = normalizeContextPx(value.round()),
                  ),
                ),
              ),
              Text('${_contextPx}px'),
            ],
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                tr('mask_editor_brush_size'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              child: Slider(
                key: const Key('mask-editor-brush-size'),
                value: _brushSize.clamp(
                  officialMaskBrushMinSize,
                  officialMaskBrushMaxSize,
                ),
                min: officialMaskBrushMinSize,
                max: officialMaskBrushMaxSize,
                divisions: (officialMaskBrushMaxSize - officialMaskBrushMinSize)
                    .round(),
                onChanged: (value) {
                  setState(() => _brushSize = value.roundToDouble());
                },
              ),
            ),
            TextButton(
              key: const Key('mask-editor-brush-size-input'),
              onPressed: () => showSliderValueInputDialog(
                context: context,
                title: tr('mask_editor_brush_size'),
                value: _brushSize,
                min: officialMaskBrushMinSize,
                max: officialMaskBrushMaxSize,
                divisions: (officialMaskBrushMaxSize - officialMaskBrushMinSize)
                    .round(),
                decimalPlaces: 0,
                inputKey: const Key('mask-editor-brush-size-field'),
                onChanged: (value) {
                  setState(() => _brushSize = value.roundToDouble());
                },
              ),
              child: Text(_brushSize.round().toString()),
            ),
          ],
        ),
        InkWell(
          key: const Key('mask-editor-square-brush-row'),
          onTap: () => setState(() {
            _brushShape = _brushShape == MaskBrushShape.square
                ? MaskBrushShape.circle
                : MaskBrushShape.square;
          }),
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  key: const Key('mask-editor-square-brush'),
                  value: _brushShape == MaskBrushShape.square,
                  onChanged: (value) => setState(() {
                    _brushShape = value == true
                        ? MaskBrushShape.square
                        : MaskBrushShape.circle;
                  }),
                ),
                Flexible(
                  child: Text(
                    tr('mask_editor_square_brush'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  _EditorSnapshot _snapshot() {
    return _EditorSnapshot(
      baseMaskBytes: _baseMaskBytes,
      strokes: _strokes
          .map(
            (stroke) => MaskStroke(
              isErase: stroke.isErase,
              brushSize: stroke.brushSize,
              shape: stroke.shape,
              points: List.of(stroke.points),
            ),
          )
          .toList(growable: false),
      focusFrame: _focusFrame,
    );
  }

  void _recordUndo() {
    _undoStack.add(_snapshot());
    _redoStack.clear();
    if (_undoStack.length > 50) _undoStack.removeAt(0);
  }

  Future<void> _restoreSnapshot(_EditorSnapshot snapshot) async {
    ui.Image? image;
    final bytes = snapshot.baseMaskBytes;
    if (bytes != null) image = await _decodeUiImage(bytes);
    if (!mounted) {
      image?.dispose();
      return;
    }
    setState(() {
      _baseMaskImage?.dispose();
      _baseMaskImage = image;
      _baseMaskBytes = bytes;
      _strokes = snapshot.strokes
          .map(
            (stroke) => MaskStroke(
              isErase: stroke.isErase,
              brushSize: stroke.brushSize,
              shape: stroke.shape,
              points: List.of(stroke.points),
            ),
          )
          .toList();
      _focusFrame = snapshot.focusFrame;
      _activeStroke = null;
    });
  }

  Future<void> _undo() async {
    if (_undoStack.isEmpty) return;
    final previous = _undoStack.removeLast();
    _redoStack.add(_snapshot());
    await _restoreSnapshot(previous);
  }

  Future<void> _redo() async {
    if (_redoStack.isEmpty) return;
    final next = _redoStack.removeLast();
    _undoStack.add(_snapshot());
    await _restoreSnapshot(next);
  }

  void _clear() {
    _recordUndo();
    setState(() {
      _strokes.clear();
      _baseMaskBytes = null;
      _baseMaskImage?.dispose();
      _baseMaskImage = null;
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
    final focusFrame = _focusFrameAsCropRect;
    final hasPaint =
        _baseMaskBytes != null || _strokes.any((stroke) => !stroke.isErase);
    if (!hasPaint) {
      Navigator.of(context).pop(
        MaskEditorResult(
          maskBytes: null,
          strokes: const [],
          baseMaskBytes: null,
          focusFrame: focusFrame,
          contextPx: _contextPx,
        ),
      );
      return;
    }
    final maskBytes = await rasterizeMaskLayers(
      baseMaskBytes: _baseMaskBytes,
      strokes: _strokes,
      imageWidth: widget.imageWidth,
      imageHeight: widget.imageHeight,
    );
    if (!mounted) return;
    if (!inpaintMaskHasSelection(maskBytes)) {
      Navigator.of(context).pop(
        MaskEditorResult(
          maskBytes: null,
          strokes: const [],
          baseMaskBytes: null,
          focusFrame: focusFrame,
          contextPx: _contextPx,
        ),
      );
      return;
    }
    Navigator.of(context).pop(
      MaskEditorResult(
        maskBytes: maskBytes,
        strokes: List.of(_strokes),
        baseMaskBytes: _baseMaskBytes,
        focusFrame: focusFrame,
        contextPx: _contextPx,
      ),
    );
  }

  Future<void> _decodeBaseMaskImage() async {
    final bytes = _baseMaskBytes;
    if (bytes == null) return;
    try {
      final image = await _decodeUiImage(bytes);
      if (!mounted || !identical(bytes, _baseMaskBytes)) {
        image.dispose();
        return;
      }
      setState(() {
        _baseMaskImage?.dispose();
        _baseMaskImage = image;
      });
    } catch (_) {
      // The final request mask remains authoritative. A damaged transient base
      // simply fails to preview instead of crashing the whole editor.
    }
  }

  Future<void> _replaceBaseMask(Uint8List bytes) async {
    final image = await _decodeUiImage(bytes);
    if (!mounted) {
      image.dispose();
      return;
    }
    _recordUndo();
    setState(() {
      _baseMaskImage?.dispose();
      _baseMaskImage = image;
      _baseMaskBytes = bytes;
      _strokes.clear();
      _activeStroke = null;
    });
  }

  Future<void> _importMask() async {
    if (_isImporting) return;
    setState(() => _isImporting = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final sourceBytes = await picked.xFiles.single.readAsBytes();
      await _importMaskBytes(sourceBytes);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('mask_import_decode_failed'))),
      );
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _pasteMask() async {
    if (_isImporting) return;
    setState(() => _isImporting = true);
    try {
      final sourceBytes =
          await (widget.clipboardImageReader ?? readClipboardMaskImage)();
      if (!mounted) return;
      if (sourceBytes == null || sourceBytes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('mask_import_clipboard_no_image'))),
        );
        return;
      }
      await _importMaskBytes(sourceBytes);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('mask_import_decode_failed'))),
      );
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _importMaskBytes(Uint8List sourceBytes) async {
    final analysis = await compute(analyzeInpaintMask, sourceBytes);
    if (!mounted) return;
    Uint8List? currentMask;
    if (_baseMaskBytes != null || _strokes.isNotEmpty) {
      currentMask = await rasterizeMaskLayers(
        baseMaskBytes: _baseMaskBytes,
        strokes: _strokes,
        imageWidth: widget.imageWidth,
        imageHeight: widget.imageHeight,
      );
    }
    final hasExisting = currentMask != null &&
        await compute(inpaintMaskHasSelection, currentMask);
    if (!mounted) return;
    final result = await MaskImportDialog.open(
      context,
      sourceBytes: sourceBytes,
      baseImageBytes: widget.imageBytes,
      targetWidth: widget.imageWidth,
      targetHeight: widget.imageHeight,
      analysis: analysis,
      hasExistingMask: hasExisting,
    );
    if (result == null || !mounted) return;

    var nextMask = result.maskBytes;
    if (result.mergeMode == MaskImportMergeMode.merge && hasExisting) {
      nextMask = await compute(_mergeMaskJob, <String, Object>{
        'existing': currentMask,
        'imported': result.maskBytes,
        'width': widget.imageWidth,
        'height': widget.imageHeight,
      });
    }
    await _replaceBaseMask(nextMask);
  }
}

class FocusFrameOverlaySpec {
  final Rect outer;
  final Rect inner;

  const FocusFrameOverlaySpec({required this.outer, required this.inner});

  factory FocusFrameOverlaySpec.fromPlan(FocusInpaintPlan plan) {
    return FocusFrameOverlaySpec(
      outer: Rect.fromLTWH(
        plan.outer.x.toDouble(),
        plan.outer.y.toDouble(),
        plan.outer.w.toDouble(),
        plan.outer.h.toDouble(),
      ),
      inner: Rect.fromLTWH(
        plan.inner.x.toDouble(),
        plan.inner.y.toDouble(),
        plan.inner.w.toDouble(),
        plan.inner.h.toDouble(),
      ),
    );
  }
}

/// Draws the mask strokes as a translucent red overlay, plus one or more
/// focus frames with their non-repainted Context Region visible inside.
class MaskOverlayPainter extends CustomPainter {
  final ui.Image? rasterMask;
  final List<MaskStroke> strokes;
  final double imageWidth;
  final double imageHeight;
  final Rect? focusFrame;
  final List<FocusFrameOverlaySpec> focusFrames;

  /// Raw pointer position in display space. Null hides the preview.
  final Offset? brushPreviewPoint;
  final int brushPreviewSize;
  final MaskBrushShape brushPreviewShape;

  MaskOverlayPainter({
    this.rasterMask,
    required this.strokes,
    required this.imageWidth,
    required this.imageHeight,
    this.focusFrame,
    this.focusFrames = const <FocusFrameOverlaySpec>[],
    this.brushPreviewPoint,
    this.brushPreviewSize = 4,
    this.brushPreviewShape = MaskBrushShape.circle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = min(size.width / imageWidth, size.height / imageHeight);
    if (rasterMask != null || strokes.isNotEmpty) {
      // Strokes render opaque inside the layer (so erase works via clear);
      // the layer paint applies the translucency on restore.
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = const Color(0x8AFFFFFF),
      );
      final raster = rasterMask;
      if (raster != null) {
        canvas.drawImageRect(
          raster,
          Rect.fromLTWH(
            0,
            0,
            raster.width.toDouble(),
            raster.height.toDouble(),
          ),
          Offset.zero & size,
          Paint()
            ..filterQuality = FilterQuality.none
            ..colorFilter = inpaintMaskRedColorFilter,
        );
      }
      canvas.scale(scale);
      for (final stroke in strokes) {
        final paint = Paint()
          ..color = const Color(0xFFE53935)
          ..isAntiAlias = false;
        if (stroke.isErase) {
          paint.blendMode = BlendMode.clear;
        }
        _paintOfficialMaskStroke(canvas, stroke, paint);
      }
      canvas.restore();
    }

    final frames = focusFrames.isNotEmpty
        ? focusFrames
        : focusFrame == null
            ? const <FocusFrameOverlaySpec>[]
            : [
                FocusFrameOverlaySpec(
                  outer: focusFrame!,
                  inner: focusFrame!,
                ),
              ];
    if (frames.isNotEmpty) {
      var visible = Path();
      final displayFrames = <FocusFrameOverlaySpec>[];
      for (final frame in frames) {
        final outer = Rect.fromLTRB(
          frame.outer.left * scale,
          frame.outer.top * scale,
          frame.outer.right * scale,
          frame.outer.bottom * scale,
        );
        final inner = Rect.fromLTRB(
          frame.inner.left * scale,
          frame.inner.top * scale,
          frame.inner.right * scale,
          frame.inner.bottom * scale,
        );
        visible = Path.combine(
          PathOperation.union,
          visible,
          Path()..addRect(outer),
        );
        displayFrames.add(FocusFrameOverlaySpec(outer: outer, inner: inner));
      }
      final outside = Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        visible,
      );
      canvas.drawPath(outside, Paint()..color = const Color(0x66000000));
      for (final frame in displayFrames) {
        if (frame.inner != frame.outer) {
          final contextBand = Path.combine(
            PathOperation.difference,
            Path()..addRect(frame.outer),
            Path()..addRect(frame.inner),
          );
          canvas.drawPath(
            contextBand,
            Paint()..color = const Color(0x44EF5350),
          );
          canvas.drawRect(
            frame.inner,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = const Color(0xDDEF5350),
          );
        }
        canvas.drawRect(
          frame.outer,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.0
            ..color = const Color(0xFFFFFFFF),
        );
        canvas.drawRect(
          frame.outer,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xFF2196F3),
        );
      }
    }

    // NovelAI previews the exact low-resolution mask cells, including their
    // stepped boundary, with a fixed-size crosshair at the raw pointer.
    final preview = brushPreviewPoint;
    if (preview != null && brushPreviewSize > 0) {
      _drawOfficialBrushPreview(
        canvas,
        pointer: preview,
        penSize: brushPreviewSize,
        shape: brushPreviewShape,
        cellSize: latentGrid * scale,
      );
    }
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
  return rasterizeMaskLayers(
    strokes: strokes,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
}

/// Rasterizes an optional imported base plus subsequent brush/eraser strokes.
Future<Uint8List> rasterizeMaskLayers({
  Uint8List? baseMaskBytes,
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
  ui.Image? baseMask;
  if (baseMaskBytes != null) {
    baseMask = await _decodeUiImage(baseMaskBytes);
    canvas.drawImageRect(
      baseMask,
      Rect.fromLTWH(
        0,
        0,
        baseMask.width.toDouble(),
        baseMask.height.toDouble(),
      ),
      Rect.fromLTWH(0, 0, imageWidth.toDouble(), imageHeight.toDouble()),
      Paint()..filterQuality = FilterQuality.none,
    );
  }
  for (final stroke in strokes) {
    final color =
        stroke.isErase ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;
    _paintOfficialMaskStroke(canvas, stroke, paint);
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
    baseMask?.dispose();
  }
}

final Map<int, List<Point<int>>> _officialCircleCellsCache = {};
final Map<int, Path> _officialCircleStampPathCache = {};
final Map<int, Path> _officialCircleBoundaryPathCache = {};

int _officialPenSize(num value) => value
    .round()
    .clamp(
      officialMaskBrushMinSize.toInt(),
      officialMaskBrushMaxSize.toInt(),
    )
    .toInt();

int _jsRound(double value) => (value + 0.5).floor();

/// The exact discrete circle used by NovelAI's current mask editor for sizes
/// 4-50, plus useful CasRand Forge extensions for sizes 1-3.
///
/// Each point is one pixel on the 1/8-resolution mask canvas. NovelAI tests
/// the nearest pixel corner against `round(penSize / 2)`, producing the
/// stepped 4/26/50-size outlines shown by the official cursor.
List<Point<int>> officialMaskCircleCells(int penSize) {
  final size = _officialPenSize(penSize);
  return _officialCircleCellsCache.putIfAbsent(size, () {
    if (size == 1) return const [Point(0, 0)];
    if (size == 2) {
      return const [Point(0, 0), Point(1, 0), Point(0, 1), Point(1, 1)];
    }
    if (size == 3) {
      return const [
        Point(0, -1),
        Point(-1, 0),
        Point(0, 0),
        Point(1, 0),
        Point(0, 1),
      ];
    }
    final radius = _jsRound(size / 2);
    final cells = <Point<int>>[];
    for (var y = -radius; y <= radius; y++) {
      for (var x = -radius; x <= radius; x++) {
        final innerX = max(0.0, x.abs() - 0.5);
        final innerY = max(0.0, y.abs() - 0.5);
        if (sqrt(innerX * innerX + innerY * innerY) <= radius) {
          cells.add(Point(x, y));
        }
      }
    }
    return List.unmodifiable(cells);
  });
}

Point<int> _circleStampOrigin(Offset maskPoint, int penSize) {
  if (penSize == 2) {
    return Point(
      _jsRound(maskPoint.dx - penSize / 2),
      _jsRound(maskPoint.dy - penSize / 2),
    );
  }
  return Point(maskPoint.dx.floor(), maskPoint.dy.floor());
}

Path _officialCircleStampPath(int penSize) {
  final size = _officialPenSize(penSize);
  return _officialCircleStampPathCache.putIfAbsent(size, () {
    final path = Path();
    for (final cell in officialMaskCircleCells(size)) {
      path.addRect(
        Rect.fromLTWH(
          cell.x * latentGrid.toDouble(),
          cell.y * latentGrid.toDouble(),
          latentGrid.toDouble(),
          latentGrid.toDouble(),
        ),
      );
    }
    return path;
  });
}

Path _officialCircleBoundaryPath(int penSize) {
  final size = _officialPenSize(penSize);
  return _officialCircleBoundaryPathCache.putIfAbsent(size, () {
    final cells = officialMaskCircleCells(size);
    final occupied = <Point<int>>{...cells};
    final path = Path();
    for (final cell in cells) {
      final left = cell.x.toDouble();
      final top = cell.y.toDouble();
      if (!occupied.contains(Point(cell.x, cell.y - 1))) {
        path
          ..moveTo(left, top)
          ..lineTo(left + 1, top);
      }
      if (!occupied.contains(Point(cell.x, cell.y + 1))) {
        path
          ..moveTo(left, top + 1)
          ..lineTo(left + 1, top + 1);
      }
      if (!occupied.contains(Point(cell.x - 1, cell.y))) {
        path
          ..moveTo(left, top)
          ..lineTo(left, top + 1);
      }
      if (!occupied.contains(Point(cell.x + 1, cell.y))) {
        path
          ..moveTo(left + 1, top)
          ..lineTo(left + 1, top + 1);
      }
    }
    return path;
  });
}

Iterable<Offset> _officialStampPoints(MaskStroke stroke) sync* {
  if (stroke.points.isEmpty) return;
  final penSize = _officialPenSize(stroke.brushSize);
  final radius = _jsRound(penSize / 2);
  final maskPoints = stroke.points
      .map((point) => point / latentGrid.toDouble())
      .toList(growable: false);
  yield maskPoints.first;
  // The official 4-50 range spaces stamps by at most one mask pixel at the
  // small end. Forge's 1-3 extension uses half a cell so floating-point
  // interpolation cannot skip the only selected cell in a size-1 stroke.
  final spacing = penSize <= 3 ? 0.5 : max(1.0, radius * 0.25);
  for (var index = 1; index < maskPoints.length; index++) {
    final start = maskPoints[index - 1];
    final end = maskPoints[index];
    final steps = max(1, ((end - start).distance / spacing).ceil());
    for (var step = 1; step <= steps; step++) {
      yield Offset.lerp(start, end, step / steps)!;
    }
  }
}

void _paintOfficialMaskStroke(
  Canvas canvas,
  MaskStroke stroke,
  Paint paint,
) {
  final penSize = _officialPenSize(stroke.brushSize);
  final cellSize = latentGrid.toDouble();
  for (final point in _officialStampPoints(stroke)) {
    if (stroke.shape == MaskBrushShape.square) {
      final left = _jsRound(point.dx - penSize / 2);
      final top = _jsRound(point.dy - penSize / 2);
      canvas.drawRect(
        Rect.fromLTWH(
          left * cellSize,
          top * cellSize,
          penSize * cellSize,
          penSize * cellSize,
        ),
        paint,
      );
      continue;
    }
    final origin = _circleStampOrigin(point, penSize);
    canvas.save();
    canvas.translate(origin.x * cellSize, origin.y * cellSize);
    canvas.drawPath(_officialCircleStampPath(penSize), paint);
    canvas.restore();
  }
}

void _drawOfficialBrushPreview(
  Canvas canvas, {
  required Offset pointer,
  required int penSize,
  required MaskBrushShape shape,
  required double cellSize,
}) {
  final size = _officialPenSize(penSize);
  final maskPoint = pointer / cellSize;
  void drawBoundary(Path boundary, Color color, double width) {
    canvas.drawPath(
      boundary,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  if (shape == MaskBrushShape.square) {
    final left = _jsRound(maskPoint.dx - size / 2) * cellSize;
    final top = _jsRound(maskPoint.dy - size / 2) * cellSize;
    final boundary = Path()
      ..addRect(
        Rect.fromLTWH(left, top, size * cellSize, size * cellSize),
      );
    drawBoundary(boundary, const Color(0x80FFFFFF), 2);
    drawBoundary(boundary, const Color(0xCC000000), 1);
  } else {
    final origin = _circleStampOrigin(maskPoint, size);
    canvas.save();
    canvas.translate(origin.x * cellSize, origin.y * cellSize);
    canvas.scale(cellSize);
    final boundary = _officialCircleBoundaryPath(size);
    drawBoundary(boundary, const Color(0x80FFFFFF), 2 / cellSize);
    drawBoundary(boundary, const Color(0xCC000000), 1 / cellSize);
    canvas.restore();
  }

  final crosshair = Path()
    ..moveTo(pointer.dx - 5, pointer.dy)
    ..lineTo(pointer.dx + 5, pointer.dy)
    ..moveTo(pointer.dx, pointer.dy - 5)
    ..lineTo(pointer.dx, pointer.dy + 5);
  canvas.drawPath(
    crosshair,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0x80FFFFFF),
  );
  canvas.drawPath(
    crosshair,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xE6000000),
  );
}

Future<ui.Image> _decodeUiImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}

Uint8List _mergeMaskJob(Map<String, Object> job) {
  return mergeInpaintMasks(
    existingMaskBytes: job['existing']! as Uint8List,
    importedMaskBytes: job['imported']! as Uint8List,
    targetWidth: job['width']! as int,
    targetHeight: job['height']! as int,
  );
}
