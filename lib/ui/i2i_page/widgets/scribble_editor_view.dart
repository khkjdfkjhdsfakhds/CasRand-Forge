import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/data/models/scribble_document.dart';
import 'scribble_color_picker.dart';

class ScribbleEditorResult {
  final Uint8List bytes;
  final ScribbleDocument document;
  const ScribbleEditorResult(this.bytes, this.document);
}

/// Shared drawing for preview and full-resolution output. Erasing happens on
/// a transparent overlay; the original image is never cleared.
void paintScribbleLayer(
    Canvas canvas, Size size, Iterable<ScribbleStroke> strokes) {
  canvas.saveLayer(Offset.zero & size, Paint());
  canvas.clipRect(Offset.zero & size);
  for (final stroke in strokes) {
    if (stroke.points.isEmpty) continue;
    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..blendMode = stroke.erase ? BlendMode.clear : BlendMode.srcOver;
    if (stroke.points.length == 1) {
      canvas.drawCircle(stroke.points.single, stroke.width / 2, paint);
    } else {
      final path = Path()
        ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (final point in stroke.points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      paint.style = PaintingStyle.stroke;
      canvas.drawPath(path, paint);
    }
  }
  canvas.restore();
}

Future<Uint8List> renderScribbleDocument(ScribbleDocument document) async {
  if (document.strokes.isEmpty) return document.originalBytes;
  final codec = await ui.instantiateImageCodec(document.originalBytes);
  ui.Image? original;
  ui.Image? output;
  ui.Picture? picture;
  try {
    original = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = Size(document.width.toDouble(), document.height.toDouble());
    canvas.drawImageRect(
        original,
        Rect.fromLTWH(
            0, 0, original.width.toDouble(), original.height.toDouble()),
        Offset.zero & size,
        Paint());
    paintScribbleLayer(canvas, size, document.strokes);
    picture = recorder.endRecording();
    output = await picture.toImage(document.width, document.height);
    final data = await output.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    output?.dispose();
    picture?.dispose();
    original?.dispose();
    codec.dispose();
  }
}

/// Sample the actual composited artwork at image-pixel coordinates. Render
/// only one pixel; never sample the resized preview or UI overlays.
Future<Color?> sampleScribbleColor(
    ScribbleDocument document, Offset point) async {
  final x = point.dx.floor(), y = point.dy.floor();
  if (x < 0 || y < 0 || x >= document.width || y >= document.height) {
    return null;
  }
  final codec = await ui.instantiateImageCodec(document.originalBytes);
  ui.Image? original;
  ui.Image? pixel;
  ui.Picture? picture;
  try {
    original = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..clipRect(const Rect.fromLTWH(0, 0, 1, 1))
      ..translate(-x.toDouble(), -y.toDouble());
    final size = Size(document.width.toDouble(), document.height.toDouble());
    canvas.drawImageRect(
        original,
        Rect.fromLTWH(
            0, 0, original.width.toDouble(), original.height.toDouble()),
        Offset.zero & size,
        Paint());
    paintScribbleLayer(canvas, size, document.strokes);
    picture = recorder.endRecording();
    pixel = await picture.toImage(1, 1);
    final rgba =
        await pixel.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (rgba == null) throw StateError('Color readback failed');
    return Color.fromARGB(
        rgba.getUint8(3), rgba.getUint8(0), rgba.getUint8(1), rgba.getUint8(2));
  } finally {
    pixel?.dispose();
    picture?.dispose();
    original?.dispose();
    codec.dispose();
  }
}

class ScribbleEditorView extends StatefulWidget {
  final ScribbleDocument document;
  const ScribbleEditorView({super.key, required this.document});

  static Future<ScribbleEditorResult?> open(BuildContext context,
          {required ScribbleDocument document}) =>
      Navigator.of(context).push<ScribbleEditorResult>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ScribbleEditorView(document: document),
      ));

  @override
  State<ScribbleEditorView> createState() => _ScribbleEditorState();
}

class _ScribbleEditorState extends State<ScribbleEditorView> {
  late List<ScribbleStroke> _strokes = List.of(widget.document.strokes);
  final _undo = <List<ScribbleStroke>>[];
  final _redo = <List<ScribbleStroke>>[];
  List<Offset>? _points;
  int? _pointer;
  Color _color = Colors.red;
  Color _strokeColor = Colors.red;
  double _size = 24;
  double _strokeSize = 24;
  bool _erase = false;
  bool _picker = false;
  bool _sampling = false;
  bool _strokeErase = false;
  bool _busy = false;
  bool _saved = false;

