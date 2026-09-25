import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The canvas color controls use HSV coordinates, with alpha kept independent
/// from the six-digit RGB field (as on the NovelAI canvas).
class ScribbleColorPicker extends StatefulWidget {
  final Color initial;
  const ScribbleColorPicker({super.key, required this.initial});

  @override
  State<ScribbleColorPicker> createState() => _ScribbleColorPickerState();
}

class _ScribbleColorPickerState extends State<ScribbleColorPicker> {
  late HSVColor _value = HSVColor.fromColor(widget.initial);
  late final _hex = TextEditingController(text: _hexValue(widget.initial));
  bool _invalid = false;
  String _hexValue(Color color) => (color.toARGB32() & 0xffffff)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _update(HSVColor value) => setState(() {
        _value = value;
        _hex.text = _hexValue(value.toColor());
        _invalid = false;
      });

  void _select(Offset point, Size size) => _update(_value
      .withSaturation((point.dx / size.width).clamp(0, 1))
      .withValue((1 - point.dy / size.height).clamp(0, 1)));

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(tr('scribble_color')),
        content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  SizedBox(
                      height: 190,
                      child: LayoutBuilder(builder: (_, constraints) {
                        final size = Size(constraints.maxWidth, 190);
                        return Semantics(
                            label: tr('scribble_color_plane'),
                            value:
                                '${(_value.saturation * 100).round()}%, ${(_value.value * 100).round()}%',
                            child: Focus(
                                onKeyEvent: (_, event) {
                                  if (event is! KeyDownEvent &&
                                      event is! KeyRepeatEvent) {
                                    return KeyEventResult.ignored;
                                  }
                                  final key = event.logicalKey;
                                  if (key == LogicalKeyboardKey.arrowLeft ||
                                      key == LogicalKeyboardKey.arrowRight) {
                                    _update(_value.withSaturation((_value
                                                .saturation +
                                            (key == LogicalKeyboardKey.arrowLeft
                                                ? -.01
                                                : .01))
                                        .clamp(0, 1)));
                                  } else if (key ==
                                          LogicalKeyboardKey.arrowUp ||
                                      key == LogicalKeyboardKey.arrowDown) {
                                    _update(_value.withValue((_value.value +
                                            (key == LogicalKeyboardKey.arrowDown
                                                ? -.01
                                                : .01))
                                        .clamp(0, 1)));
                                  } else {
                                    return KeyEventResult.ignored;
                                  }
                                  return KeyEventResult.handled;
                                },
                                child: MouseRegion(
                                    cursor: SystemMouseCursors.precise,
                                    child: GestureDetector(
                                      key: const Key('scribble-color-plane'),
                                      onPanDown: (d) =>
                                          _select(d.localPosition, size),
                                      onPanUpdate: (d) =>
                                          _select(d.localPosition, size),
                                      child: CustomPaint(
                                          painter: _ColorPlane(_value),
                                          size: size),
                                    ))));
                      })),
                  const SizedBox(height: 12),
                  Text(tr('scribble_hue')),
                  _gradientSlider(
                      'scribble-hue',
                      _value.hue / 360,
                      const [
                        Colors.red,
                        Colors.yellow,
                        Colors.green,
                        Colors.cyan,
                        Colors.blue,
                        Color(0xffff00ff),
                        Colors.red
                      ],
                      (v) => _update(_value.withHue(v * 360))),
                  Text(
                      '${tr('scribble_opacity')} ${(_value.alpha * 100).round()}%'),
                  _gradientSlider(
                      'scribble-alpha',
                      _value.alpha,
                      [
                        _value.toColor().withValues(alpha: 0),
                        _value.toColor().withValues(alpha: 1)
                      ],
                      (v) => _update(_value.withAlpha(v))),
                  const SizedBox(height: 8),
                  SizedBox(
                      height: 36,
                      child: Row(children: [
                        Expanded(child: _preview(widget.initial)),
                        Expanded(child: _preview(_value.toColor())),
                      ])),
                  TextField(
                      key: const Key('scribble-hex'),
                      controller: _hex,
                      decoration: InputDecoration(
                          labelText: 'HEX',
                          prefixText: '#',
                          errorText:
                              _invalid ? tr('scribble_invalid_color') : null),
                      onChanged: (text) {
                        final normalized =
                            text.trim().replaceFirst(RegExp(r'^#'), '');
                        final valid =
                            RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(normalized);
                        setState(() {
                          _invalid = !valid;
                          if (valid) {
                            _value = HSVColor.fromColor(Color(0xff000000 |
                                    int.parse(normalized, radix: 16)))
                                .withAlpha(_value.alpha);
                          }
                        });
                      }),
                  const SizedBox(height: 8),
                  Wrap(
                      children: [
                    Colors.black,
                    Colors.white,
                    Colors.red,
                    Colors.orange,
                    Colors.yellow,
                    Colors.green,
                    Colors.cyan,
                    Colors.blue,
                    Colors.purple,
                    Colors.brown
                  ]
                          .map((color) => IconButton(
                              key: ValueKey(
                                  'scribble-swatch-${_hexValue(color)}'),
                              tooltip: '#${_hexValue(color)}',
                              icon: Icon(Icons.circle, color: color),
                              onPressed: () => _update(HSVColor.fromColor(color)
                                  .withAlpha(_value.alpha))))
                          .toList()),
                ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('cancel'))),
          FilledButton(
              key: const Key('scribble-color-confirm'),
              onPressed: _invalid
                  ? null
                  : () => Navigator.pop(context, _value.toColor()),
              child: Text(tr('confirm'))),
        ],
      );

  Widget _preview(Color color) => CustomPaint(
      painter: const TransparencyGrid(), child: ColoredBox(color: color));

  Widget _gradientSlider(String key, double value, List<Color> colors,
          ValueChanged<double> update) =>
      SizedBox(
          height: 32,
          child: Stack(alignment: Alignment.center, children: [
            Positioned(
                left: 12,
                right: 12,
                height: 16,
                child: CustomPaint(
                    painter: const TransparencyGrid(),
                    child: DecoratedBox(
                        decoration: BoxDecoration(
                            gradient: LinearGradient(colors: colors))))),
            SliderTheme(
                data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    trackHeight: 16,
                    thumbColor: Colors.white,
                    overlayColor: Colors.black12),
                child: Slider(
                    key: Key(key),
                    value: value,
                    semanticFormatterCallback: (v) =>
                        '${(v * (key == 'scribble-hue' ? 360 : 100)).round()}',
                    onChanged: update)),
          ]));
}

class _ColorPlane extends CustomPainter {
  final HSVColor value;
  _ColorPlane(this.value);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(colors: [
            Colors.white,
            HSVColor.fromAHSV(1, value.hue, 1, 1).toColor()
          ]).createShader(rect));
    canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black]).createShader(rect));
    final point =
        Offset(value.saturation * size.width, (1 - value.value) * size.height);
    canvas.drawCircle(
        point,
        6,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
    canvas.drawCircle(
        point,
        6,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_ColorPlane oldDelegate) => oldDelegate.value != value;
}

class TransparencyGrid extends CustomPainter {
  const TransparencyGrid();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xffeeeeee));
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()..color = const Color(0xffbbbbbb);
    for (var y = 0; y < size.height / 8; y++) {
      for (var x = 0; x < size.width / 8; x++) {
        if ((x + y).isEven) {
          canvas.drawRect(Rect.fromLTWH(x * 8.0, y * 8.0, 8, 8), paint);
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TransparencyGrid oldDelegate) => false;
}
