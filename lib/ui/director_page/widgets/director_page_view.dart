import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/image_formats.dart';
import 'package:nai_casrand/data/models/director_tool_config.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/utils/platform_support.dart';
import 'package:nai_casrand/ui/core/widgets/editable_list_tile.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/ui/director_page/view_models/director_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

/// Director Tools: single-image transforms that run against the augment-image
/// endpoint, independent of the generation pipeline.
class DirectorPageView extends StatelessWidget {
  final DirectorPageViewmodel viewmodel;

  const DirectorPageView({super.key, required this.viewmodel});

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
              _buildSourceCard(context),
              if (config.hasImage) _buildToolCard(context),
              if (config.hasImage) _buildRunCard(context),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSourceCard(BuildContext context) {
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
      key: const Key('director-import-image-area'),
      onTap: () => _importImage(context),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor, width: 2.0),
          borderRadius: BorderRadius.circular(8.0),
        ),
        padding: const EdgeInsets.all(8.0),
        child: preview,
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_fix_high_outlined),
              title: Text(tr('director_tool_section')),
              subtitle: Text(
                config.hasImage
                    ? '${config.width} × ${config.height}'
                    : tr('director_tool_hint'),
              ),
            ),
            supportsSuperNativeExtensions
                ? DropRegion(
                    formats: Formats.standardFormats,
                    onDropOver: (_) => DropOperation.copy,
                    onPerformDrop: (event) => _handleDrop(context, event),
                    child: dropChild,
                  )
                : dropChild,
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
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
          ],
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
          ListTile(
            title: Text(tr('director_tool_type')),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8.0),
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
                          : '${tool.name}  ·  $cost',
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
                padding: const EdgeInsets.only(top: 8.0),
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
              onChanged: (value) => viewmodel.setOverrideEnabled(value ?? false),
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

  Widget _buildRunCard(BuildContext context) {
    final cost = viewmodel.currentCost;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(
              Icons.toll_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(tr('director_tool_cost_notice')),
            subtitle: cost == null
                ? null
                : Text(tr('director_tool_cost_value',
                    namedArgs: {'anlas': cost.toString()})),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: FilledButton.tonalIcon(
              key: const Key('director-run'),
              onPressed: () => _run(context),
              icon: const Icon(Icons.play_arrow),
              label: Text(
                cost == null
                    ? tr('director_tool_run')
                    : '${tr('director_tool_run')}  ·  $cost',
              ),
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

  void _run(BuildContext context) {
    final config = viewmodel.config;
    if (!config.hasImage) {
      showWarningBar(context, tr('director_tool_no_image'));
      return;
    }
    final generationViewmodel = GetIt.I<GenerationPageViewmodel>();
    if (generationViewmodel.commandStatus.isGenerationActive.value ||
        (generationViewmodel.currentCommand?.isExecuting.value ?? false)) {
      showWarningBar(context, tr('i2i_generation_busy'));
      return;
    }
    generationViewmodel.runDirectorTool();
    showInfoBar(
      context,
      tr('director_tool_started', namedArgs: {'tool': config.displayName}),
    );
  }
}
