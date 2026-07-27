import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/ui/character_config/widgets/character_config_view.dart';
import 'package:nai_casrand/ui/character_config/view_models/character_config_viewmodel.dart';
import 'package:nai_casrand/ui/core/widgets/prompt_mode_switch_button.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_config_view.dart';
import 'package:nai_casrand/ui/prompt_config/view_models/prompt_config_viewmodel.dart';
import 'package:nai_casrand/ui/saved_config_list/view_models/saved_config_list_viewmodel.dart';
import 'package:nai_casrand/ui/saved_config_list/widgets/saved_config_list_view.dart';
import 'package:provider/provider.dart';

class PromptTabView extends StatelessWidget {
  const PromptTabView({super.key, required this.viewmodel});

  final PromptTabViewmodel viewmodel;

  @override
  Widget build(BuildContext context) {
    final content = ChangeNotifierProvider.value(
      value: viewmodel,
      child: Consumer<PromptTabViewmodel>(
        builder: (context, value, child) => value.isFixedMode
            ? _FixedPromptEditor(viewmodel: value)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                      title: Text(context.tr('prompt_compact_view_hint')),
                      dense: true),
                  _PromptSectionCard(
                    key: const Key('base-prompt-section'),
                    title: context.tr('base_prompts'),
                    icon: Icons.edit_note,
                    accentColor: Theme.of(context).colorScheme.primary,
                    child: PromptConfigView(
                      viewModel: PromptConfigViewModel(
                        config: viewmodel.promptConfig,
                      ),
                    ),
                  ),
                  for (final (index, characterConfig)
                      in viewmodel.characterConfigList.indexed)
                    _PromptSectionCard(
                      key: Key('character-prompt-section-$index'),
                      title: 'Character ${index + 1}',
                      icon: Icons.person_outline,
                      accentColor: Theme.of(context).colorScheme.secondary,
                      child: CharacterConfigView(
                        viewmodel: CharacterConfigViewmodel(
                          config: characterConfig,
                          paramConfig: viewmodel.paramConfig,
                          onAutoPositionChanged: viewmodel.setAutoPosition,
                        ),
                      ),
                    ),
                  _PromptSectionCard(
                    key: const Key('negative-prompt-section'),
                    title: context.tr('negative_prompts'),
                    icon: Icons.block,
                    accentColor: Theme.of(context).colorScheme.tertiary,
                    child: Padding(
                      key: const Key('negative-prompt-config'),
                      padding: const EdgeInsets.only(left: 4),
                      child: PromptConfigView(
                        viewModel: PromptConfigViewModel(
                          config: viewmodel.negativePromptConfig,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
    final buttons = ListenableBuilder(
      listenable: viewmodel,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (viewmodel.payloadConfig != null) ...[
            PromptModeSwitchButton(
              payloadConfig: viewmodel.payloadConfig!,
              onChanged: viewmodel.promptModeChanged,
              heroTag: 'ptvfab-mode',
              expandOnHover: true,
            ),
            const SizedBox(height: 20.0),
          ],
          if (!viewmodel.isFixedMode) ...[
            FloatingActionButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (context) => SavedConfigListView(
                      viewmodel: SavedConfigListViewmodel(
                          configList: viewmodel.savedConfigList)))),
              tooltip: tr('manage_saved_configs'),
              heroTag: 'ptvfab1',
              child: const Icon(Icons.format_list_bulleted),
            ),
            const SizedBox(height: 20.0),
          ],
          FloatingActionButton(
            onPressed: () => _showCharacterRearrangeDialog(context),
            tooltip: tr('rearrange_characters'),
            heroTag: 'ptvfab2',
            child: const Icon(Icons.group),
          ),
        ],
      ),
    );
    return Scaffold(
      body: SingleChildScrollView(
        child: content,
      ),
      floatingActionButton: buttons,
    );
  }

  void _showCharacterRearrangeDialog(BuildContext context) {
    final addCharacterTile = ChangeNotifierProvider.value(
      value: viewmodel,
      child: Consumer<PromptTabViewmodel>(
          builder: (context, viewmodel, child) => ListTile(
                title: Text(tr('add_character')),
                leading: const Icon(Icons.person_add),
                onTap: () => viewmodel.addCharacter(),
                enabled: viewmodel.characterConfigList.length < 6,
              )),
    );
    showDialog(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(tr('rearrange_characters')),
              content: SizedBox(
                  width: 400.0,
                  height: 600.0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Expanded(
                          child: CharacterRearrangeView(viewmodel: viewmodel)),
                      addCharacterTile,
                    ],
                  )),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(tr('confirm')))
              ],
            ));
  }
}

class _FixedPromptEditor extends StatelessWidget {
  const _FixedPromptEditor({required this.viewmodel});

