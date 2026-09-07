import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/image_formats.dart';
import 'package:nai_casrand/data/models/enhance_config.dart';
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/utils/platform_support.dart';
import 'package:nai_casrand/ui/core/widgets/image_transform_workspace.dart';
import 'package:nai_casrand/ui/core/widgets/prompt_mode_switch_button.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/ui/enhance_page/view_models/enhance_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/widgets/result_actions.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class EnhancePageView extends StatelessWidget {
  final EnhancePageViewmodel viewmodel;

  const EnhancePageView({super.key, required this.viewmodel});

  GenerationPageViewmodel get generationViewmodel =>
      GetIt.I<GenerationPageViewmodel>();
  ImageHandoffCoordinator? get handoff =>
      GetIt.I.isRegistered<ImageHandoffCoordinator>()
          ? GetIt.I<ImageHandoffCoordinator>()
          : null;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        viewmodel,
        generationViewmodel,
        if (handoff != null) handoff!,
      ]),
      builder: (context, _) {
        return Scaffold(
          key: const Key('enhance-page-frame'),
          body: Column(
            children: [
              _buildPrimaryAction(context),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    _buildWorkspace(context),
                    const SizedBox(height: 12),
                    _buildSettingsCard(context),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPrimaryAction(BuildContext context) {
    generationViewmodel.refreshSubscriptionSnapshot();
    final config = viewmodel.config;
    final target = config.hasImage && viewmodel.availableScales.isNotEmpty
        ? viewmodel.targetSize
        : null;
    final cost = viewmodel.estimateCost();
    final badge = formatAnlasBadge(cost);
    final busy = generationViewmodel.isPreparingEnhance ||
        generationViewmodel.commandStatus.isGenerationActive.value ||
        (generationViewmodel.currentCommand?.isExecuting.value ?? false);
    final enabled =
        config.hasImage && viewmodel.availableScales.isNotEmpty && !busy;
    final label = target == null
        ? tr('enhance_run')
        : badge.isEmpty
            ? '${tr('enhance_run')} → ${target.width}×${target.height}'
            : '${tr('enhance_run')} → ${target.width}×${target.height} · ${tr('estimated_cost_prefix')} $badge';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Tooltip(
          message: formatEstimatedAnlasTooltip(cost),
          child: FilledButton.icon(
            key: const Key('enhance-run'),
            onPressed: enabled ? () => _runEnhance(context) : null,
            icon: busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(label),
          ),
        ),
      ),
    );
  }

  Widget _buildWorkspace(BuildContext context) {
    if (handoff?.isPreparing(ImageHandoffAction.enhance) ?? false) {
      return _buildHandoffLoading();
    }
    if (handoff?.hasFailed(ImageHandoffAction.enhance) ?? false) {
      return _buildHandoffFailure(context);
    }
    final config = viewmodel.config;
    final command = generationViewmodel.lastEnhanceCommand;
    final workspace = ImageTransformWorkspace(
      sourceBytes: config.imageBytes,
      result: command?.value,
      isExecuting: generationViewmodel.isPreparingEnhance ||
          (command?.isExecuting.value ?? false),
      onSourceTap: () => _importImage(context),
      sourcePlaceholder: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.add_photo_alternate_outlined,
            size: 88,
            color: Theme.of(context).disabledColor,
          ),
          const SizedBox(height: 8),
          Text(
            tr('enhance_drop_hint'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).disabledColor),
          ),
        ],
      ),
      sourceActions: Wrap(
        alignment: WrapAlignment.end,
        spacing: 4,
        children: [
          TextButton.icon(
            key: const Key('enhance-import-image'),
            onPressed: () => _importImage(context),
            icon: const Icon(Icons.file_open_outlined),
            label: Text(tr('i2i_import_image')),
          ),
          if (viewmodel.canUseI2iBaseImage)
            TextButton.icon(
              key: const Key('enhance-use-base-image'),
              onPressed: viewmodel.useI2iBaseImage,
              icon: const Icon(Icons.download_outlined),
              label: Text(tr('enhance_use_base')),
            ),
          if (config.hasImage)
            TextButton.icon(
              key: const Key('enhance-remove-image'),
              onPressed: viewmodel.removeImage,
              icon: const Icon(Icons.delete_outline),
              label: Text(tr('i2i_remove_image')),
            ),
        ],
      ),
    );
    final keyed = KeyedSubtree(
      key: const Key('enhance-import-image-area'),
      child: workspace,
    );
    if (!supportsSuperNativeExtensions) return keyed;
    return DropRegion(
      formats: Formats.standardFormats,
      onDropOver: (_) => DropOperation.copy,
      onPerformDrop: (event) => _handleDrop(context, event),
      child: keyed,
    );
  }

  Widget _buildHandoffLoading() {
    return Card(
      key: const Key('image-handoff-loading-enhance'),
      child: SizedBox(
        height: 220,
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
      ),
    );
  }

  Widget _buildHandoffFailure(BuildContext context) {
    return Card(
      key: const Key('image-handoff-error-enhance'),
      child: SizedBox(
        height: 220,
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
                key: const Key('image-handoff-retry-enhance'),
                onPressed: handoff?.retry,
                icon: const Icon(Icons.refresh),
                label: Text(tr('retry')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsCard(BuildContext context) {
    final config = viewmodel.config;
    final scales = viewmodel.availableScales;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!config.hasImage)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(tr('image_generation_requires_source')),
            )
          else if (scales.isEmpty)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(tr('enhance_too_large')),
            ),
          ListTile(
            title: Text(tr('enhance_scale_label')),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: (!config.hasImage ? enhanceScaleOptions : scales)
                    .map((scale) {
                  final size =
                      config.hasImage ? viewmodel.targetSizeFor(scale) : null;
                  return ChoiceChip(
                    key: Key('enhance-scale-$scale'),
                    selected: (config.scale - scale).abs() < 1e-6,
                    onSelected: (_) => viewmodel.setScale(scale),
                    label: Text(
                      size == null
                          ? '${scale}x'
                          : '${scale}x  ${size.width}×${size.height}',
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
                '${tr(viewmodel.preset.labelKey)} '
                '(${viewmodel.preset.strength.toStringAsFixed(2)})',
            sliderValue: config.presetIndex.toDouble(),
            min: 0,
            max: (enhancePresets.length - 1).toDouble(),
            divisions: enhancePresets.length - 1,
            onChanged: (value) => viewmodel.setPresetIndex(value.round()),
          ),
          SwitchListTile(
            key: const Key('enhance-show-individual'),
            secondary: const Icon(Icons.tune_outlined),
            title: Text(tr('enhance_show_individual')),
            subtitle: Text(tr('enhance_show_individual_hint')),
            value: config.showIndividualSettings,
            onChanged: viewmodel.setShowIndividualSettings,
          ),
          if (config.showIndividualSettings) ...[
            SliderListTile(
              key: const Key('enhance-strength'),
              leading: const Icon(Icons.contrast),
              title:
                  '${tr('i2i_strength')}: ${config.individualStrength.toStringAsFixed(2)}',
              sliderValue: config.individualStrength,
              min: 0,
              max: 1,
              divisions: 100,
              onChanged: viewmodel.setStrength,
            ),
            SliderListTile(
              key: const Key('enhance-noise'),
              leading: const Icon(Icons.grain),
              title:
                  '${tr('i2i_noise')}: ${config.individualNoise.toStringAsFixed(2)}',
              sliderValue: config.individualNoise,
              min: 0,
              max: 0.99,
              divisions: 99,
              onChanged: viewmodel.setNoise,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _importImage(BuildContext context) async {
    final succeed = await viewmodel.pickAndSetImage();
    if (!context.mounted) return;
    if (succeed) {
      if (viewmodel.takeLastImportActivatedFixedMode()) {
        showFixedModeImportNotice(
          context,
          '${tr('i2i_import_image')}${tr('succeed')}',
        );
      } else {
        showInfoBar(context, '${tr('i2i_import_image')}${tr('succeed')}');
      }
    }
  }

  Future<void> _handleDrop(BuildContext context, PerformDropEvent event) async {
    if (event.session.items.isEmpty) return;
    final reader = event.session.items.first.dataReader;
    if (reader == null) return;
    reader.getFile(imageFormat, (file) async {
      final succeed = await viewmodel.loadImageBytes(await file.readAll());
      if (!context.mounted) return;
      if (succeed) {
        if (viewmodel.takeLastImportActivatedFixedMode()) {
          showFixedModeImportNotice(
            context,
            '${tr('i2i_import_image')}${tr('succeed')}',
          );
        } else {
          showInfoBar(context, '${tr('i2i_import_image')}${tr('succeed')}');
        }
      } else {
        showErrorBar(context, '${tr('i2i_import_image')}${tr('failed')}');
      }
    });
  }

  Future<void> _runEnhance(BuildContext context) async {
    final target = viewmodel.targetSize;
    final started = await generationViewmodel.runEnhanceGeneration();
    if (!context.mounted) return;
    if (started) {
      showInfoBar(
        context,
        tr('enhance_started', namedArgs: {
          'size': '${target.width}×${target.height}',
        }),
      );
      final command = generationViewmodel.currentCommand;
      if (command != null) {
        var handled = false;
        late VoidCallback listener;
        listener = () {
          if (handled || command.isExecuting.value) return;
          handled = true;
          command.isExecuting.removeListener(listener);
          if (!context.mounted) return;
          final cost = command.value.anlasCost;
          showInfoBar(
            context,
            cost == null
                ? tr('actual_cost_unavailable')
                : tr('actual_cost_detected', namedArgs: {'anlas': '$cost'}),
          );
        };
        command.isExecuting.addListener(listener);
        WidgetsBinding.instance.addPostFrameCallback((_) => listener());
      }
    } else {
      final error = generationViewmodel.takeEnhancePreparationError();
      if (error != null) {
        showErrorBar(context, '${tr('image_handoff_failed')}: $error');
      }
    }
  }
}
