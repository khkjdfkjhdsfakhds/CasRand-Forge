import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/director_tool_config.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/widgets/editable_list_tile.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/i2i_page/view_models/i2i_page_viewmodel.dart';

/// Director Tools section: single-image transforms that run against the
/// augment-image endpoint rather than the generation endpoint.
class DirectorToolCard extends StatelessWidget {
  final I2iPageViewmodel viewmodel;

  const DirectorToolCard({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    final config = viewmodel.directorToolConfig;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.auto_fix_high_outlined),
            title: Text(tr('director_tool_section')),
            subtitle: Text(tr('director_tool_hint')),
          ),
          ListTile(
            title: Text(tr('director_tool_type')),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: toolTypes.map((tool) {
                  return ChoiceChip(
                    key: Key('director-tool-${tool.type}'),
                    selected: config.type == tool.type,
                    onSelected: (_) => viewmodel.setDirectorTool(tool.type),
                    label: Text(tool.name),
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
                    final selected = config.selectedEmotions.contains(emotion);
                    return FilterChip(
                      key: Key('director-emotion-$emotion'),
                      selected: selected,
                      onSelected: (value) =>
                          viewmodel.toggleDirectorEmotion(emotion, value),
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
              onChanged: (value) => viewmodel.setDirectorDefry(value.round()),
            ),
            CheckboxListTile(
              key: const Key('director-override-enabled'),
              secondary: const Icon(Icons.edit_note),
              title: Text(tr('director_tool_prompt')),
              value: config.overrideEnabled,
              onChanged: (value) =>
                  viewmodel.setDirectorOverrideEnabled(value ?? false),
            ),
            if (config.overrideEnabled)
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: EditableListTile(
                  title: tr('director_tool_prompt'),
                  currentValue: config.overridePrompt,
                  confirmOnSubmit: true,
                  onEditComplete: viewmodel.setDirectorOverridePrompt,
                ),
              ),
          ],
          ListTile(
            dense: true,
            leading: const Icon(Icons.info_outline),
            title: Text(tr('director_tool_free')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: FilledButton.tonalIcon(
              key: const Key('director-run'),
              onPressed: () => _run(context),
              icon: const Icon(Icons.play_arrow),
              label: Text(tr('director_tool_run')),
            ),
          ),
        ],
      ),
    );
  }

  void _run(BuildContext context) {
    final config = viewmodel.directorToolConfig;
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
