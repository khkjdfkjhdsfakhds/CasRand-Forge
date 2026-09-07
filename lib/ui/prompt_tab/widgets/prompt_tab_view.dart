import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/ui/character_config/widgets/character_config_view.dart';
import 'package:nai_casrand/ui/character_config/view_models/character_config_viewmodel.dart';
import 'package:nai_casrand/ui/core/widgets/prompt_mode_switch_button.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_config_view.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_search_replace_bar.dart';
import 'package:nai_casrand/ui/prompt_config/view_models/prompt_config_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_transform.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_weight_syntax.dart';
import 'package:nai_casrand/ui/saved_config_list/view_models/saved_config_list_viewmodel.dart';
import 'package:nai_casrand/ui/saved_config_list/widgets/saved_config_list_view.dart';
import 'package:provider/provider.dart';

/// Line bounds for the fixed-mode positive prompt editor.
///
/// Most NAI5 tags are dumped into this field, so it starts taller than the
/// generic assisted field and grows with content until
/// [kFixedPromptFieldMaxLines] before scrolling internally.
const int kFixedPromptFieldMinLines = 10;
const int kFixedPromptFieldMaxLines = 24;

/// Line bounds for the fixed-mode negative prompt editor.
const int kFixedNegativePromptMinLines = 4;
const int kFixedNegativePromptMaxLines = 8;

class PromptTabView extends StatelessWidget {
  const PromptTabView({
    super.key,
    required this.viewmodel,
    this.promptAssistance,
  });

  final PromptTabViewmodel viewmodel;
  final PromptEditingAssistance? promptAssistance;

  @override
  Widget build(BuildContext context) {
    final changes = Listenable.merge([
      viewmodel,
      if (viewmodel.payloadConfig != null) viewmodel.payloadConfig!,
    ]);
    final content = ChangeNotifierProvider.value(
      value: viewmodel,
      child: ListenableBuilder(
        listenable: changes,
        builder: (context, child) => viewmodel.isFixedMode
            ? _FixedPromptEditor(
                viewmodel: viewmodel,
                promptAssistance:
                    promptAssistance ?? PromptEditingAssistance.shared,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PromptSectionCard(
                    key: const Key('base-prompt-section'),
                    title: context.tr('base_prompts'),
                    icon: Icons.edit_note,
                    accentColor: Theme.of(context).colorScheme.primary,
                    child: PromptConfigView(
                      viewModel: PromptConfigViewModel(
                        config: viewmodel.promptConfig,
                      ),
                      promptAssistance:
                          promptAssistance ?? PromptEditingAssistance.shared,
                      autocompleteEnabled: viewmodel.promptAutocompleteEnabled,
                    ),
                  ),
                  for (final (index, characterConfig)
                      in viewmodel.characterConfigList.indexed)
                    _CharacterPromptSection(
                      key: ObjectKey(characterConfig),
                      viewmodel: viewmodel,
                      character: characterConfig,
                      index: index,
                      promptAssistance:
                          promptAssistance ?? PromptEditingAssistance.shared,
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
                        promptAssistance:
                            promptAssistance ?? PromptEditingAssistance.shared,
                        autocompleteEnabled:
                            viewmodel.promptAutocompleteEnabled,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
    final buttons = ListenableBuilder(
      listenable: changes,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (viewmodel.payloadConfig != null) ...[
            PromptModeSwitchButton(
              payloadConfig: viewmodel.payloadConfig!,
              onChanged: viewmodel.promptModeChanged,
              heroTag: 'ptvfab-mode',
            ),
            const SizedBox(height: 20.0),
          ],
          if (!viewmodel.isFixedMode) ...[
            FloatingActionButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (context) => SavedConfigListView(
                      viewmodel: SavedConfigListViewmodel(
                          configList: viewmodel.savedConfigList),
                      promptAssistance:
                          promptAssistance ?? PromptEditingAssistance.shared,
                      autocompleteEnabled:
                          viewmodel.promptAutocompleteEnabled))),
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
        key: const Key('prompt-tab-scroll'),
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
  const _FixedPromptEditor({
    required this.viewmodel,
    this.promptAssistance,
  });

  final PromptTabViewmodel viewmodel;
  final PromptEditingAssistance? promptAssistance;

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
            autocompleteEnabled: viewmodel.promptAutocompleteEnabled,
            assistance: promptAssistance,
            onChanged: viewmodel.setFixedPrompt,
            minLines: kFixedPromptFieldMinLines,
            maxLines: kFixedPromptFieldMaxLines,
          ),
        ),
        for (final (index, character) in viewmodel.characterConfigList.indexed)
          _CharacterPromptSection(
            key: ObjectKey(character),
            viewmodel: viewmodel,
            character: character,
            index: index,
            promptAssistance:
                promptAssistance ?? PromptEditingAssistance.shared,
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
            autocompleteEnabled: viewmodel.promptAutocompleteEnabled,
            assistance: promptAssistance,
            onChanged: viewmodel.setFixedNegativePrompt,
            minLines: kFixedNegativePromptMinLines,
            maxLines: kFixedNegativePromptMaxLines,
          ),
        ),
      ],
    );
  }
}