  bool get _canEdit => !_busy && !_sampling && _pointer == null;
  ScribbleStroke? get _active => _points == null
      ? null
      : ScribbleStroke(
          points: _points!,
          color: _strokeColor,
          width: _strokeSize,
          erase: _strokeErase);

  void _record() {
    _undo.add(List.of(_strokes));
    _redo.clear();
  }

  void _history(bool backwards) {
    if (!_canEdit) return;
    final source = backwards ? _undo : _redo;
    final target = backwards ? _redo : _undo;
    if (source.isEmpty) return;
    setState(() {
      target.add(List.of(_strokes));
      _strokes = source.removeLast();
    });
  }

  void _endStroke({bool cancelled = false}) {
    if (_pointer == null) return;
    setState(() {
      if (!cancelled) {
        _record();
        _strokes.add(_active!);
      }
      _pointer = null;
      _points = null;
    });
  }

  Future<void> _save() async {
    if (!_canEdit) return;
    setState(() => _busy = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final document = ScribbleDocument(
        originalBytes: widget.document.originalBytes,
        width: widget.document.width,
        height: widget.document.height,
        strokes: _strokes,
      );
      final bytes = await renderScribbleDocument(document);
      if (!mounted) return;
      setState(() => _saved = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        Navigator.of(context).pop(ScribbleEditorResult(bytes, document));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr('scribble_failed'))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sample(Offset position, {required bool quick}) async {
    if (!_canEdit) return;
    setState(() => _sampling = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final color = await sampleScribbleColor(
          ScribbleDocument(
            originalBytes: widget.document.originalBytes,
            width: widget.document.width,
            height: widget.document.height,
            strokes: _strokes,
          ),
          position);
      if (!mounted || color == null) return;
      setState(() {
        _color = color;
        if (!quick) {
          _picker = false;
          _erase = false;
        }
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr('scribble_pick_failed'))));
      }
    } finally {
      if (mounted) setState(() => _sampling = false);
    }
  }

