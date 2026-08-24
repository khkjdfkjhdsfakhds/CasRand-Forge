import 'dart:math';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/image_formats.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';
import 'package:nai_casrand/data/use_cases/i2i_request_size.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/utils/platform_support.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/widgets/result_actions.dart';
import 'package:nai_casrand/ui/i2i_page/view_models/i2i_page_viewmodel.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/inpaint_mask_overlay.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/mask_editor_view.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

typedef InpaintImagePreparer = Future<void> Function(
  BuildContext context,
  Uint8List bytes,
);

typedef FocusPreviewPlanner = Future<FocusInpaintBatch?> Function(
  I2IConfig config,
);

/// The 图生图 / 局部重绘 destination: base image, img2img parameters and
/// inpainting (mask, Autocrop or a hand-drawn focus frame) in one place,
/// with its own generate button.
class I2iPageView extends StatefulWidget {
  final I2iPageViewmodel viewmodel;
  final InpaintImagePreparer? inpaintImagePreparer;
  final FocusPreviewPlanner? focusPreviewPlanner;

  const I2iPageView({
    super.key,
    required this.viewmodel,
    this.inpaintImagePreparer,
    this.focusPreviewPlanner,
  });

  @override
  State<I2iPageView> createState() => _I2iPageViewState();
}

class _I2iPageViewState extends State<I2iPageView> {
  final ScrollController _scrollController = ScrollController();
  late final NavigationRequest _navigation;
  int _entryGeneration = 0;
  String? _focusPreviewKey;
  Future<FocusInpaintBatch?>? _focusPreviewFuture;

  I2iPageViewmodel get viewmodel => widget.viewmodel;
  ImageHandoffCoordinator? get _handoff =>
      GetIt.I.isRegistered<ImageHandoffCoordinator>()
          ? GetIt.I<ImageHandoffCoordinator>()
          : null;

  Future<FocusInpaintBatch?>? _focusPreviewFor(I2IConfig config) {
    final automaticFocusActive = config.autocropEnabled &&
        autocropAppliesToImage(config.width, config.height);
    if (!config.hasInpaintSelection ||
        (config.manualFocusFrame == null && !automaticFocusActive)) {
      _focusPreviewKey = null;
      _focusPreviewFuture = null;
      return null;
    }
    final key = '${identityHashCode(config)}|${config.planRevision}|'
        '${config.requestSize.width}x${config.requestSize.height}';
    if (_focusPreviewKey != key) {
      _focusPreviewKey = key;
      _focusPreviewFuture = widget.focusPreviewPlanner?.call(config) ??
          PrepareI2iRequestUseCase(config: config).planFocusPreview(
            targetWidth: config.requestSize.width,
            targetHeight: config.requestSize.height,
          );
    }
    return _focusPreviewFuture;
  }

  @override
  void initState() {
    super.initState();
    _navigation = GetIt.I<NavigationRequest>();
    _navigation.i2iEntryRevision.addListener(_scheduleApplyEntryMode);
    // Act on how the page was entered ("use as base image", "inpaint").
    _scheduleApplyEntryMode();
  }

  @override
  void dispose() {
    _navigation.i2iEntryRevision.removeListener(_scheduleApplyEntryMode);
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleApplyEntryMode() {
    final generation = ++_entryGeneration;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _applyEntryMode(generation),
    );
  }

  Future<void> _applyEntryMode(int generation) async {
    if (!mounted || generation != _entryGeneration) return;
    final mode = _navigation.takeI2iEntryMode();
    if (mode == I2iEntryMode.inpaint && viewmodel.config.hasImage) {
      final originalBytes = viewmodel.config.imageBytes!;
      final displayBytes = viewmodel.config.displayImageBytes!;
      final prepareImage = widget.inpaintImagePreparer ?? _precacheInpaintImage;
      await prepareImage(context, displayBytes);
      if (!mounted ||
          generation != _entryGeneration ||
          !identical(viewmodel.config.imageBytes, originalBytes)) {
        return;
      }
      await _openMaskEditor(context);
    }
  }