class _FixedTextField extends StatefulWidget {
  const _FixedTextField({
    required this.fieldKey,
    required this.initialValue,
    required this.hintText,
    required this.onChanged,
    required this.minLines,
    required this.maxLines,
    this.autocompleteEnabled = false,
    this.assistance,
  });

  final Key fieldKey;
  final String initialValue;
  final String hintText;
  final ValueChanged<String> onChanged;
  final bool autocompleteEnabled;
  final PromptEditingAssistance? assistance;
  final int minLines;
  final int maxLines;

  @override
  State<_FixedTextField> createState() => _FixedTextFieldState();
}

class _FixedTextFieldState extends State<_FixedTextField> {
  final _assistedFieldKey = GlobalKey<PromptAssistedTextFieldState>();
  late final _HighlightableTextController _controller;
  late final FocusNode _focusNode;
  bool _searchVisible = false;

  @override
  void initState() {
    super.initState();
    _controller = _HighlightableTextController(text: widget.initialValue);
    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
  }

  @override
  void didUpdateWidget(covariant _FixedTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The user may have edited the controller since the previous widget
    // value was supplied. A re-import of that same value is still a change.
    // Leave equal text untouched so normal rebuilds preserve caret and IME.
    if (widget.initialValue != _controller.text) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final hardware = HardwareKeyboard.instance;
    final modifierPressed = hardware.isMetaPressed || hardware.isControlPressed;

    if (modifierPressed &&
        !hardware.isShiftPressed &&
        !hardware.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.keyF) {
      setState(() {
        _searchVisible = true;
      });
      return KeyEventResult.handled;
    }

    if (!hardware.isControlPressed ||
        hardware.isMetaPressed ||
        hardware.isAltPressed ||
        hardware.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => _FixedShortcut.weightIncrease,
      LogicalKeyboardKey.arrowDown => _FixedShortcut.weightDecrease,
      LogicalKeyboardKey.arrowLeft => _FixedShortcut.moveBackward,
      LogicalKeyboardKey.arrowRight => _FixedShortcut.moveForward,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;

    final fieldState = _assistedFieldKey.currentState;
    if (fieldState == null) return KeyEventResult.handled;
    final current = fieldState.editingValue;
    if (current.composing.isValid && !current.composing.isCollapsed) {
      // IME composition always has priority over editor shortcuts.
      return KeyEventResult.ignored;
    }
    final result = switch (direction) {
      _FixedShortcut.weightIncrease => PromptEditingTransform.adjustWeight(
          current,
          direction: PromptWeightDirection.increase,
        ),
      _FixedShortcut.weightDecrease => PromptEditingTransform.adjustWeight(
          current,
          direction: PromptWeightDirection.decrease,
        ),
      _FixedShortcut.moveBackward => PromptEditingTransform.move(
          current,
          direction: PromptMoveDirection.backward,
        ),
      _FixedShortcut.moveForward => PromptEditingTransform.move(
          current,
          direction: PromptMoveDirection.forward,
        ),
    };
    if (result.changed) {
      fieldState.setEditingValue(result.value);
      widget.onChanged(result.value.text);
    }
    // Consume a Control-arrow even at a valid boundary so the platform's
    // native word/line navigation cannot move the caret as a side effect.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PromptSearchReplaceBar(
            controller: _controller,
            focusNode: _focusNode,
            visible: _searchVisible,
            onClose: () => setState(() => _searchVisible = false),
            onChanged: widget.onChanged,
          ),
          PromptAssistedTextField(
            key: _assistedFieldKey,
            controller: _controller,
            focusNode: _focusNode,
            fieldKey: widget.fieldKey,
            initialValue: widget.initialValue,
            hintText: widget.hintText,
            onChanged: widget.onChanged,
            assistance: widget.assistance,
            completionEnabled: widget.autocompleteEnabled,
            normalizeWeightOnFocusLoss: true,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
          ),
        ],
      ),
    );
  }
}

