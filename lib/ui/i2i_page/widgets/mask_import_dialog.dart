import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/use_cases/import_inpaint_mask.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/inpaint_mask_overlay.dart';

enum MaskImportMergeMode { replace, merge }

class MaskImportDialogResult {
  final Uint8List maskBytes;
  final MaskImportMergeMode mergeMode;

  const MaskImportDialogResult({
    required this.maskBytes,
    required this.mergeMode,
  });
}

class MaskImportDialog extends StatefulWidget {
  final Uint8List sourceBytes;
  final Uint8List baseImageBytes;
  final int targetWidth;
  final int targetHeight;
  final InpaintMaskAnalysis analysis;
  final bool hasExistingMask;

  const MaskImportDialog({
    super.key,
    required this.sourceBytes,
    required this.baseImageBytes,
    required this.targetWidth,
    required this.targetHeight,
    required this.analysis,
    required this.hasExistingMask,
  });

  static Future<MaskImportDialogResult?> open(
    BuildContext context, {
    required Uint8List sourceBytes,
    required Uint8List baseImageBytes,
    required int targetWidth,
    required int targetHeight,
    required InpaintMaskAnalysis analysis,
    required bool hasExistingMask,
  }) {
    return showDialog<MaskImportDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => MaskImportDialog(
        sourceBytes: sourceBytes,
        baseImageBytes: baseImageBytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        analysis: analysis,
        hasExistingMask: hasExistingMask,
      ),
    );
  }

  @override
  State<MaskImportDialog> createState() => _MaskImportDialogState();
}

class _MaskImportDialogState extends State<MaskImportDialog> {
  InpaintMaskChannel _channel = InpaintMaskChannel.automatic;
  double _threshold = 128;
  late bool _invert;
  InpaintMaskRenderResult? _preview;
  bool _rendering = true;
  String? _error;
  Timer? _renderDebounce;
  int _renderRevision = 0;

  bool get _aspectMismatch {
    final sourceAspect = widget.analysis.width / widget.analysis.height;
    final targetAspect = widget.targetWidth / widget.targetHeight;
    return (sourceAspect - targetAspect).abs() / targetAspect > 0.01;
  }

  @override
  void initState() {
    super.initState();
    _invert = widget.analysis.suggestedInvertFor(_channel);
    _renderPreview();
  }

