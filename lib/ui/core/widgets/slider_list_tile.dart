import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

String _formatSliderValue(double value, int decimalPlaces) {
  if (decimalPlaces <= 0) return value.round().toString();
  return value.toStringAsFixed(decimalPlaces);
}

int _decimalPlacesForStep(double step) {
  for (var places = 0; places <= 4; places++) {
    final scaled = step * _pow10(places);
    if ((scaled - scaled.round()).abs() < 1e-8) return places;
  }
  return 4;
}

double _pow10(int exponent) {
  var result = 1.0;
  for (var i = 0; i < exponent; i++) {
    result *= 10;
  }
  return result;
}

double _snapSliderValue({
  required double value,
  required double min,
  required double max,
  required int divisions,
  required int decimalPlaces,
}) {
  final step = (max - min) / divisions;
  final snapped = min + ((value - min) / step).round() * step;
  return double.parse(
    snapped.clamp(min, max).toStringAsFixed(decimalPlaces),
  );
}

String _inputTitleFrom(String title) {
  final match = RegExp(r'^(.+?)[：:][^：:]*$').firstMatch(title);
  return match?.group(1)?.trim() ?? title;
}

Future<void> showSliderValueInputDialog({
  required BuildContext context,
  required String title,
  required double value,
  required double min,
  required double max,
  required int divisions,
  required ValueChanged<double> onChanged,
  int? decimalPlaces,
  Key? inputKey,
}) async {
  final step = (max - min) / divisions;
  final places = decimalPlaces ?? _decimalPlacesForStep(step);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _SliderValueInputDialog(
      title: title,
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      decimalPlaces: places,
      inputKey: inputKey,
      onChanged: onChanged,
    ),
  );
}

class _SliderValueInputDialog extends StatefulWidget {
  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final int decimalPlaces;
  final Key? inputKey;
  final ValueChanged<double> onChanged;

  const _SliderValueInputDialog({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.decimalPlaces,
    required this.inputKey,
    required this.onChanged,
  });

  @override
  State<_SliderValueInputDialog> createState() =>
      _SliderValueInputDialogState();
}

class _SliderValueInputDialogState extends State<_SliderValueInputDialog> {
  late final TextEditingController controller;
  String? errorText;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(
      text: _formatSliderValue(widget.value, widget.decimalPlaces),
    );
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    final parsed = double.tryParse(
      controller.text.trim().replaceAll(',', '.'),
    );
    if (parsed == null ||
        !parsed.isFinite ||
        parsed < widget.min ||
        parsed > widget.max) {
      setState(() => errorText = tr('slider_invalid_value'));
      return;
    }
    widget.onChanged(
      _snapSliderValue(
        value: parsed,
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        decimalPlaces: widget.decimalPlaces,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final step = (widget.max - widget.min) / widget.divisions;
    return AlertDialog(
      title: Text('${tr('edit')}${tr('colon')}${widget.title}'),
      content: TextField(
        key: widget.inputKey,
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.numberWithOptions(
          decimal: widget.decimalPlaces > 0,
          signed: widget.min < 0,
        ),
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          helperText: tr(
            'slider_value_helper',
            namedArgs: {
              'min': _formatSliderValue(widget.min, widget.decimalPlaces),
              'max': _formatSliderValue(widget.max, widget.decimalPlaces),
              'step': _formatSliderValue(step, widget.decimalPlaces),
            },
          ),
          errorText: errorText,
        ),
        onSubmitted: (_) => submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('cancel')),
        ),
        TextButton(
          onPressed: submit,
          child: Text(tr('confirm')),
        ),
      ],
    );
  }
}

class _RangeValueInputDialog extends StatefulWidget {
  final String title;
  final double start;
  final double end;
  final double min;
  final double max;
  final int divisions;
  final int decimalPlaces;
  final Function(double, double) onChanged;

  const _RangeValueInputDialog({
    required this.title,
    required this.start,
    required this.end,
    required this.min,
    required this.max,
    required this.divisions,
    required this.decimalPlaces,
    required this.onChanged,
  });

  @override
  State<_RangeValueInputDialog> createState() => _RangeValueInputDialogState();
}

class _RangeValueInputDialogState extends State<_RangeValueInputDialog> {
  late final TextEditingController startController;
  late final TextEditingController endController;
  String? errorText;

  @override
  void initState() {
    super.initState();
    startController = TextEditingController(
      text: _formatSliderValue(widget.start, widget.decimalPlaces),
    );
    endController = TextEditingController(
      text: _formatSliderValue(widget.end, widget.decimalPlaces),
    );
  }

