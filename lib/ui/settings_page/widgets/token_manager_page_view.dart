import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/settings_page/view_models/token_manager_viewmodel.dart';

/// Management page for multiple NovelAI API tokens (concurrent generation).
class TokenManagerPageView extends StatefulWidget {
  const TokenManagerPageView({super.key});

  @override
  State<TokenManagerPageView> createState() => _TokenManagerPageViewState();
}

class _TokenManagerPageViewState extends State<TokenManagerPageView> {
  final TokenManagerViewmodel viewmodel = TokenManagerViewmodel();

  @override
  void initState() {
    super.initState();
    viewmodel.refreshAllBalances();
  }

  @override
  void dispose() {
    viewmodel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('api_tokens_manage')),
        actions: [
          IconButton(
            tooltip: tr('anlas_balance_refresh'),
            onPressed: viewmodel.refreshAllBalances,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('token-manager-add'),
        onPressed: () => _showAddTokenDialog(context),
        icon: const Icon(Icons.add),
        label: Text(tr('api_token_add')),
      ),
      body: ListenableBuilder(
        listenable: viewmodel,
        builder: (context, _) {
          final tokens = viewmodel.tokens;
          return Column(
            children: [
              SwitchListTile(
                key: const Key('token-manager-parallel-switch'),
                secondary: const Icon(Icons.bolt_outlined),
                title: Text(tr('api_tokens_parallel_enabled')),
                subtitle: Text(tr('api_tokens_parallel_hint')),
                value: viewmodel.parallelApiEnabled,
                onChanged: tokens.any((entry) => entry.enabled)
                    ? viewmodel.setParallelApiEnabled
                    : null,
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.info_outline),
                title: Text(
                  tr(
                    'api_tokens_limit_note',
                    namedArgs: {
                      'count': viewmodel.enabledTokenCount.toString(),
                    },
                  ),
                ),
                subtitle: Text(tr('api_tokens_priority_note')),
              ),
              const Divider(height: 1),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: tokens.length,
                  onReorderItem: viewmodel.reorderToken,
                  itemBuilder: (context, index) {
                    final entry = tokens[index];
                    return ListTile(
                      key: ValueKey(entry.token),
                      leading: Icon(
                        entry.enabled ? Icons.key : Icons.key_off_outlined,
                      ),
                      title: Row(
                        children: [
                          Flexible(child: Text(entry.label)),
                          if (entry.isPrimary) ...[
                            const SizedBox(width: 8),
                            Chip(
                              visualDensity: VisualDensity.compact,
                              label: Text(tr('api_token_primary_badge')),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        '${entry.maskedToken} · ${_balanceText(entry.token)}',
                      ),
                      onTap: () => _showRenameDialog(context, index),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: tr('anlas_balance_refresh'),
                            onPressed: viewmodel.isBalanceLoading(entry.token)
                                ? null
                                : () => viewmodel.refreshBalance(entry.token),
                            icon: const Icon(Icons.refresh),
                          ),
                          Switch(
                            value: entry.enabled,
                            onChanged: (value) =>
                                viewmodel.setTokenEnabled(index, value),
                          ),
                          if (!entry.isPrimary)
                            IconButton(
                              tooltip: tr('delete'),
                              onPressed: () => _confirmDelete(context, index),
                              icon: const Icon(Icons.delete_outline),
                            )
                          else
                            Tooltip(
                              message: tr('api_token_primary_delete_hint'),
                              child: const Padding(
                                padding: EdgeInsets.all(12),
                                child: Icon(Icons.lock_outline),
                              ),
                            ),
                          const Icon(Icons.drag_handle),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _balanceText(String token) {
    if (viewmodel.isBalanceLoading(token)) {
      return tr('anlas_balance_loading');
    }
    if (!viewmodel.balances.containsKey(token)) {
      return tr('anlas_balance_unknown');
    }
    final balance = viewmodel.balances[token];
    if (balance == null) return tr('anlas_balance_failed');
    return tr('anlas_balance', namedArgs: {'balance': balance.toString()});
  }

  void _showAddTokenDialog(BuildContext context) {
    final labelController = TextEditingController();
    final tokenController = TextEditingController();
    var obscure = true;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(tr('api_token_add')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('token-manager-add-label'),
                controller: labelController,
                decoration: InputDecoration(
                  labelText: tr('api_token_label'),
                ),
              ),
              TextField(
                key: const Key('token-manager-add-token'),
                controller: tokenController,
                obscureText: obscure,
                decoration: InputDecoration(
                  labelText: tr('api_token_value'),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setDialogState(() => obscure = !obscure),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(tr('cancel')),
            ),
            TextButton(
              key: const Key('token-manager-add-confirm'),
              onPressed: () {
                viewmodel.addToken(
                  labelController.text,
                  tokenController.text,
                );
                Navigator.of(dialogContext).pop();
              },
              child: Text(tr('confirm')),
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, int index) {
    final controller =
        TextEditingController(text: viewmodel.tokens[index].label);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('api_token_label')),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('cancel')),
          ),
          TextButton(
            onPressed: () {
              viewmodel.renameToken(index, controller.text);
              Navigator.of(dialogContext).pop();
            },
            child: Text(tr('confirm')),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, int index) {
    final label = viewmodel.tokens[index].label;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('api_token_delete_confirm', namedArgs: {
          'label': label,
        })),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('cancel')),
          ),
          TextButton(
            onPressed: () {
              viewmodel.removeTokenAt(index);
              Navigator.of(dialogContext).pop();
            },
            child: Text(tr('confirm')),
          ),
        ],
      ),
    );
  }
}
