import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';
import 'package:nai_casrand/ui/character_config/view_models/character_config_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_config_view.dart';
import 'package:nai_casrand/ui/prompt_config/view_models/prompt_config_viewmodel.dart';
import 'package:provider/provider.dart';

class CharacterConfigView extends StatelessWidget {
  final CharacterConfigViewmodel viewmodel;
  final PromptEditingAssistance? promptAssistance;
  final bool autocompleteEnabled;

  const CharacterConfigView({
    super.key,
    required this.viewmodel,
    this.promptAssistance,
    this.autocompleteEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewmodel,
      builder: (context, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context)
              .disabledColor
              .withAlpha(viewmodel.config.enabled ? 0 : 30),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ListTile(
                    key: const Key('character-position-tile'),
                    title: Text(tr('character_position')),
                    leading: const Icon(Icons.location_on),
                    subtitle: Text(
                      viewmodel.autoPosition
                          ? tr('auto_position')
                          : viewmodel.getPositionsTexts(),
                    ),
                    onTap: () => _showEditPositionDialog(context),
                  ),
                ),
                Expanded(
                  child: ListTile(
                    key: const Key('character-gender-tile'),
                    title: Text(tr('gender')),
                    leading: Icon(_genderIcon(viewmodel.config.gender)),
                    subtitle: Text(_genderLabel(viewmodel.config.gender)),
                    onTap: () => _showGenderDialog(context),
                  ),
                ),
                Checkbox(
                  key: const Key('character-enabled-checkbox'),
                  value: viewmodel.config.enabled,
                  onChanged: (value) => viewmodel.setEnabled(value),
                ),
              ],
            ),
            Padding(
              key: const Key('character-positive-prompt'),
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: PromptConfigView(
                viewModel: PromptConfigViewModel(
                  config: viewmodel.config.positivePromptConfig,
                ),
                promptAssistance: promptAssistance,
                autocompleteEnabled: autocompleteEnabled,
              ),
            ),
            const Divider(height: 25, indent: 12, endIndent: 12),
            Padding(
              key: const Key('character-negative-prompt'),
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: PromptConfigView(
                viewModel: PromptConfigViewModel(
                  config: viewmodel.config.negativePromptConfig,
                ),
                promptAssistance: promptAssistance,
                autocompleteEnabled: autocompleteEnabled,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditPositionDialog(BuildContext context) {
    showDialog(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(
                  '${tr('edit')}${tr('colon')}${tr('character_position')}'),
              content: CharacterPositionView(viewmodel: viewmodel),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(tr('confirm')))
              ],
            ));
  }

  void _showGenderDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr('gender')),
        children: [
          _genderOption(
            dialogContext,
            CharacterConfig.genderFemale,
            Icons.female,
          ),
          _genderOption(
            dialogContext,
            CharacterConfig.genderMale,
            Icons.male,
          ),
          _genderOption(
            dialogContext,
            CharacterConfig.genderOther,
            Icons.radio_button_unchecked,
          ),
        ],
      ),
    );
  }

  Widget _genderOption(
    BuildContext context,
    String value,
    IconData icon,
  ) {
    return SimpleDialogOption(
      key: Key('character-gender-$value'),
      onPressed: () {
        viewmodel.setGender(value);
        Navigator.of(context).pop();
      },
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Text(_genderLabel(value)),
          const Spacer(),
          if (viewmodel.config.gender == value) const Icon(Icons.check),
        ],
      ),
    );
  }

  String _genderLabel(String gender) => switch (gender) {
        CharacterConfig.genderFemale => tr('gender_female'),
        CharacterConfig.genderMale => tr('gender_male'),
        CharacterConfig.genderOther => tr('gender_other'),
        _ => '',
      };

  IconData _genderIcon(String gender) => switch (gender) {
        CharacterConfig.genderFemale => Icons.female,
        CharacterConfig.genderMale => Icons.male,
        CharacterConfig.genderOther => Icons.radio_button_unchecked,
        _ => Icons.transgender,
      };
}

class CharacterPositionView extends StatelessWidget {
  final CharacterConfigViewmodel viewmodel;

  const CharacterPositionView({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    const indexes = [1, 2, 3, 4, 5];
    const Map<int, String> xMapping = {
      1: 'A',
      2: 'B',
      3: 'C',
      4: 'D',
      5: 'E',
    };

    return ChangeNotifierProvider.value(
        value: viewmodel,
        builder: (context, child) => Consumer<CharacterConfigViewmodel>(
              builder: (context, viewmodel, child) {
                List<Widget> rows = [];
                for (final y in indexes) {
                  List<Widget> cols = [];
                  for (final x in indexes) {
                    final pt = Point(x, y);
                    final selected = viewmodel.config.positions.contains(pt);
                    final label = '${xMapping[x]}${y.toString()}';
                    cols.add(InkWell(
                      key: Key('character-position-$label'),
                      onTap: () => viewmodel.switchPosition(pt),
                      child: SizedBox(
                        width: 40.0,
                        height: 40.0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: selected
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Colors.grey.withAlpha(77),
                            border: Border.all(
                              color: selected
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.transparent,
                            ),
                          ),
                          child: Center(child: Text(label)),
                        ),
                      ),
                    ));
                  }
                  rows.add(Row(
                    mainAxisSize: MainAxisSize.min,
                    children: cols,
                  ));
                }
                final grid = Column(
                  key: const Key('character-position-grid'),
                  mainAxisSize: MainAxisSize.min,
                  children: rows,
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IgnorePointer(
                      ignoring: viewmodel.autoPosition,
                      child: Opacity(
                        opacity: viewmodel.autoPosition ? 0.35 : 1,
                        child: grid,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Divider(),
                    CheckboxListTile(
                      key: const Key('auto-position-checkbox'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('auto_position')),
                      secondary: const Icon(Icons.not_listed_location_outlined),
                      value: viewmodel.autoPosition,
                      onChanged: viewmodel.setAutoPosition,
                    ),
                  ],
                );
              },
            ));
  }
}