/// A [TextEditingController] that supports search-match highlighting via the
/// [SearchHighlightable] mixin.
class _HighlightableTextController extends TextEditingController
    with SearchHighlightable {
  _HighlightableTextController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = super.buildTextSpan(
      context: context,
      style: style,
      withComposing: withComposing,
    );
    final weighted = PromptWeightSyntax.applyHighlights(base, text);
    return applySearchHighlights(weighted, context);
  }
}

enum _FixedShortcut {
  weightIncrease,
  weightDecrease,
  moveBackward,
  moveForward,
}

class _CharacterPromptSection extends StatefulWidget {
  const _CharacterPromptSection({
    super.key,
    required this.viewmodel,
    required this.character,
    required this.index,
    required this.promptAssistance,
  });

  final PromptTabViewmodel viewmodel;
  final CharacterConfig character;
  final int index;
  final PromptEditingAssistance promptAssistance;

  @override
  State<_CharacterPromptSection> createState() =>
      _CharacterPromptSectionState();
}

class _CharacterPromptSectionState extends State<_CharacterPromptSection> {
  bool _expanded = true;
  bool _restored = false;
  late final CharacterConfigViewmodel _details;
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.character.name);
    _details = CharacterConfigViewmodel(
      config: widget.character,
      paramConfig: widget.viewmodel.paramConfig,
      onAutoPositionChanged: widget.viewmodel.setAutoPosition,
    );
  }

  @override
  void didUpdateWidget(covariant _CharacterPromptSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_nameController.text != widget.character.name) {
      _nameController.value = TextEditingValue(
        text: widget.character.name,
        selection:
            TextSelection.collapsed(offset: widget.character.name.length),
      );
    }
    _details
      ..config = widget.character
      ..paramConfig = widget.viewmodel.paramConfig
      ..onAutoPositionChanged = widget.viewmodel.setAutoPosition;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _details.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_restored) {
      _expanded = PageStorage.maybeOf(context)
              ?.readState(context, identifier: widget.character) as bool? ??
          true;
      _restored = true;
    }
  }

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(
      context,
      _expanded,
      identifier: widget.character,
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewmodel;
    final index = widget.index;
    final prefix = vm.isFixedMode ? 'fixed-character' : 'character-prompt';
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 600;
      final buttonSize = compact ? 40.0 : 48.0;
      final controlGap = compact ? 4.0 : 12.0;
      Widget action(
              String key, String tooltip, IconData icon, VoidCallback? tap) =>
          IconButton(
            key: Key(key),
            tooltip: context.tr(tooltip),
            onPressed: tap,
            icon: Icon(icon, size: compact ? 22 : 26),
            constraints:
                BoxConstraints.tightFor(width: buttonSize, height: buttonSize),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.standard,
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          );
      return _PromptSectionCard(
        key: Key('$prefix-section-$index'),
        title: context
            .tr('character_number', namedArgs: {'number': '${index + 1}'}),
        titleWidget: TextField(
          key: const Key('character-name-field'),
          controller: _nameController,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.secondary,
                fontWeight: FontWeight.w600,
              ),
          decoration: InputDecoration(
            hintText: context
                .tr('character_number', namedArgs: {'number': '${index + 1}'}),
            hintStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: FontWeight.w600,
                ),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
          textInputAction: TextInputAction.done,
          onChanged: (value) => vm.renameCharacter(widget.character, value),
        ),
        icon: Icons.person_outline,
        accentColor: Theme.of(context).colorScheme.secondary,
        expanded: _expanded,
        trailing: Row(
          spacing: controlGap,
          mainAxisSize: MainAxisSize.min,
          children: [
            action(
                'character-move-up',
                'move_character_up',
                Icons.arrow_drop_up,
                index > 0
                    ? () => vm.reorderCharacterAdjusted(index, index - 1)
                    : null),
            action(
                'character-move-down',
                'move_character_down',
                Icons.arrow_drop_down,
                index < vm.characterConfigList.length - 1
                    ? () => vm.reorderCharacterAdjusted(index, index + 1)
                    : null),
            Tooltip(
              message:
                  context.tr(widget.character.enabled ? 'enabled' : 'disabled'),
              child: SizedBox(
                width: buttonSize,
                height: buttonSize,
                child: Checkbox(
                  key: const Key('character-enabled-checkbox'),
                  value: widget.character.enabled,
                  onChanged: (value) {
                    if (value != null) vm.setCharacterEnabled(index, value);
                  },
                ),
              ),
            ),
            action('character-delete-button', 'delete', Icons.delete_outline,
                () => vm.removeCharacter(index)),
            action(
                'character-expand-button',
                _expanded ? 'collapse_character' : 'expand_character',
                _expanded ? Icons.unfold_less : Icons.unfold_more,
                _toggleExpanded),
          ],
        ),
        child: CharacterConfigView(
          viewmodel: _details,
          characterIndex: index,
          referencePositions:
              vm.characterConfigList.map((c) => c.freeCenter).toList(),
          promptAssistance: widget.promptAssistance,
          autocompleteEnabled: vm.promptAutocompleteEnabled,
        ),
      );
    });
  }
}

class _PromptSectionCard extends StatelessWidget {
  const _PromptSectionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.accentColor,
    required this.child,
    this.trailing,
    this.titleWidget,
    this.expanded = true,
  });

  final String title;
  final IconData icon;
  final Color accentColor;
  final Widget child;
  final Widget? trailing;
  final Widget? titleWidget;
  final bool expanded;

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
              key: const Key('prompt-section-header'),
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
                  Expanded(
                    child: titleWidget ??
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: accentColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
            Visibility(
              visible: expanded,
              maintainState: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
                child: child,
              ),
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
              title: Text(
                viewmodel.characterConfigList[index].name.isNotEmpty
                    ? viewmodel.characterConfigList[index].name
                    : context.tr(
                        'character_number',
                        namedArgs: {'number': '${index + 1}'},
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              leading: const Icon(Icons.person),
              trailing: Padding(
                  padding: const EdgeInsets.only(right: 16.0),
                  child: IconButton(
                    onPressed: () => viewmodel.removeCharacter(index),
                    icon: const Icon(Icons.delete),
                  )),
            ),
            itemCount: viewmodel.characterConfigList.length,
            onReorderItem: viewmodel.reorderCharacterAdjusted,
          ),
        ));
  }
}
