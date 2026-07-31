import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/image_formats.dart';
import 'package:nai_casrand/data/models/director_tool_config.dart';
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/utils/platform_support.dart';
import 'package:nai_casrand/ui/core/widgets/editable_list_tile.dart';
import 'package:nai_casrand/ui/core/widgets/image_transform_workspace.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/ui/director_page/view_models/director_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class DirectorPageView extends StatelessWidget {
  final DirectorPageViewmodel viewmodel;

  const DirectorPageView({super.key, required this.viewmodel});

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
          key: const Key('directorTools-page-frame'),
          body: Column(
            children: [
              _buildPrimaryAction(context),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    _buildWorkspace(context),
                    const SizedBox(height: 12),
                    _buildToolCard(context),
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
    final cost = viewmodel.currentCost;
    final busy = generationViewmodel.isPreparingDirector ||
        generationViewmodel.commandStatus.isGenerationActive.value ||
        (generationViewmodel.currentCommand?.isExecuting.value ?? false);
    final enabled = viewmodel.config.hasImage && !busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Tooltip(
          message: cost == null
              ? tr('estimated_generation_cost_pending')
              : tr(
                  'estimated_generation_cost_tooltip',
                  namedArgs: {'anlas': cost.toString()},
                ),
          child: FilledButton.icon(
            key: const Key('director-run'),
            onPressed: enabled ? () => _run(context) : null,
            icon: busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(
              cost == null
                  ? tr('director_tool_run')
                  : '${tr('director_tool_run')} · ${tr('estimated_cost_prefix')} $cost',
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWorkspace(BuildContext context) {
    if (handoff?.isPreparing(ImageHandoffAction.directorTools) ?? false) {
      return _buildHandoffLoading();
    }
    if (handoff?.hasFailed(ImageHandoffAction.directorTools) ?? false) {
      return _buildHandoffFailure(context);
    }
    final config = viewmodel.config;
    final command = generationViewmodel.lastDirectorCommand;
    final workspace = ImageTransformWorkspace(
      sourceBytes: config.imageBytes,
      result: command?.value,
      isExecuting: command?.isExecuting.value ?? false,
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
            tr('i2i_drop_hint'),
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
            key: const Key('director-import-image'),
            onPressed: () => _importImage(context),
            icon: const Icon(Icons.file_open_outlined),
            label: Text(tr('i2i_import_image')),
          ),
          if (viewmodel.canUseBaseImage)
            TextButton.icon(
              key: const Key('director-use-base-image'),
              onPressed: viewmodel.useBaseImage,
              icon: const Icon(Icons.download_outlined),
              label: Text(tr('director_tool_use_base')),
            ),
          if (config.hasImage)
            TextButton.icon(
              key: const Key('director-remove-image'),
              onPressed: viewmodel.removeImage,
              icon: const Icon(Icons.delete_outline),
              label: Text(tr('i2i_remove_image')),
            ),
        ],
      ),
    );
    final keyed = KeyedSubtree(
      key: const Key('director-import-image-area'),
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
      key: const Key('image-handoff-loading-directorTools'),
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
      key: const Key('image-handoff-error-directorTools'),
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
                key: const Key('image-handoff-retry-directorTools'),
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

  Widget _buildToolCard(BuildContext context) {
    final config = viewmodel.config;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!config.hasImage)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(tr('image_generation_requires_source')),
            ),
          ListTile(
            title: Text(tr('director_tool_type')),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: toolTypes.map((tool) {
                  final cost = viewmodel.costFor(tool.type);
                  return ChoiceChip(
                    key: Key('director-tool-${tool.type}'),
                    selected: config.type == tool.type,
                    onSelected: (_) => viewmodel.setTool(tool.type),
                    label: Text(
                      cost == null
                          ? tool.name
                          : '${tool.name} · ${tr('estimated_cost_prefix')} $cost',
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          if (config.type == 'emotion')
            ListTile(
              title: Text(tr('director_tool_emotions')),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: emotions.map((emotion) {
                    return FilterChip(
                      key: Key('director-emotion-$emotion'),
                      selected: config.selectedEmotions.contains(emotion),
                      onSelected: (value) =>
                          viewmodel.toggleEmotion(emotion, value),
                      label: Text(emotion),
                    );
                  }).toList(),
                ),
              ),
            ),
          if (config.withPrompt) ...[
            SliderListTile(
              key: const Key('director-defry'),
              leading: const Icon(Icons.tune),
              title: '${tr('director_tool_defry')}: ${config.defry}',
              sliderValue: config.defry.toDouble(),
              min: 0,
              max: maxDefry.toDouble(),
              divisions: maxDefry,
              onChanged: (value) => viewmodel.setDefry(value.round()),
            ),
            CheckboxListTile(
              key: const Key('director-override-enabled'),
              secondary: const Icon(Icons.edit_note),
              title: Text(tr('director_tool_prompt')),
              value: config.overrideEnabled,
              onChanged: (value) =>
                  viewmodel.setOverrideEnabled(value ?? false),
            ),
            if (config.overrideEnabled)
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: EditableListTile(
                  title: tr('director_tool_prompt'),
                  currentValue: config.overridePrompt,
                  confirmOnSubmit: true,
                  onEditComplete: viewmodel.setOverridePrompt,
                ),
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
      showInfoBar(context, '${tr('i2i_import_image')}${tr('succeed')}');
    }
  }

  Future<void> _handleDrop(BuildContext context, PerformDropEvent event) async {
    if (event.session.items.isEmpty) return;
    final reader = event.session.items.first.dataReader;
    if (reader == null) return;
    reader.getFile(imageFormat, (file) async {
      final succeed = viewmodel.loadImageBytes(await file.readAll());
      if (!context.mounted) return;
      if (succeed) {
        showInfoBar(context, '${tr('i2i_import_image')}${tr('succeed')}');
      } else {
        showErrorBar(context, '${tr('i2i_import_image')}${tr('failed')}');
      }
    });
  }

  Future<void> _run(BuildContext context) async {
    final config = viewmodel.config;
    if (!config.hasImage) return;
    final started = await generationViewmodel.runDirectorTool();
    if (!context.mounted) return;
    if (!started) {
      final error = generationViewmodel.takeDirectorPreparationError();
      if (error != null) {
        showErrorBar(context, '${tr('image_handoff_failed')}: $error');
      }
      return;
    }
    showInfoBar(
      context,
      tr('director_tool_started', namedArgs: {'tool': config.displayName}),
    );
    final command = generationViewmodel.lastDirectorCommand;
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
  }
}