  @override
  void dispose() {
    _renderDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 820),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.layers_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tr('mask_import_title'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    key: const Key('mask-import-close'),
                    tooltip: tr('cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildPreviews(),
                      const SizedBox(height: 16),
                      SegmentedButton<InpaintMaskChannel>(
                        key: const Key('mask-import-channel'),
                        segments: [
                          ButtonSegment(
                            value: InpaintMaskChannel.automatic,
                            icon: const Icon(Icons.auto_awesome_outlined),
                            label: Text(tr('mask_import_channel_auto')),
                          ),
                          ButtonSegment(
                            value: InpaintMaskChannel.alpha,
                            icon: const Icon(Icons.opacity_outlined),
                            label: Text(tr('mask_import_channel_alpha')),
                          ),
                          ButtonSegment(
                            value: InpaintMaskChannel.luminance,
                            icon: const Icon(Icons.tonality_outlined),
                            label: Text(tr('mask_import_channel_luminance')),
                          ),
                        ],
                        selected: {_channel},
                        onSelectionChanged: (selection) {
                          final next = selection.single;
                          setState(() {
                            _channel = next;
                            _invert = widget.analysis.suggestedInvertFor(next);
                          });
                          _renderPreview();
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(_channelDescription),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: Text(tr('mask_import_threshold'))),
                          Text(_threshold.round().toString()),
                        ],
                      ),
                      Slider(
                        key: const Key('mask-import-threshold'),
                        value: _threshold,
                        min: 1,
                        max: 254,
                        divisions: 253,
                        onChanged: (value) {
                          setState(() => _threshold = value);
                          _scheduleRender();
                        },
                      ),
                      SwitchListTile(
                        key: const Key('mask-import-invert'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('mask_import_invert')),
                        subtitle: Text(tr('mask_import_invert_hint')),
                        value: _invert,
                        onChanged: (value) {
                          setState(() => _invert = value);
                          _renderPreview();
                        },
                      ),
                      if (_aspectMismatch)
                        _InfoNotice(
                          icon: Icons.warning_amber_rounded,
                          color: Theme.of(context).colorScheme.tertiary,
                          text: tr(
                            'mask_import_aspect_warning',
                            namedArgs: {
                              'source':
                                  '${widget.analysis.width} × ${widget.analysis.height}',
                              'target':
                                  '${widget.targetWidth} × ${widget.targetHeight}',
                            },
                          ),
                        )
                      else if (widget.analysis.width != widget.targetWidth ||
                          widget.analysis.height != widget.targetHeight)
                        _InfoNotice(
                          icon: Icons.aspect_ratio_outlined,
                          color: Theme.of(context).colorScheme.primary,
                          text: tr(
                            'mask_import_resize_notice',
                            namedArgs: {
                              'source':
                                  '${widget.analysis.width} × ${widget.analysis.height}',
                              'target':
                                  '${widget.targetWidth} × ${widget.targetHeight}',
                            },
                          ),
                        ),
                      if (_preview?.isEmpty ?? false)
                        _InfoNotice(
                          icon: Icons.error_outline,
                          color: Theme.of(context).colorScheme.error,
                          text: tr('mask_import_empty'),
                        ),
                      if (_error != null)
                        _InfoNotice(
                          icon: Icons.error_outline,
                          color: Theme.of(context).colorScheme.error,
                          text: _error!,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildActions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreviews() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panels = <Widget>[
          _PreviewPanel(
            title: tr('mask_import_source_preview'),
            child: Image.memory(
              widget.sourceBytes,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ),
          _PreviewPanel(
            title: tr('mask_import_result_preview'),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  widget.baseImageBytes,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                ),
                if (_preview != null)
                  InpaintMaskOverlay(maskBytes: _preview!.pngBytes),
                if (_rendering)
                  const ColoredBox(
                    color: Color(0x55000000),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ];
        if (constraints.maxWidth >= 640) {
          return SizedBox(
            height: 310,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: panels[0]),
                const SizedBox(width: 12),
                Expanded(child: panels[1]),
              ],
            ),
          );
        }
        return Column(
          children: [
            SizedBox(height: 230, child: panels[0]),
            const SizedBox(height: 12),
            SizedBox(height: 230, child: panels[1]),
          ],
        );
      },
    );
  }

  Widget _buildActions(BuildContext context) {
    final canConfirm =
        !_rendering && _error == null && _preview != null && !_preview!.isEmpty;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('cancel')),
        ),
        if (widget.hasExistingMask)
          OutlinedButton.icon(
            key: const Key('mask-import-merge'),
            onPressed:
                canConfirm ? () => _finish(MaskImportMergeMode.merge) : null,
            icon: const Icon(Icons.call_merge),
            label: Text(tr('mask_import_merge')),
          ),
        FilledButton.icon(
          key: const Key('mask-import-replace'),
          onPressed:
              canConfirm ? () => _finish(MaskImportMergeMode.replace) : null,
          icon: const Icon(Icons.check),
          label: Text(
            widget.hasExistingMask
                ? tr('mask_import_replace')
                : tr('mask_import_confirm'),
          ),
        ),
      ],
    );
  }

  String get _channelDescription {
    switch (_channel) {
      case InpaintMaskChannel.automatic:
        return widget.analysis.hasTransparency
            ? tr('mask_import_auto_uses_alpha')
            : tr('mask_import_auto_uses_luminance');
      case InpaintMaskChannel.alpha:
        return widget.analysis.hasAlphaChannel
            ? tr('mask_import_alpha_hint')
            : tr('mask_import_no_alpha_hint');
      case InpaintMaskChannel.luminance:
        return tr('mask_import_luminance_hint');
    }
  }

  void _scheduleRender() {
    _renderDebounce?.cancel();
    _renderDebounce = Timer(const Duration(milliseconds: 120), _renderPreview);
  }

  Future<void> _renderPreview() async {
    _renderDebounce?.cancel();
    final revision = ++_renderRevision;
    setState(() {
      _rendering = true;
      _error = null;
    });
    try {
      final result = await compute(_renderMaskJob, <String, Object>{
        'sourceBytes': widget.sourceBytes,
        'targetWidth': widget.targetWidth,
        'targetHeight': widget.targetHeight,
        'channel': _channel.index,
        'threshold': _threshold.round(),
        'invert': _invert,
      });
      if (!mounted || revision != _renderRevision) return;
      setState(() {
        _preview = result;
        _rendering = false;
      });
    } catch (_) {
      if (!mounted || revision != _renderRevision) return;
      setState(() {
        _rendering = false;
        _error = tr('mask_import_decode_failed');
      });
    }
  }

  void _finish(MaskImportMergeMode mergeMode) {
    final preview = _preview;
    if (preview == null || preview.isEmpty) return;
    Navigator.of(context).pop(
      MaskImportDialogResult(
        maskBytes: preview.pngBytes,
        mergeMode: mergeMode,
      ),
    );
  }
}

InpaintMaskRenderResult _renderMaskJob(Map<String, Object> job) {
  return renderInpaintMask(
    sourceBytes: job['sourceBytes']! as Uint8List,
    targetWidth: job['targetWidth']! as int,
    targetHeight: job['targetHeight']! as int,
    channel: InpaintMaskChannel.values[job['channel']! as int],
    threshold: job['threshold']! as int,
    invert: job['invert']! as bool,
  );
}

class _PreviewPanel extends StatelessWidget {
  final String title;
  final Widget child;

  const _PreviewPanel({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: Colors.black26,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoNotice extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _InfoNotice({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
