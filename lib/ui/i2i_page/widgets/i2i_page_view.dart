import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/image_formats.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/utils/platform_support.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/i2i_page/view_models/i2i_page_viewmodel.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/mask_editor_view.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

/// The 图生图 / 局部重绘 (img2img / inpaint) destination page.
class I2iPageView extends StatelessWidget {
  final I2iPageViewmodel viewmodel;

  const I2iPageView({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewmodel,
      builder: (context, _) {
        final config = viewmodel.config;
        return Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(12.0),
            children: [
              _buildBaseImageCard(context),
              if (config.hasImage) _buildI2iParamsCard(context),
              if (config.hasImage) _buildInpaintCard(context),
              if (config.hasImage) _buildEnhanceCard(context),
              if (config.hasImage) _buildActionCard(context),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBaseImageCard(BuildContext context) {
    final config = viewmodel.config;
    final Widget preview;
    if (config.hasImage) {
      preview = ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: Image.memory(
          config.imageBytes!,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
        ),
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
            color: Theme.of(context).dividerColor,
            width: 2.0,
          ),
          borderRadius: BorderRadius.circular(8.0),
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
                      '${viewmodel.config.width} × ${viewmodel.config.height}')
                  : Text(tr('i2i_page_sections_hint')),
            ),
            dropArea,
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
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

  Widget _buildI2iParamsCard(BuildContext context) {
    final config = viewmodel.config;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(tr('i2i_parameters')),
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
          if (!config.hasMask)
            SliderListTile(
              title: '${tr('i2i_noise')}: ${config.noise.toStringAsFixed(2)}',
              sliderValue: config.noise,
              min: 0.0,
              max: 0.99,
              divisions: 99,
              onChanged: viewmodel.setNoise,
            ),
          if (!config.hasMask)
            ListTile(
              leading: const Icon(Icons.photo_size_select_large),
              title: Text(tr('i2i_request_size')),
              subtitle: Text(viewmodel.paramSizeText),
              trailing: viewmodel.paramSizeMatchesImage
                  ? null
                  : TextButton(
                      key: const Key('i2i-use-image-size'),
                      onPressed: viewmodel.applyImageSizeToParams,
                      child: Text(
                        '${tr('i2i_use_image_size')} '
                        '(${viewmodel.snappedImageSize.width} × '
                        '${viewmodel.snappedImageSize.height})',
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _buildInpaintCard(BuildContext context) {
    final config = viewmodel.config;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.brush_outlined),
            title: Text(tr('inpaint_section')),
            subtitle: Text(
              config.hasMask
                  ? tr('inpaint_mask_present')
                  : tr('inpaint_mask_absent'),
            ),
            trailing: Wrap(
              spacing: 4,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('inpaint-edit-mask'),
                  onPressed: () => _openMaskEditor(context),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(tr('inpaint_edit_mask')),
                ),
                if (config.hasMask)
                  TextButton.icon(
                    key: const Key('inpaint-clear-mask'),
                    onPressed: viewmodel.clearMask,
                    icon: const Icon(Icons.layers_clear_outlined),
                    label: Text(tr('inpaint_clear_mask')),
                  ),
              ],
            ),
          ),
          if (config.hasMask) ...[
            SwitchListTile(
              key: const Key('inpaint-add-original-image'),
              secondary: const Icon(Icons.layers_outlined),
              title: Text(tr('inpaint_add_original_image')),
              subtitle: Text(tr('inpaint_add_original_image_hint')),
              value: config.addOriginalImage,
              onChanged: viewmodel.setAddOriginalImage,
            ),
            SwitchListTile(
              key: const Key('inpaint-autocrop'),
              secondary: const Icon(Icons.center_focus_strong_outlined),
              title: Text(tr('inpaint_autocrop')),
              subtitle: Text(
                config.autocropEnabled
                    ? tr('inpaint_autocrop_hint_on')
                    : tr('inpaint_autocrop_hint_off'),
              ),
              value: config.autocropEnabled,
              onChanged: viewmodel.setAutocropEnabled,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEnhanceCard(BuildContext context) {
    final config = viewmodel.config;
    final scales = viewmodel.availableEnhanceScales;
    final target = viewmodel.enhanceTargetSize;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(tr('enhance_section')),
            subtitle: Text(tr('enhance_section_hint')),
          ),
          if (scales.isEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: Text(tr('enhance_too_large')),
            )
          else ...[
            ListTile(
              title: Text(tr('enhance_scale_label')),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: scales.map((scale) {
                    final size = viewmodel.enhanceTargetSizeFor(scale);
                    return ChoiceChip(
                      key: Key('enhance-scale-$scale'),
                      selected: (config.enhanceScale - scale).abs() < 1e-6,
                      onSelected: (_) => viewmodel.setEnhanceScale(scale),
                      label: Text(
                        '${scale}x  ${size.width}×${size.height}',
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            SliderListTile(
              key: const Key('enhance-preset-slider'),
              leading: const Icon(Icons.tune),
              title: '${tr('enhance_strength_preset')}: '
                  '${tr(viewmodel.enhancePreset.labelKey)} '
                  '(${viewmodel.enhancePreset.strength.toStringAsFixed(2)})',
              sliderValue: config.enhancePresetIndex.toDouble(),
              min: 0,
              max: (enhancePresets.length - 1).toDouble(),
              divisions: enhancePresets.length - 1,
              onChanged: (value) =>
                  viewmodel.setEnhancePresetIndex(value.round()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (config.hasMask)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Text(
                        tr('enhance_clears_mask_notice'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton.tonalIcon(
                    key: const Key('enhance-run'),
                    onPressed: () => _runEnhance(context, target),
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(
                      '${tr('enhance_run')} → ${target.width}×${target.height}',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionCard(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(tr('i2i_active_note')),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: FilledButton.icon(
              key: const Key('i2i-generate-once'),
              onPressed: () => _generateOnce(context),
              icon: const Icon(Icons.play_arrow),
              label: Text(tr('i2i_generate_once')),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _importImage(BuildContext context) async {
    final succeed = await viewmodel.pickAndSetImage();
    if (!context.mounted) return;
    if (succeed) {
      showInfoBar(context, '${tr('i2i_import_image')}${tr('succeed')}');
    }
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
    if (!config.hasImage) return;
    final result = await MaskEditorView.open(
      context,
      imageBytes: config.imageBytes!,
      imageWidth: config.width,
      imageHeight: config.height,
      initialStrokes: config.maskStrokes,
    );
    if (result == null) return;
    viewmodel.setMask(result.maskBytes, result.strokes);
  }

  void _runEnhance(BuildContext context, GenerationSize target) {
    final generationViewmodel = GetIt.I<GenerationPageViewmodel>();
    if (generationViewmodel.commandStatus.isGenerationActive.value ||
        (generationViewmodel.currentCommand?.isExecuting.value ?? false)) {
      showWarningBar(context, tr('i2i_generation_busy'));
      return;
    }
    viewmodel.applyEnhance();
    generationViewmodel.runSingleGeneration();
    showInfoBar(
      context,
      tr('enhance_started', namedArgs: {
        'size': '${target.width}×${target.height}',
      }),
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
