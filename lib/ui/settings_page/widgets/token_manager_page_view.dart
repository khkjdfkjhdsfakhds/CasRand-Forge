import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/settings_page/view_models/token_manager_viewmodel.dart';

/// Management page for multiple NovelAI API tokens (concurrent generation).
class TokenManagerPageView extends StatefulWidget {
  final TokenManagerViewmodel? viewmodel;

  const TokenManagerPageView({super.key, this.viewmodel});

  @override
  State<TokenManagerPageView> createState() => _TokenManagerPageViewState();
}

class _TokenManagerPageViewState extends State<TokenManagerPageView> {
  late final TokenManagerViewmodel viewmodel;
  late final bool _ownsViewmodel;

  @override
  void initState() {
    super.initState();
    _ownsViewmodel = widget.viewmodel == null;
    viewmodel = widget.viewmodel ?? TokenManagerViewmodel();
    viewmodel.refreshAllBalances();
  }

  @override
  void dispose() {
    if (_ownsViewmodel) viewmodel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('api_tokens_manage')),
        actions: [
          ListenableBuilder(
            listenable: viewmodel,
            builder: (context, _) => IconButton(
              tooltip: tr('anlas_balance_refresh'),
              onPressed:
                  viewmodel.isRefreshing ? null : viewmodel.refreshAllBalances,
              icon: const Icon(Icons.refresh),
            ),
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
                    return LayoutBuilder(
                      key: ValueKey(entry.token),
                      builder: (context, constraints) {
                        final compact = constraints.maxWidth < 480;
                        final actions = _buildTokenActions(
                          context,
                          index,
                          entry.token,
                          entry.enabled,
                          entry.isPrimary,
                        );
                        return ListTile(
                          contentPadding: compact
                              ? const EdgeInsets.symmetric(horizontal: 12)
                              : null,
                          leading: compact
                              ? null
                              : Icon(
                                  entry.enabled
                                      ? Icons.key
                                      : Icons.key_off_outlined,
                                ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  entry.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (entry.isPrimary) ...[
                                const SizedBox(width: 8),
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: compact ? 112 : 160,
                                  ),
                                  child: Chip(
                                    visualDensity: VisualDensity.compact,
                                    label: Text(
                                      tr('api_token_primary_badge'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${entry.maskedToken} · ${_balanceText(entry.token)}',
                              ),
                              Text(_usageText(entry.token)),
                              Text(_expirationText(entry.token)),
                              if (compact)
                                Align(
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: actions,
                                ),
                            ],
                          ),
                          onTap: () => _showRenameDialog(context, index),
                          trailing: compact ? null : actions,
                        );
                      },
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

  Widget _buildTokenActions(
    BuildContext context,
    int index,
    String token,
    bool enabled,
    bool isPrimary,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: tr('anlas_balance_refresh'),
          onPressed: viewmodel.isBalanceLoading(token)
              ? null
              : () => viewmodel.refreshBalance(token),
          icon: const Icon(Icons.refresh),
        ),
        Switch(
          value: enabled,
          onChanged: (value) => viewmodel.setTokenEnabled(index, value),
        ),
        if (!isPrimary)
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

  String _usageText(String token) {
    if (viewmodel.isBalanceLoading(token)) {
      return tr('api_token_subscription_loading');
    }
    if (!viewmodel.hasSubscription(token)) {
      return tr('api_token_usage_unknown');
    }
    final usage = viewmodel.subscriptionFor(token)?.usage;
    if (usage == null) return tr('api_token_usage_unknown');
    final percent = usage.visiblePercent;
    final formatted = percent == percent.roundToDouble()
        ? percent.toStringAsFixed(0)
        : percent.toStringAsFixed(1);
    return tr('api_token_usage_limit', namedArgs: {'percent': formatted});
  }

  String _expirationText(String token) {
    if (viewmodel.isBalanceLoading(token) ||
        !viewmodel.hasSubscription(token)) {
      return tr('api_token_expiration_unknown');
    }
    final expiresAt = viewmodel.subscriptionFor(token)?.expiresAt;
    if (expiresAt == null) return tr('api_token_expiration_unknown');
    final local = expiresAt.toLocal();
    final date = '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return tr('api_token_expiration', namedArgs: {'date': date});
  }

  void _showAddTokenDialog(BuildContext context) {
    final labelController = TextEditingController();
    final tokenController = TextEditingController();
    var obscure = true;
    String? tokenError;
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
                onChanged: (_) {
                  if (tokenError != null) {
                    setDialogState(() => tokenError = null);
                  }
                },
                decoration: InputDecoration(
                  labelText: tr('api_token_value'),
                  errorText: tokenError,
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
                final added = viewmodel.addToken(
                  labelController.text,
                  tokenController.text,
                );
                if (added) {
                  Navigator.of(dialogContext).pop();
                } else {
                  setDialogState(() => tokenError = tr(
                        tokenController.text.trim().isEmpty
                            ? 'api_token_empty_error'
                            : 'api_token_duplicate',
                      ));
                }
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