  Future<void> _chooseColor() async {
    final color = await showDialog<Color>(
        context: context, builder: (_) => ScribbleColorPicker(initial: _color));
    if (mounted && color != null) {
      setState(() {
        _color = color;
        _erase = false;
        _picker = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: (!_busy && !_sampling) || _saved,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyC): () {
              if (_canEdit) setState(() => _picker = true);
            },
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (_canEdit && _picker) setState(() => _picker = false);
            },
            const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () =>
                _history(true),
            const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
                _history(true),
            const SingleActivator(LogicalKeyboardKey.keyZ,
                meta: true, shift: true): () => _history(false),
            const SingleActivator(LogicalKeyboardKey.keyZ,
                control: true, shift: true): () => _history(false),
            const SingleActivator(LogicalKeyboardKey.keyB): () {
              if (_canEdit) {
                setState(() {
                  _erase = false;
                  _picker = false;
                });
              }
            },
            const SingleActivator(LogicalKeyboardKey.keyE): () {
              if (_canEdit) {
                setState(() {
                  _erase = true;
                  _picker = false;
                });
              }
            },
          },
          child: Focus(
              autofocus: true,
              child: Scaffold(
                appBar: AppBar(
                  title: Text(tr('scribble_title')),
                  leading: IconButton(
                      key: const Key('scribble-cancel'),
                      tooltip: tr('cancel'),
                      onPressed: (_busy || _sampling)
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close)),
                  actions: [
                    IconButton(
                        key: const Key('scribble-undo'),
                        tooltip: tr('mask_editor_undo'),
                        onPressed: _canEdit && _undo.isNotEmpty
                            ? () => _history(true)
                            : null,
                        icon: const Icon(Icons.undo)),
                    IconButton(
                        key: const Key('scribble-redo'),
                        tooltip: tr('mask_editor_redo'),
                        onPressed: _canEdit && _redo.isNotEmpty
                            ? () => _history(false)
                            : null,
                        icon: const Icon(Icons.redo)),
                    IconButton(
                        key: const Key('scribble-save'),
                        tooltip: tr('confirm'),
                        onPressed: _canEdit ? _save : null,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.check)),
                  ],
                ),
                body: Column(children: [
                  if (_sampling)
                    const LinearProgressIndicator(
                        key: Key('scribble-sampling')),
                  if (_picker)
                    Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(tr('scribble_pick_hint'))),
                  Expanded(
                      child: ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: LayoutBuilder(builder: (_, constraints) {
                      final doc = widget.document;
                      final scale = math.min(constraints.maxWidth / doc.width,
                          constraints.maxHeight / doc.height);
                      final size = Size(doc.width * scale, doc.height * scale);
                      if (scale <= 0) return const SizedBox.shrink();
                      return Center(
                          child: RepaintBoundary(
                              child: Listener(
                        key: const Key('scribble-canvas'),
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) {
                          if (_busy ||
                              _sampling ||
                              _pointer != null ||
                              event.buttons != kPrimaryButton) {
                            return;
                          }
                          if (_picker ||
                              HardwareKeyboard.instance.isControlPressed) {
                            _sample(event.localPosition / scale,
                                quick: !_picker);
                            return;
                          }
                          setState(() {
                            _pointer = event.pointer;
                            _strokeColor = _color;
                            _strokeSize = _size;
                            _strokeErase = _erase;
                            _points = [event.localPosition / scale];
                          });
                        },
                        onPointerMove: (event) {
                          if (event.pointer != _pointer) return;
                          setState(
                              () => _points!.add(event.localPosition / scale));
                        },
                        onPointerUp: (event) {
                          if (event.pointer == _pointer) _endStroke();
                        },
                        onPointerCancel: (event) {
                          if (event.pointer == _pointer) {
                            _endStroke(cancelled: true);
                          }
                        },
                        child: MouseRegion(
                            cursor: _picker
                                ? SystemMouseCursors.precise
                                : SystemMouseCursors.basic,
                            child: ClipRect(
                                child: SizedBox.fromSize(
                                    size: size,
                                    child:
                                        Stack(fit: StackFit.expand, children: [
                                      Image.memory(doc.originalBytes,
                                          fit: BoxFit.fill,
                                          gaplessPlayback: true),
                                      CustomPaint(
                                          painter: _ScribblePainter([
                                        ..._strokes,
                                        if (_active != null) _active!,
                                      ], scale)),
                                    ])))),
                      )));
                    }),
                  )),
                  SafeArea(
                      top: false,
                      child: Padding(
                          padding: const EdgeInsets.all(8),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  ChoiceChip(
                                      key: const Key('scribble-brush'),
                                      label: Text(tr('mask_editor_brush')),
                                      selected: !_erase && !_picker,
                                      onSelected: _canEdit
                                          ? (_) => setState(() {
                                                _erase = false;
                                                _picker = false;
                                              })
                                          : null),
                                  ChoiceChip(
                                      key: const Key('scribble-eraser'),
                                      label: Text(tr('mask_editor_eraser')),
                                      selected: _erase && !_picker,
                                      onSelected: _canEdit
                                          ? (_) => setState(() {
                                                _erase = true;
                                                _picker = false;
                                              })
                                          : null),
                                  ChoiceChip(
                                    key: const Key('scribble-picker'),
                                    avatar: const Icon(Icons.colorize),
                                    label: Text(tr('scribble_eyedropper')),
                                    selected: _picker,
                                    onSelected: _canEdit
                                        ? (_) =>
                                            setState(() => _picker = !_picker)
                                        : null,
                                  ),
                                  OutlinedButton.icon(
                                      key: const Key('scribble-color'),
                                      onPressed: _canEdit ? _chooseColor : null,
                                      icon: Icon(Icons.circle, color: _color),
                                      label: Text(
                                          '${tr('scribble_color')} #${(_color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()} · ${(_color.a * 100).round()}%')),
                                  TextButton.icon(
                                      key: const Key('scribble-clear'),
                                      onPressed: _canEdit && _strokes.isNotEmpty
                                          ? () => setState(() {
                                                _record();
                                                _strokes = [];
                                              })
                                          : null,
                                      icon: const Icon(
                                          Icons.delete_sweep_outlined),
                                      label: Text(tr('scribble_clear'))),
                                ]),
                            Row(children: [
                              Text(
                                  '${tr('scribble_size')} ${_size.round()} px'),
                              Expanded(
                                  child: Slider(
                                      key: const Key('scribble-size'),
                                      value: _size,
                                      min: 1,
                                      max: 200,
                                      label: '${_size.round()} px',
                                      onChanged: _canEdit
                                          ? (v) => setState(() => _size = v)
                                          : null)),
                            ]),
                          ]))),
                ]),
              )),
        ),
      );
}

class _ScribblePainter extends CustomPainter {
  final List<ScribbleStroke> strokes;
  final double scale;
  _ScribblePainter(this.strokes, this.scale);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    paintScribbleLayer(canvas, size / scale, strokes);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScribblePainter oldDelegate) => true;
}