  final PromptTabViewmodel viewmodel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: ListTile(
            leading: const Icon(Icons.push_pin),
            title: Text(context.tr('prompt_mode_fixed_active')),
            subtitle: Text(context.tr('prompt_mode_fixed_active_hint')),
          ),
        ),
        _PromptSectionCard(
          key: const Key('fixed-positive-section'),
          title: context.tr('fixed_positive_prompt'),
          icon: Icons.edit_note,
          accentColor: Theme.of(context).colorScheme.primary,
          child: _FixedTextField(
            fieldKey: const Key('fixed-positive-prompt'),
            initialValue: viewmodel.fixedPromptText,
            hintText: context.tr('fixed_positive_prompt_hint'),
            onChanged: viewmodel.setFixedPrompt,
          ),
        ),
        for (final (index, character) in viewmodel.characterConfigList.indexed)
          _PromptSectionCard(
            key: Key('fixed-character-section-$index'),
            title: '${context.tr('character')} ${index + 1}',
            icon: Icons.person_outline,
            accentColor: Theme.of(context).colorScheme.secondary,
            child: Column(
              children: [
                SwitchListTile(
                  key: Key('fixed-character-enabled-$index'),
                  title: Text(context.tr('enabled')),
                  value: character.enabled,
                  onChanged: (value) =>
                      viewmodel.setCharacterEnabled(index, value),
                ),
                _FixedTextField(
                  fieldKey: Key('fixed-character-positive-$index'),
                  initialValue: viewmodel.fixedCharacterPromptText(index),
                  hintText: context.tr('fixed_character_positive_hint'),
                  onChanged: (value) =>
                      viewmodel.setFixedCharacterPrompt(index, value),
                ),
                _FixedTextField(
                  fieldKey: Key('fixed-character-negative-$index'),
                  initialValue:
                      viewmodel.fixedCharacterNegativePromptText(index),
                  hintText: context.tr('fixed_character_negative_hint'),
                  onChanged: (value) =>
                      viewmodel.setFixedCharacterNegativePrompt(index, value),
                ),
                ListTile(
                  key: Key('fixed-character-position-$index'),
                  leading: const Icon(Icons.location_on_outlined),
                  title: Text(context.tr('character_position')),
                  subtitle: Text(
                    viewmodel.paramConfig.autoPosition
                        ? context.tr('character_position_ai')
                        : CharacterConfigViewmodel(
                            config: character,
                            paramConfig: viewmodel.paramConfig,
                          ).getPositionsTexts(),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editPosition(context, character),
                ),
              ],
            ),
          ),
        _PromptSectionCard(
          key: const Key('fixed-negative-section'),
          title: context.tr('fixed_negative_prompt'),
          icon: Icons.block,
          accentColor: Theme.of(context).colorScheme.tertiary,
          child: _FixedTextField(
            fieldKey: const Key('fixed-negative-prompt'),
            initialValue: viewmodel.fixedNegativePromptText,
            hintText: context.tr('fixed_negative_prompt_hint'),
            onChanged: viewmodel.setFixedNegativePrompt,
          ),
        ),
      ],
    );
  }

  Future<void> _editPosition(
    BuildContext context,
    CharacterConfig character,
  ) async {
    final positionViewmodel = CharacterConfigViewmodel(
      config: character,
      paramConfig: viewmodel.paramConfig,
      onAutoPositionChanged: viewmodel.setAutoPosition,
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          '${dialogContext.tr('edit')}${dialogContext.tr('colon')}'
          '${dialogContext.tr('character_position')}',
        ),
        content: CharacterPositionView(viewmodel: positionViewmodel),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(dialogContext.tr('confirm')),
          ),
        ],
      ),
    );
    viewmodel.promptModeChanged();
  }
}

class _FixedTextField extends StatelessWidget {
  const _FixedTextField({
    required this.fieldKey,
    required this.initialValue,
    required this.hintText,
    required this.onChanged,
  });

  final Key fieldKey;
  final String initialValue;
  final String hintText;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextFormField(
        key: fieldKey,
        initialValue: initialValue,
        minLines: 3,
        maxLines: 8,
        keyboardType: TextInputType.multiline,
        decoration: InputDecoration(
          hintText: hintText,
          border: const OutlineInputBorder(),
          alignLabelWithHint: true,
        ),
        onChanged: onChanged,
      ),
    );
  }
}

class _PromptSectionCard extends StatelessWidget {
  const _PromptSectionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.accentColor,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Color accentColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      child: Material(
        color: Color.alphaBlend(
          accentColor.withAlpha(14),
          colorScheme.surface,
        ),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: accentColor.withAlpha(90)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: accentColor.withAlpha(28),
                border: Border(
                  bottom: BorderSide(color: accentColor.withAlpha(70)),
                ),
              ),
              child: Row(
                children: [
                  Icon(icon, color: accentColor, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: accentColor,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

class CharacterRearrangeView extends StatelessWidget {
  final PromptTabViewmodel viewmodel;

  const CharacterRearrangeView({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
        value: viewmodel,
        child: Consumer<PromptTabViewmodel>(
          builder: (context, viewmodel, child) => ReorderableListView.builder(
            itemBuilder: (context, index) => ListTile(
              key: Key('character-manager-row-$index'),
              title: Text('Character ${index + 1}'),
              leading: const Icon(Icons.person),
              trailing: Padding(
                  padding: const EdgeInsets.only(right: 16.0),
                  child: IconButton(
                    onPressed: () => viewmodel.removeCharacter(index),
                    icon: const Icon(Icons.delete),
                  )),
            ),
            itemCount: viewmodel.characterConfigList.length,
            onReorder: (oldIndex, newIndex) =>
                viewmodel.reorderCharacter(oldIndex, newIndex),
          ),
        ));
  }
}
