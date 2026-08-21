import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_entry_divider.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_entry_editor.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_config_delete_view.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_config_edit_view.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_config_reorder_view.dart';
import 'package:nai_casrand/ui/prompt_config/view_models/prompt_config_viewmodel.dart';
import 'package:provider/provider.dart';

class PromptConfigView extends StatelessWidget {
  final PromptConfigViewModel viewModel;
  final PromptEditingAssistance? promptAssistance;
  final bool autocompleteEnabled;

  const PromptConfigView({
    super.key,
    required this.viewModel,
    this.promptAssistance,
    this.autocompleteEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<PromptConfigViewModel>.value(
      value: viewModel,
      child: Consumer<PromptConfigViewModel>(
        builder: (context, viewModel, child) {
          final backgroundColor = viewModel.isEnabled
              ? null
              : Theme.of(context).disabledColor.withAlpha(30);

          return Padding(
            padding: EdgeInsets.only(left: viewModel.isRoot ? 0 : 20),
            child: ExpansionTile(
              title: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  Text(viewModel.config.comment),
                  TextButton(
                    child: Text(viewModel.getConfigDescrption(context)),
                    onPressed: () => _showConfigDialog(viewModel, context),
                  )
                ]),
              ),
              trailing: viewModel.isRoot
                  ? const SizedBox.shrink()
                  : Switch(
                      value: viewModel.isEnabled,
                      onChanged: (value) => viewModel.setEnabled(value),
                    ),
              backgroundColor: backgroundColor,
              collapsedBackgroundColor: backgroundColor,
              controlAffinity: ListTileControlAffinity.leading,
              initiallyExpanded: viewModel.initiallyExpanded,
              children: _buildChildrenList(viewModel, context),
            ),
          );
        },
      ),
    );
  }

  void _showConfigDialog(
    PromptConfigViewModel viewModel,
    BuildContext context,
  ) {
    showDialog(
      context: context,
      builder: (context) => PromptConfigEditView(viewModel: viewModel),
    );
  }

  List<Widget> _buildChildrenList(
      PromptConfigViewModel viewModel, BuildContext context) {
    if (viewModel.config.type == 'config') {
      List<Widget> children = [];
      for (var subViewModel in viewModel.subConfigs) {
        children.add(
          PromptConfigView(
            viewModel: subViewModel,
            promptAssistance: promptAssistance,
            autocompleteEnabled: autocompleteEnabled,
          ),
        );
      }
      children.add(_buildButtonsRow(viewModel, context));
      return children;
    } else {
      return [
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: ListTile(
            title: Text(
                '${context.tr('cascaded_strings')}${context.tr('colon')}${viewModel.config.usableEntryCount}${context.tr('items')}'),
            subtitle: _PromptEntryPreview(entries: viewModel.config.strs),
            onTap: () => _editStrList(context),
          ),
        )
      ];
    }
  }

  void _editStrList(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _PromptEntryEditorDialog(
        viewModel: viewModel,
        promptAssistance: promptAssistance,
        autocompleteEnabled: autocompleteEnabled,
      ),
    );
  }

  Widget _buildButtonsRow(
    PromptConfigViewModel viewModel,
    BuildContext context,
  ) {
    return ListTile(
        title: Row(
      children: [
        Expanded(
          child: Tooltip(
            message: context.tr('add_new_config'),
            child: IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => viewModel.addNewConfig(),
            ),
          ),
        ),
        Expanded(
          child: Tooltip(
            message: context.tr('import_config_from_clipboard'),
            child: IconButton(
              icon: const Icon(Icons.paste),
              onPressed: () => viewModel.importConfigFromClipboard(context),
            ),
          ),
        ),
        Expanded(
          child: Tooltip(
            message: context.tr('reorder_config'),
            child: IconButton(
              icon: const Icon(Icons.cached),
              onPressed: () => _showReorderDialog(viewModel, context),
            ),
          ),
        ),
        Expanded(
          child: Tooltip(
            message: context.tr('delete_config'),
            child: IconButton(
              icon: const Icon(Icons.remove),
              onPressed: () => _showDeleteDialog(viewModel, context),
            ),
          ),
        ),
        const SizedBox(width: 40),
      ],
    ));
  }

  void _showReorderDialog(
    PromptConfigViewModel viewModel,
    BuildContext context,
  ) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.tr('reorder_config')),
          content: SizedBox(
            width: 400.0,
            height: 600.0,
            child: PromptConfigReorderView(viewModel: viewModel),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(context.tr('confirm')),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteDialog(
    PromptConfigViewModel viewModel,
    BuildContext context,
  ) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.tr('delete_config')),
          content: SizedBox(
            width: 400.0,
            height: 600.0,
            child: PromptComfigDeleteView(viewModel: viewModel),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(context.tr('confirm')),
            ),
          ],
        );
      },
    );
  }
}

class _PromptEntryEditorDialog extends StatefulWidget {
  const _PromptEntryEditorDialog({
    required this.viewModel,
    this.promptAssistance,
    required this.autocompleteEnabled,
  });

  final PromptConfigViewModel viewModel;
  final PromptEditingAssistance? promptAssistance;
  final bool autocompleteEnabled;

  @override
  State<_PromptEntryEditorDialog> createState() =>
      _PromptEntryEditorDialogState();
}

class _PromptEntryEditorDialogState extends State<_PromptEntryEditorDialog> {
  late List<String> _entries;

  @override
  void initState() {
    super.initState();
    _entries = List.of(widget.viewModel.config.strs);
  }

  @override
  Widget build(BuildContext context) {
    final mediaSize = MediaQuery.sizeOf(context);
    final availableWidth = mediaSize.width - 128;
    final availableHeight = mediaSize.height - 220;
    return AlertDialog(
      title: Text('${context.tr('edit')}${context.tr('cascaded_strings')}'),
      content: SizedBox(
        width: availableWidth.clamp(240, 620),
        height: availableHeight.clamp(180, 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                context.tr('edit_cascaded_config_str_notice'),
                key: const Key('prompt-entry-help'),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: PromptEntryEditor(
                initialEntries: _entries,
                onChanged: (value) => _entries = value,
                promptAssistance: widget.promptAssistance,
                autocompleteEnabled: widget.autocompleteEnabled,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          child: Text(context.tr('cancel')),
          onPressed: () => Navigator.of(context).pop(),
        ),
        TextButton(
          child: Text(context.tr('confirm')),
          onPressed: () {
            widget.viewModel.setEntries(_entries);
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}

class _PromptEntryPreview extends StatelessWidget {
  const _PromptEntryPreview({required this.entries});

  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    final dividerColor = promptEntryDividerColor(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, entry) in entries.indexed) ...[
          Text(entry),
          if (index < entries.length - 1)
            PromptEntryDivider(
              key: Key('prompt-preview-divider-$index'),
              color: dividerColor,
            ),
        ],
      ],
    );
  }
}