  Future<void> _precacheInpaintImage(
    BuildContext context,
    Uint8List bytes,
  ) async {
    await precacheImage(MemoryImage(bytes), context);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        viewmodel,
        if (_handoff != null) _handoff!,
      ]),
      builder: (context, _) {
        return Scaffold(
          key: const Key('i2i-page-frame'),
          body: Column(
            children: [
              _buildPrimaryAction(context),
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    _buildBaseImageCard(context),
                    _buildGenerationCard(context),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBaseImageCard(BuildContext context) {
    final config = viewmodel.config;
    final Widget preview;
    final handoffAction = _activeI2iHandoffAction;
    if (handoffAction != null &&
        (_handoff?.isPreparing(handoffAction) ?? false)) {
      preview = _buildHandoffLoading(handoffAction);
    } else if (handoffAction != null &&
        (_handoff?.hasFailed(handoffAction) ?? false)) {
      preview = _buildHandoffFailure(
        context,
        handoffAction,
      );
    } else if (config.hasImage) {
      preview = LayoutBuilder(
        builder: (context, constraints) {
          final aspectRatio = config.width / config.height;
          final widthAtMaxHeight = 320.0 * aspectRatio;
          final displayWidth = widthAtMaxHeight < constraints.maxWidth
              ? widthAtMaxHeight
              : constraints.maxWidth;
          final displayHeight = displayWidth / aspectRatio;
          final focusPreview = _focusPreviewFor(config);
          return Center(
            child: SizedBox(
              key: const Key('i2i-image-preview-stack'),
              width: displayWidth,
              height: displayHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    config.displayImageBytes!,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                  ),
                  if (config.hasMask)
                    InpaintMaskOverlay(
                      key: const Key('i2i-mask-preview-raster'),
                      maskBytes: config.maskBytes!,
                    ),
                  if (focusPreview != null)
                    FutureBuilder<FocusInpaintBatch?>(
                      future: focusPreview,
                      builder: (context, snapshot) {
                        final error = snapshot.error;
                        if (error != null) {
                          final message =
                              error is FocusInpaintTileLimitException
                                  ? tr(
                                      'inpaint_autocrop_too_many_tiles',
                                      namedArgs: {
                                        'count': error.tileCount.toString(),
                                        'max': error.maxTiles.toString(),
                                      },
                                    )
                                  : tr('inpaint_autocrop_planning_failed');
                          return IgnorePointer(
                            child: ColoredBox(
                              key: const Key('i2i-focus-preview-error'),
                              color: Colors.black54,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                    message,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }
                        final batch = snapshot.data;
                        final manual = config.manualFocusFrame;
                        final specs = batch != null
                            ? batch.tiles
                                .map(FocusFrameOverlaySpec.fromPlan)
                                .toList(growable: false)
                            : manual == null
                                ? const <FocusFrameOverlaySpec>[]
                                : [
                                    _manualFocusOverlaySpec(
                                      manual,
                                      config.contextPx,
                                    ),
                                  ];
                        return IgnorePointer(
                          child: CustomPaint(
                            key: const Key('i2i-mask-preview-overlay'),
                            painter: MaskOverlayPainter(
                              strokes: const <MaskStroke>[],
                              imageWidth: config.width.toDouble(),
                              imageHeight: config.height.toDouble(),
                              focusFrames: specs,
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          );
        },
      );
    } else {
      preview = SizedBox(
        height: 220,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.add_photo_alternate_outlined,
              size: 96,
              color: Theme.of(context).disabledColor,
            ),
            const SizedBox(height: 8),
            Text(
              tr('i2i_drop_hint'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).disabledColor),
            ),
          ],
        ),
      );
    }

    final dropChild = InkWell(
      key: const Key('i2i-import-image-area'),
      onTap: () => _importImage(context),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 1.2,
          ),
          borderRadius: BorderRadius.circular(12.0),
        ),
        padding: const EdgeInsets.all(8.0),
        child: preview,
      ),
    );

    final dropArea = supportsSuperNativeExtensions
        ? DropRegion(
            formats: Formats.standardFormats,
            onDropOver: (_) => DropOperation.copy,
            onPerformDrop: (event) => _handleDrop(context, event),
            child: dropChild,
          )
        : dropChild;

    final imageWorkspace = Stack(
      children: [
        dropArea,
        Positioned(
          top: 12,
          right: 12,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (config.hasInpaintSelection) ...[
                Tooltip(
                  message: tr('inpaint_clear_mask'),
                  child: FilledButton.tonal(
                    key: const Key('inpaint-clear-mask'),
                    onPressed: viewmodel.clearMask,
                    style: FilledButton.styleFrom(
                      fixedSize: const Size.square(48),
                      padding: EdgeInsets.zero,
                    ),
                    child: const Icon(Icons.layers_clear_outlined),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Tooltip(
                message: tr('inpaint_edit_mask'),
                child: FilledButton.tonalIcon(
                  key: const Key('inpaint-edit-mask'),
                  onPressed: () => _startInpainting(context),
                  icon: const Icon(Icons.brush_outlined),
                  label: Text(tr('inpaint_section')),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: Text(tr('i2i_base_image')),
              subtitle: viewmodel.config.hasImage
                  ? Text(
                      '${viewmodel.config.width} × ${viewmodel.config.height}',
                    )
                  : Text(tr('i2i_page_sections_hint')),
              trailing: Switch(
                key: const Key('i2i-feature-switch'),
                value: viewmodel.enabled,
                onChanged: config.hasImage ? viewmodel.setEnabled : null,
              ),
            ),
            imageWorkspace,
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  key: const Key('i2i-import-image-button'),
                  onPressed: () => _importImage(context),
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(tr('i2i_import_image')),
                ),
                if (viewmodel.config.hasImage)
                  TextButton.icon(
                    key: const Key('i2i-remove-image-button'),
                    onPressed: viewmodel.removeImage,
                    icon: const Icon(Icons.delete_outline),
                    label: Text(tr('i2i_remove_image')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  ImageHandoffAction? get _activeI2iHandoffAction {
    final action = _handoff?.action;
    return action == ImageHandoffAction.imageToImage ||
            action == ImageHandoffAction.inpaint
        ? action
        : null;
  }

  Widget _buildHandoffLoading(ImageHandoffAction action) {
    return SizedBox(
      key: Key('image-handoff-loading-${action.name}'),
      height: 180,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(tr('image_handoff_preparing')),
          ],
        ),
      ),
    );
  }

  Widget _buildHandoffFailure(
    BuildContext context,
    ImageHandoffAction action,
  ) {
    return SizedBox(
      key: Key('image-handoff-error-${action.name}'),
      height: 180,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 8),
            Text(tr('image_handoff_failed')),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: Key('image-handoff-retry-${action.name}'),
              onPressed: _handoff?.retry,
              icon: const Icon(Icons.refresh),
              label: Text(tr('retry')),
            ),
          ],
        ),
      ),
    );
  }

  FocusFrameOverlaySpec _manualFocusOverlaySpec(
    CropRect frame,
    int contextPx,
  ) {
    final outer = Rect.fromLTWH(
      frame.x.toDouble(),
      frame.y.toDouble(),
      frame.w.toDouble(),
      frame.h.toDouble(),
    );
    final effective = min(
      contextPx.toDouble(),
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

  /// One card for everything that shapes the request: img2img parameters,
  /// request size and the inpainting mask with its options.
  Widget _buildGenerationCard(BuildContext context) {
    final config = viewmodel.config;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(tr('i2i_parameters')),
            subtitle: Text(
              config.hasImage
                  ? tr('i2i_active_note')
                  : tr('image_generation_requires_source'),
            ),
          ),
          SliderListTile(
            title:
                '${tr('i2i_strength')}: ${config.strength.toStringAsFixed(2)}',
            sliderValue: config.strength,
            min: 0.01,
            max: 1.0,
            divisions: 99,
            onChanged: viewmodel.setStrength,
          ),
          if (!config.hasInpaintSelection)
            SliderListTile(
              title: '${tr('i2i_noise')}: ${config.noise.toStringAsFixed(2)}',
              sliderValue: config.noise,
              min: 0.0,
              max: 0.99,
              divisions: 99,
              onChanged: viewmodel.setNoise,
            ),
          ListTile(
            leading: const Icon(Icons.photo_size_select_large),
            title: Text(tr('i2i_request_size')),
            subtitle: Text(
              '${_sizeModeLabel(viewmodel.sizeMode)} · '
              '${viewmodel.paramSizeText}',
            ),
            trailing: Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  key: const Key('i2i-auto-size'),
                  onPressed: () {
                    if (!viewmodel.applyAutomaticSize()) {
                      showWarningBar(
                        context,
                        tr('image_generation_requires_source'),
                      );
                    }
                  },
                  icon: Icon(
                    viewmodel.sizeMode == I2iSizeMode.automatic
                        ? Icons.check_circle
                        : Icons.auto_awesome_outlined,
                    size: 18,
                  ),
                  label: Text(tr('i2i_auto_size')),
                ),
                TextButton.icon(
                  key: const Key('i2i-use-image-size'),
                  onPressed: () {
                    if (!viewmodel.applyImageSizeToParams()) {
                      showWarningBar(
                        context,
                        tr('image_generation_requires_source'),
                      );
                    }
                  },
                  icon: Icon(
                    viewmodel.sizeMode == I2iSizeMode.original
                        ? Icons.check_circle
                        : Icons.aspect_ratio_outlined,
                    size: 18,
                  ),
                  label: Text(tr('i2i_use_image_size')),
                ),
                TextButton.icon(
                  key: const Key('i2i-manual-size'),
                  onPressed: () => _showManualSizeDialog(context),
                  icon: Icon(
                    viewmodel.sizeMode == I2iSizeMode.manual
                        ? Icons.check_circle
                        : Icons.edit_outlined,
                    size: 18,
                  ),
                  label: Text(tr('i2i_manual_size')),
                ),
              ],
            ),
          ),
          if (config.hasInpaintSelection) ...[
            const Divider(height: 1),
            if (config.manualFocusFrame != null)
              ListTile(
                key: const Key('inpaint-manual-frame'),
                leading: const Icon(Icons.crop_free),
                title: Text(tr('inpaint_manual_frame')),
                subtitle: Text(
                  '${config.manualFocusFrame!.w} × '
                  '${config.manualFocusFrame!.h} @ '
                  '(${config.manualFocusFrame!.x}, '
                  '${config.manualFocusFrame!.y})'
                  ' · ${tr(config.hasMask ? 'inpaint_manual_frame_hint' : 'inpaint_manual_frame_hint_maskless')}',
                ),
                trailing: TextButton.icon(
                  key: const Key('inpaint-clear-frame'),
                  onPressed: viewmodel.clearManualFocusFrame,
                  icon: const Icon(Icons.close),
                  label: Text(tr('inpaint_clear_frame')),
                ),
              )
            else
              SwitchListTile(
                key: const Key('inpaint-autocrop'),
                secondary: const Icon(Icons.center_focus_strong_outlined),
                title: Text(tr('inpaint_autocrop')),
                subtitle: Text(
                  config.autocropEnabled
                      ? tr(
                          autocropAppliesToImage(config.width, config.height)
                              ? 'inpaint_autocrop_hint_on'
                              : 'inpaint_autocrop_hint_inactive',
                        )
                      : tr('inpaint_autocrop_hint_off'),
                ),
                value: config.autocropEnabled,
                onChanged: viewmodel.setAutocropEnabled,
              ),
            if (config.manualFocusFrame != null || config.autocropEnabled)
              SliderListTile(
                key: const Key('inpaint-context-area'),
                leading: const Icon(Icons.filter_center_focus_outlined),
                title: '${tr('inpaint_minimum_context_area')}: '
                    '${config.contextPx}px',
                inputTitle: tr('inpaint_minimum_context_area'),
                inputDecimalPlaces: 0,
                sliderValue: config.contextPx.toDouble(),
                min: minContextPx.toDouble(),
                max: maxContextPx.toDouble(),
                divisions: (maxContextPx - minContextPx) ~/ latentGrid,
                onChanged: viewmodel.setContextPx,
              ),
          ],
        ],
      ),
    );
  }

  String _sizeModeLabel(I2iSizeMode mode) {
    switch (mode) {
      case I2iSizeMode.automatic:
        return tr('i2i_size_mode_auto');
      case I2iSizeMode.original:
        return tr('i2i_size_mode_original');
      case I2iSizeMode.manual:
        return tr('i2i_size_mode_manual');
    }
  }

  Widget _buildPrimaryAction(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: _buildGenerateButton(context),
      ),
    );
  }

  Widget _buildGenerateButton(BuildContext context) {
    final generationViewmodel = GetIt.I<GenerationPageViewmodel>();
    generationViewmodel.refreshCostEstimate();
    return ValueListenableBuilder<AnlasCost?>(
      valueListenable: generationViewmodel.nextCostEstimate,
      builder: (context, cost, _) {
        final badge = formatAnlasBadge(cost);
        final bound = generationViewmodel.nextCostIsUpperBound &&
                cost != null &&
                !cost.isFreeUnderOpus
            ? '≤ '
            : '';
        return Tooltip(
          message: formatAnlasTooltip(
            cost,
            isUpperBound: generationViewmodel.nextCostIsUpperBound,
          ),
          child: FilledButton.icon(
            key: const Key('i2i-generate-once'),
            onPressed:
                viewmodel.config.hasImage ? () => _generateOnce(context) : null,
            icon: const Icon(Icons.play_arrow),
            label: Text(
              badge.isEmpty
                  ? tr('i2i_generate_once')
                  : '${tr('i2i_generate_once')}  ·  $bound$badge',
            ),
          ),
        );
      },
    );
  }

  Future<void> _showManualSizeDialog(BuildContext context) async {
    final widthController = TextEditingController(
      text: viewmodel.config.requestSize.width.toString(),
    );
    final heightController = TextEditingController(
      text: viewmodel.config.requestSize.height.toString(),
    );
    final applied = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('i2i_manual_size')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('i2i_manual_size_hint')),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('i2i-manual-size-width'),
                    controller: widthController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: tr('width')),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('×'),
                ),
                Expanded(
                  child: TextField(
                    key: const Key('i2i-manual-size-height'),
                    controller: heightController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: tr('height')),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('cancel')),
          ),
          TextButton(
            key: const Key('i2i-manual-size-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('confirm')),
          ),
        ],
      ),
    );
    if (applied != true) return;
    final size = viewmodel.applyManualRequestSize(
      widthController.text,
      heightController.text,
    );
    if (!context.mounted) return;
    if (size == null) {
      showErrorBar(context, tr('i2i_manual_size_invalid'));
    } else {
      showInfoBar(
        context,
        '${tr('i2i_request_size')}: ${size.width} × ${size.height}',
      );
    }
  }

  Future<bool> _importImage(BuildContext context) async {
    final succeed = await viewmodel.pickAndSetImage();
    if (!context.mounted) return false;
    if (succeed) {
      showInfoBar(context, '${tr('i2i_import_image')}${tr('succeed')}');
    }
    return succeed;
  }

  Future<void> _startInpainting(BuildContext context) async {
    if (!viewmodel.config.hasImage) {
      final imported = await _importImage(context);
      if (!imported || !context.mounted) return;
    }
    await _openMaskEditor(context);
  }

  Future<void> _handleDrop(BuildContext context, PerformDropEvent event) async {
    if (event.session.items.isEmpty) return;
    final reader = event.session.items.first.dataReader;
    if (reader == null) return;
    reader.getFile(imageFormat, (file) async {
      final bytes = await file.readAll();
      final succeed = viewmodel.loadImageBytes(bytes);
      if (!context.mounted) return;
      if (succeed) {
        showInfoBar(context, '${tr('i2i_import_image')}${tr('succeed')}');
      } else {
        showErrorBar(context, '${tr('i2i_import_image')}${tr('failed')}');
      }
    });
  }

  Future<void> _openMaskEditor(BuildContext context) async {
    final config = viewmodel.config;
    if (!config.hasImage) {
      showWarningBar(context, tr('image_generation_requires_source'));
      return;
    }
    final result = await MaskEditorView.open(
      context,
      imageBytes: config.imageBytes!,
      displayImageBytes: config.displayImageBytes,
      imageWidth: config.width,
      imageHeight: config.height,
      initialBaseMaskBytes: config.maskBaseBytes,
      initialStrokes: config.maskStrokes,
      initialFocusFrame: config.manualFocusFrame,
      initialContextPx: config.contextPx,
    );
    if (result == null) return;
    viewmodel.setMask(
      result.maskBytes,
      result.strokes,
      baseMaskBytes: result.baseMaskBytes,
      focusFrame: result.focusFrame,
      contextPx: result.contextPx,
    );
  }

  void _generateOnce(BuildContext context) {
    final generationViewmodel = GetIt.I<GenerationPageViewmodel>();
    if (generationViewmodel.commandStatus.isGenerationActive.value ||
        (generationViewmodel.currentCommand?.isExecuting.value ?? false)) {
      showWarningBar(context, tr('i2i_generation_busy'));
      return;
    }
    generationViewmodel.runSingleGeneration();
    showInfoBar(context, tr('i2i_generate_once_started'));
  }
}