  @override
  void dispose() {
    startController.dispose();
    endController.dispose();
    super.dispose();
  }

  void submit() {
    final start = double.tryParse(
      startController.text.trim().replaceAll(',', '.'),
    );
    final end = double.tryParse(
      endController.text.trim().replaceAll(',', '.'),
    );
    if (start == null ||
        end == null ||
        !start.isFinite ||
        !end.isFinite ||
        start < widget.min ||
        end > widget.max ||
        start > end) {
      setState(() => errorText = tr('slider_invalid_range'));
      return;
    }
    widget.onChanged(
      _snapSliderValue(
        value: start,
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        decimalPlaces: widget.decimalPlaces,
      ),
      _snapSliderValue(
        value: end,
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        decimalPlaces: widget.decimalPlaces,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final step = (widget.max - widget.min) / widget.divisions;
    return AlertDialog(
      title: Text('${tr('edit')}${tr('colon')}${widget.title}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('range-slider-start-input'),
            controller: startController,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(
              decimal: widget.decimalPlaces > 0,
              signed: widget.min < 0,
            ),
            decoration: InputDecoration(labelText: tr('range_start')),
          ),
          TextField(
            key: const Key('range-slider-end-input'),
            controller: endController,
            keyboardType: TextInputType.numberWithOptions(
              decimal: widget.decimalPlaces > 0,
              signed: widget.min < 0,
            ),
            decoration: InputDecoration(
              labelText: tr('range_end'),
              helperText: tr(
                'slider_value_helper',
                namedArgs: {
                  'min': _formatSliderValue(widget.min, widget.decimalPlaces),
                  'max': _formatSliderValue(widget.max, widget.decimalPlaces),
                  'step': _formatSliderValue(step, widget.decimalPlaces),
                },
              ),
              errorText: errorText,
            ),
            onSubmitted: (_) => submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('cancel')),
        ),
        TextButton(
          onPressed: submit,
          child: Text(tr('confirm')),
        ),
      ],
    );
  }
}

class SliderListTile extends StatelessWidget {
  final String title;
  final double sliderValue;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTitleTap;
  final String? inputTitle;
  final int? inputDecimalPlaces;
  final Key? inputKey;

  const SliderListTile({
    super.key,
    required this.title,
    required this.sliderValue,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.leading,
    this.trailing,
    this.onTitleTap,
    this.inputTitle,
    this.inputDecimalPlaces,
    this.inputKey,
  });

  void _showInput(BuildContext context) {
    if (onChanged == null) return;
    showSliderValueInputDialog(
      context: context,
      title: inputTitle ?? _inputTitleFrom(title),
      value: sliderValue,
      min: min,
      max: max,
      divisions: divisions,
      onChanged: onChanged!,
      decimalPlaces: inputDecimalPlaces,
      inputKey: inputKey,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: Text(title),
          leading: leading,
          trailing: trailing ??
              (onChanged == null
                  ? null
                  : IconButton(
                      tooltip: tr('edit'),
                      onPressed: () => _showInput(context),
                      icon: const Icon(Icons.edit_outlined),
                    )),
          onTap: onTitleTap ??
              (onChanged == null ? null : () => _showInput(context)),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            height: kMinInteractiveDimension,
            child: Slider(
                value: sliderValue.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged),
          ),
        )
      ],
    );
  }
}

class RangeListTile extends StatelessWidget {
  final String title;
  final double sliderStart;
  final double sliderEnd;
  final double min;
  final double max;
  final int divisions;
  final Function(double, double) onChanged;
  final Widget? leading;
  final int? inputDecimalPlaces;

  const RangeListTile({
    super.key,
    required this.title,
    required this.sliderStart,
    required this.sliderEnd,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.leading,
    this.inputDecimalPlaces,
  });

  Future<void> _showInput(BuildContext context) async {
    final step = (max - min) / divisions;
    final places = inputDecimalPlaces ?? _decimalPlacesForStep(step);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _RangeValueInputDialog(
        title: _inputTitleFrom(title),
        start: sliderStart,
        end: sliderEnd,
        min: min,
        max: max,
        divisions: divisions,
        decimalPlaces: places,
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: Text(title),
          leading: leading,
          trailing: IconButton(
            tooltip: tr('edit'),
            onPressed: () => _showInput(context),
            icon: const Icon(Icons.edit_outlined),
          ),
          onTap: () => _showInput(context),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            height: kMinInteractiveDimension,
            child: RangeSlider(
                values: RangeValues(
                    sliderStart.clamp(min, max), sliderEnd.clamp(min, max)),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: (range) => onChanged(range.start, range.end)),
          ),
        )
      ],
    );
  }
}
