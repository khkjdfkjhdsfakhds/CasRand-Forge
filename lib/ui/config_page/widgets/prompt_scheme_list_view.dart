import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/generation_profile.dart';
import 'package:nai_casrand/ui/config_page/view_models/config_page_viewmodel.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/widgets/prompt_mode_switch_button.dart';
import 'package:nai_casrand/ui/navigation/widgets/image_import_area.dart';
import 'package:nai_casrand/ui/parameters_config/view_models/parameters_config_viewmodel.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/parameters_conifg_view.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';

/// Every random prompt scheme as a card. Expanding a card only shows it for
/// viewing and editing; the switch in its header decides which one generates.
class PromptSchemeListView extends StatelessWidget {
  const PromptSchemeListView({super.key, required this.viewmodel});

  final ConfigPageViewmodel viewmodel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: _PageButtons(viewmodel: viewmodel),
      body: ImageImportArea(
        ignoreWhenTextEditing: true,
        child: ListenableBuilder(
          listenable: viewmodel.promptSchemeChanges,
          builder: (context, _) {
            viewmodel.syncPromptSchemeViewState();
            final config = viewmodel.payloadConfig;
            final schemes = config.promptSchemes;
            return ListView.builder(
              key: const PageStorageKey('prompt-scheme-list'),
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 104),
              itemCount: schemes.length + 1,
              findChildIndexCallback: (key) {
                if (key is! ObjectKey) return null;
                final index = schemes.indexWhere(
                  (scheme) => identical(scheme.profile, key.value),
                );
                return index < 0 ? null : index;
              },
              itemBuilder: (context, index) {
                if (index == schemes.length) {
                  return _NewSchemeButton(viewmodel: viewmodel);
                }
                final scheme = schemes[index];
                return _PromptSchemeCard(
                  key: ObjectKey(scheme.profile),
                  viewmodel: viewmodel,
                  scheme: scheme,
                  index: index,
                  isLast: index == schemes.length - 1,
                  isActive: index == config.currentPromptSchemeIndex,
                  isExpanded: viewmodel.isPromptSchemeExpanded(scheme),
                  canChange: viewmodel.canChangePromptSchemes,
                  canDelete: viewmodel.canDeletePromptScheme,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _PageButtons extends StatelessWidget {
  const _PageButtons({required this.viewmodel});

  final ConfigPageViewmodel viewmodel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        PromptModeSwitchButton(
          payloadConfig: viewmodel.payloadConfig,
          onChanged: () {},
          heroTag: 'config-fab-mode',
        ),
        const SizedBox(height: 20),
        FloatingActionButton(
          heroTag: 'config-fab-saved',
          tooltip: tr('manage_saved_configs'),
          onPressed: () => openSavedConfigList(
            context,
            viewmodel.activePromptViewmodel,
          ),
          child: const Icon(Icons.format_list_bulleted),
        ),
        const SizedBox(height: 20),
        FloatingActionButton(
          heroTag: 'config-fab-import',
          tooltip: tr('import_metadata_from_image'),
          onPressed: () => showImportMetadataDialog(
            context,
            viewmodel.activeParametersViewmodel,
          ),
          child: const Icon(Icons.image_outlined),
        ),
      ],
    );
  }
}

class _NewSchemeButton extends StatelessWidget {
  const _NewSchemeButton({required this.viewmodel});

  final ConfigPageViewmodel viewmodel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Tooltip(
        message: viewmodel.canChangePromptSchemes
            ? context.tr('prompt_scheme_new_hint')
            : context.tr('prompt_scheme_locked_generating'),
        child: OutlinedButton.icon(
          key: const Key('prompt-scheme-add'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(46),
            foregroundColor: colors.primary,
            side: BorderSide(color: colors.outlineVariant),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: viewmodel.canChangePromptSchemes
              ? () => viewmodel.createPromptScheme(
                    viewmodel.payloadConfig.nextPromptSchemeName(
                      (number) => tr(
                        'prompt_scheme_default_name',
                        namedArgs: {'number': '$number'},
                      ),
                    ),
                  )
              : null,
          icon: const Icon(Icons.add, size: 20),
          label: Text(context.tr('prompt_scheme_new')),
        ),
      ),
    );
  }
}

class _PromptSchemeCard extends StatefulWidget {
  const _PromptSchemeCard({
    super.key,
    required this.viewmodel,
    required this.scheme,
    required this.index,
    required this.isLast,
    required this.isActive,
    required this.isExpanded,
    required this.canChange,
    required this.canDelete,
  });

  final ConfigPageViewmodel viewmodel;
  final PromptScheme scheme;
  final int index;
  final bool isLast;
  final bool isActive;
  final bool isExpanded;
  final bool canChange;
  final bool canDelete;

  @override
  State<_PromptSchemeCard> createState() => _PromptSchemeCardState();
}

class _PromptSchemeCardState extends State<_PromptSchemeCard>
    with SingleTickerProviderStateMixin {
  late final PromptTabViewmodel _promptViewmodel;
  late final ParametersConfigViewmodel _parametersViewmodel;
  late final TextEditingController _nameController;
  late final FocusNode _nameFocus;
  late final TabController _tabController;
  late final Widget _promptsTab;
  late final Widget _parametersTab;
  late int _shownTab;
  late String _promptsModel;

  /// A tab is built the first time it is shown and then kept mounted, so
  /// coming back to it costs no rebuild and keeps its expansion state.
  final Set<int> _builtTabs = {};

  @override
  void initState() {
    super.initState();
    _promptViewmodel = PromptTabViewmodel(
      payloadConfig: widget.viewmodel.payloadConfig,
      profile: widget.scheme.profile,
    );
    _parametersViewmodel =
        ParametersConfigViewmodel(profile: widget.scheme.profile);
    _nameController = TextEditingController(text: widget.scheme.name);
    _nameFocus = FocusNode()
      ..addListener(() {
        if (!_nameFocus.hasFocus) _commitName();
      });
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.viewmodel.selectedTab(widget.scheme),
    )..addListener(_onTabChanged);
    _shownTab = _tabController.index;
    _builtTabs.add(_shownTab);
    _promptsTab = PromptTabContent(viewmodel: _promptViewmodel);
    _parametersTab = ParametersConfigView(
      viewmodel: _parametersViewmodel,
      embedded: true,
    );
    _promptsModel = widget.scheme.profile.paramConfig.model;
    _parametersViewmodel.addListener(_onParametersChanged);
  }

  /// The kept prompt tab depends on the model (character limit, notices).
  void _onParametersChanged() {
    final model = widget.scheme.profile.paramConfig.model;
    if (model == _promptsModel) return;
    _promptsModel = model;
    _promptViewmodel.notifyConfigChanged();
  }

  /// Runs on the controller's first notification, when the index has already
  /// changed: the content switches at once while the indicator animates.
  void _onTabChanged() {
    final index = _tabController.index;
    if (index == _shownTab) return;
    widget.viewmodel.setSelectedTab(widget.scheme, index);
    setState(() {
      _shownTab = index;
      _builtTabs.add(index);
    });
  }

  @override
  void didUpdateWidget(covariant _PromptSchemeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_nameFocus.hasFocus && _nameController.text != widget.scheme.name) {
      _nameController.text = widget.scheme.name;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _parametersViewmodel.removeListener(_onParametersChanged);
    _nameController.dispose();
    _nameFocus.dispose();
    _promptViewmodel.dispose();
    _parametersViewmodel.dispose();
    super.dispose();
  }

  void _commitName() {
    final text = _nameController.text;
    if (text.trim() == widget.scheme.name) {
      _nameController.text = widget.scheme.name;
      return;
    }
    final error = widget.viewmodel.validatePromptSchemeName(
      text,
      index: widget.index,
    );
    if (error == null) {
      widget.viewmodel.renamePromptScheme(widget.index, text);
      return;
    }
    _nameController.text = widget.scheme.name;
    showErrorBar(
      context,
      context.tr(
        error == PromptSchemeNameError.empty
            ? 'prompt_scheme_name_empty'
            : 'prompt_scheme_name_duplicate',
      ),
    );
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.tr('prompt_scheme_delete')),
        content: Text([
          dialogContext.tr(
            'prompt_scheme_delete_confirm',
            namedArgs: {'name': widget.scheme.name},
          ),
          if (widget.isActive)
            dialogContext.tr('prompt_scheme_delete_active_note'),
        ].join('\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.tr('cancel')),
          ),
          FilledButton(
            key: const Key('prompt-scheme-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.tr('delete')),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.viewmodel.deletePromptScheme(widget.index);
  }

  VoidCallback? get _moveUp => widget.canChange && widget.index > 0
      ? () => widget.viewmodel.movePromptScheme(widget.index, widget.index - 1)
      : null;

  VoidCallback? get _moveDown => widget.canChange && !widget.isLast
      ? () => widget.viewmodel.movePromptScheme(widget.index, widget.index + 1)
      : null;

  VoidCallback? get _deleteAction => widget.canDelete ? _delete : null;

  void _toggleExpanded() =>
      widget.viewmodel.togglePromptSchemeExpanded(widget.scheme);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = widget.isActive;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        key: Key('prompt-scheme-card-${widget.index}'),
        color: colors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color:
                active ? colors.primary.withAlpha(150) : colors.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            if (widget.isExpanded) _buildBody(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final active = widget.isActive;
    final foreground = active ? colors.primary : colors.onSurface;
    return Material(
      // Lighter than the section headers inside the card: the outline, the
      // badge and the icon mark the active scheme, not a block of color.
      color: active ? colors.primary.withAlpha(16) : Colors.transparent,
      child: InkWell(
        key: const Key('prompt-scheme-header'),
        onTap: _toggleExpanded,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 520;
            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
              child: IconTheme.merge(
                data: IconThemeData(color: colors.onSurfaceVariant),
                child: Row(
                  children: [
                    Icon(
                      active ? Icons.layers : Icons.layers_outlined,
                      size: 20,
                      color: active ? colors.primary : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(child: _buildNameField(theme, foreground)),
                            if (active) ...[
                              const SizedBox(width: 10),
                              const _ActiveBadge(),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (compact)
                      _buildCompactMenu(context)
                    else ...[
                      _HeaderButton(
                        buttonKey: const Key('prompt-scheme-move-up'),
                        tooltip: 'prompt_scheme_move_up',
                        icon: Icons.arrow_upward,
                        onPressed: _moveUp,
                      ),
                      _HeaderButton(
                        buttonKey: const Key('prompt-scheme-move-down'),
                        tooltip: 'prompt_scheme_move_down',
                        icon: Icons.arrow_downward,
                        onPressed: _moveDown,
                      ),
                    ],
                    _buildSwitch(context),
                    if (!compact)
                      _HeaderButton(
                        buttonKey: const Key('prompt-scheme-delete'),
                        tooltip: 'delete',
                        icon: Icons.delete_outline,
                        onPressed: _deleteAction,
                      ),
                    _HeaderButton(
                      buttonKey: const Key('prompt-scheme-expand'),
                      tooltip: widget.isExpanded
                          ? 'prompt_scheme_collapse'
                          : 'prompt_scheme_expand',
                      icon: widget.isExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      onPressed: _toggleExpanded,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildNameField(ThemeData theme, Color foreground) {
    final style = theme.textTheme.titleMedium?.copyWith(
      color: foreground,
      fontWeight: FontWeight.w600,
    );
    return IntrinsicWidth(
      child: TextField(
        key: const Key('prompt-scheme-name-field'),
        controller: _nameController,
        focusNode: _nameFocus,
        readOnly: !widget.canChange,
        style: style,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _nameFocus.unfocus(),
        decoration: const InputDecoration(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 8),
        ),
      ),
    );
  }

  Widget _buildSwitch(BuildContext context) {
    final active = widget.isActive;
    return Tooltip(
      message: context.tr(
        active
            ? 'prompt_scheme_active_hint'
            : widget.canChange
                ? 'prompt_scheme_activate'
                : 'prompt_scheme_locked_generating',
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Transform.scale(
          scale: 0.8,
          child: Switch(
            key: const Key('prompt-scheme-active-switch'),
            value: active,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            // One scheme always stays active: turning off the active one has
            // no effect, and it keeps its full color instead of looking disabled.
            onChanged: active
                ? (_) {}
                : widget.canChange
                    ? (_) => widget.viewmodel.activatePromptScheme(widget.index)
                    : null,
          ),
        ),
      ),
    );
  }

  Widget _buildCompactMenu(BuildContext context) {
    PopupMenuItem<VoidCallback> item(
      String key,
      String label,
      IconData icon,
      VoidCallback? action,
    ) {
      return PopupMenuItem(
        key: Key(key),
        value: action,
        enabled: action != null,
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 12),
            Text(context.tr(label)),
          ],
        ),
      );
    }

    return PopupMenuButton<VoidCallback>(
      key: const Key('prompt-scheme-more'),
      tooltip: context.tr('prompt_scheme_more'),
      icon: const Icon(Icons.more_horiz, size: 20),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 160),
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        item('prompt-scheme-move-up', 'prompt_scheme_move_up',
            Icons.arrow_upward, _moveUp),
        item('prompt-scheme-move-down', 'prompt_scheme_move_down',
            Icons.arrow_downward, _moveDown),
        item('prompt-scheme-delete', 'delete', Icons.delete_outline,
            _deleteAction),
      ],
    );
  }

  Widget _buildCharactersButton(BuildContext context, {required bool compact}) {
    void open() => showCharacterRearrangeDialog(context, _promptViewmodel);
    if (compact) {
      return _HeaderButton(
        buttonKey: const Key('prompt-scheme-characters'),
        tooltip: 'rearrange_characters',
        icon: Icons.group_outlined,
        onPressed: open,
      );
    }
    return TextButton.icon(
      key: const Key('prompt-scheme-characters'),
      onPressed: open,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      icon: const Icon(Icons.group_outlined, size: 18),
      label: Text(context.tr('rearrange_characters')),
    );
  }

  Widget _buildBody(BuildContext context) {
    final showPrompts = _shownTab == 0;
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildBodyContent(context, constraints.maxWidth < 520, showPrompts),
    );
  }

  Widget _buildBodyContent(
    BuildContext context,
    bool compact,
    bool showPrompts,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colors.outlineVariant.withAlpha(120)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  dividerHeight: 0,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                  labelStyle: theme.textTheme.titleSmall,
                  tabs: [
                    Tab(height: 40, text: tr('generation_prompt_config')),
                    Tab(height: 40, text: tr('generation_parameters')),
                  ],
                ),
              ),
              if (showPrompts)
                _buildCharactersButton(context, compact: compact),
              const SizedBox(width: 6),
            ],
          ),
        ),
        for (final (tab, content) in [_promptsTab, _parametersTab].indexed)
          if (_builtTabs.contains(tab))
            Visibility(
              key: ValueKey<int>(tab),
              visible: tab == _shownTab,
              maintainState: true,
              child: content,
            ),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: buttonKey,
      tooltip: context.tr(tooltip),
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      color: IconTheme.of(context).color,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('prompt-scheme-active-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withAlpha(28),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.primary.withAlpha(90)),
      ),
      child: Text(
        context.tr('prompt_scheme_active_badge'),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
