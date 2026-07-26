import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/core/constants/defaults.dart';
import 'package:nai_casrand/core/constants/feature_flags.dart';
import 'package:nai_casrand/ui/core/widgets/editable_list_tile.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

class GenerationSettingsView extends StatelessWidget {
  final GenerationPageViewmodel viewmodel;

  const GenerationSettingsView({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewmodel,
      builder: (context, _) {
        final paramConfig = viewmodel.payloadConfig.paramConfig;
        final settings = viewmodel.payloadConfig.settings;
        final displayedGenerationCount = settings.generationCount == 0
            ? '∞'
            : settings.generationCount.toString();

        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              EditableListTile(
                key: const Key('generation-settings-count'),
                leading: const Icon(Icons.alarm),
                title: context.tr('generation_count'),
                currentValue: displayedGenerationCount,
                editValue: settings.generationCount.toString(),
                notice: '0 → ∞',
                keyboardType: TextInputType.number,
                confirmOnSubmit: true,
                onEditComplete: viewmodel.setGenerationCount,
              ),
              EditableListTile(
                key: const Key('generation-settings-interval'),
                leading: const Icon(Icons.hourglass_empty),
                title: context.tr('generation_interval'),
                currentValue: settings.generationIntervalSec.toString(),
                keyboardType: TextInputType.number,
                confirmOnSubmit: true,
                onEditComplete: viewmodel.setGenerationInterval,
              ),
              ListTile(
                key: const Key('generation-settings-image-size'),
                title: Text(context.tr('image_size')),
                subtitle: Text(
                  paramConfig.sizes
                      .map((size) => '${size.width} × ${size.height}')
                      .join(' || '),
                ),
                leading: const Icon(Icons.photo_size_select_large),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showSizeSelectionDialog(context),
              ),
              CheckboxListTile(
                key: const Key('generation-settings-random-seed'),
                secondary: const Icon(Icons.shuffle),
                title: Text(context.tr('use_random_seed')),
                value: paramConfig.randomSeed,
                onChanged: viewmodel.setRandomSeedEnabled,
              ),
              if (!paramConfig.randomSeed)
                Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: EditableListTile(
                    key: const Key('generation-settings-fixed-seed'),
                    leading: const Icon(Icons.numbers),
                    title: context.tr('fixed_seed'),
                    currentValue: paramConfig.seed?.toString() ?? '',
                    keyboardType: TextInputType.number,
                    confirmOnSubmit: true,
                    onEditComplete: viewmodel.setSeed,
                  ),
                ),
              ListTile(
                key: const Key('generation-settings-display-mode'),
                leading: const Icon(Icons.view_quilt_outlined),
                title: Text(context.tr('result_display_mode')),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                        value: 'waterfall',
                        icon: const Icon(Icons.view_column_outlined),
                        label: Text(context.tr('display_mode_waterfall')),
                      ),
                      ButtonSegment(
                        value: 'classic',
                        icon: const Icon(Icons.grid_on_outlined),
                        label: Text(context.tr('display_mode_classic')),
                      ),
                    ],
                    selected: {
                      settings.resultDisplayMode == 'classic'
                          ? 'classic'
                          : 'waterfall'
                    },
                    onSelectionChanged: (selection) =>
                        viewmodel.setResultDisplayMode(selection.first),
                  ),
                ),
              ),
              SliderListTile(
                key: const Key('generation-settings-column-count'),
                leading: const Icon(Icons.grid_view_outlined),
                title: '${tr('result_column_count')}: ${viewmodel.colNum}',
                sliderValue: viewmodel.colNum.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                onChanged: (value) => viewmodel.setCardsPerCol(value.toInt()),
              ),
              if (FeatureFlags.overridePrompt) ...[
                CheckboxListTile(
                  secondary: const Icon(Icons.edit),
                  title: Text(context.tr('override_random_prompts')),
                  value: viewmodel.payloadConfig.useOverridePrompt,
                  onChanged: viewmodel.setOverride,
                ),
                if (viewmodel.payloadConfig.useOverridePrompt)
                  CheckboxListTile(
                    secondary: const Icon(Icons.people_outline),
                    title: Text(context.tr('use_character_prompt')),
                    value:
                        viewmodel.payloadConfig.useCharacterPromptWithOverride,
                    onChanged: viewmodel.setCharacterOverride,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _showSizeSelectionDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          '${dialogContext.tr('edit')}${dialogContext.tr('colon')}'
          '${dialogContext.tr('image_size')}',
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.7,
          ),
          child: SizeSelectionView(viewmodel: viewmodel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(dialogContext.tr('confirm')),
          ),
        ],
      ),
    );
  }
}

class SizeSelectionView extends StatefulWidget {
  final GenerationPageViewmodel viewmodel;

  const SizeSelectionView({super.key, required this.viewmodel});

  @override
  State<SizeSelectionView> createState() => _SizeSelectionViewState();
}

class _SizeSelectionViewState extends State<SizeSelectionView> {
  final widthController = TextEditingController();
  final heightController = TextEditingController();

  @override
  void dispose() {
    widthController.dispose();
    heightController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewmodel,
      builder: (context, _) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(context.tr('selected_sizes')),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: widget.viewmodel.payloadConfig.paramConfig.sizes
                  .map(
                    (size) => Chip(
                      label: Text('${size.width} × ${size.height}'),
                      onDeleted: () => widget.viewmodel.removeSize(size),
                    ),
                  )
                  .toList(),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(context.tr('default_sizes')),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: defaultSizes
                  .map(
                    (size) => OutlinedButton(
                      onPressed: () => widget.viewmodel.addSize(size),
                      child: Text('${size.width} × ${size.height}'),
                    ),
                  )
                  .toList(),
            ),
            const Divider(),
            Text(context.tr('manual_size')),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('manual-size-width'),
                    controller: widthController,
                    keyboardType: const TextInputType.numberWithOptions(),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('×'),
                ),
                Expanded(
                  child: TextField(
                    key: const Key('manual-size-height'),
                    controller: heightController,
                    keyboardType: const TextInputType.numberWithOptions(),
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  key: const Key('manual-size-add'),
                  onPressed: () => widget.viewmodel.addManualSize(
                    widthController.text,
                    heightController.text,
                  ),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
