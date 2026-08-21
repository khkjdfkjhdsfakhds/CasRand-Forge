import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/settings.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/ui/settings_page/widgets/navigation_directory.dart';
import 'package:nai_casrand/ui/settings_page/view_models/settings_page_viewmodel.dart';
import 'package:nai_casrand/ui/core/widgets/editable_list_tile.dart';
import 'package:nai_casrand/ui/settings_page/widgets/config_selection_page_view.dart';
import 'package:nai_casrand/ui/settings_page/widgets/token_manager_page_view.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/defaults.dart';

enum _RestoreInitialSettingsAction {
  backupAndRestore,
  restoreDirectly,
}

class SettingsPageView extends StatefulWidget {
  final SettingsPageViewmodel viewmodel;

  SettingsPageView({
    super.key,
    SettingsPageViewmodel? viewmodel,
  }) : viewmodel = viewmodel ?? SettingsPageViewmodel();

  @override
  State<SettingsPageView> createState() => _SettingsPageViewState();
}

class _SettingsPageViewState extends State<SettingsPageView> {
  NavigationRequest? _navigationRequest;
  bool _apiProxyDialogOpen = false;
  late final ScrollController _scrollController;
  final Map<AppDestination, GlobalKey> _navigationDestinationKeys = {
    for (final destination in AppDestination.values) destination: GlobalKey(),
  };

  SettingsPageViewmodel get viewmodel => widget.viewmodel;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: viewmodel.navigationDirectoryScrollOffset,
    )..addListener(_rememberScrollOffset);
    if (GetIt.I.isRegistered<NavigationRequest>()) {
      _navigationRequest = GetIt.I<NavigationRequest>();
      _navigationRequest!.apiProxySettingsRevision
          .addListener(_handleApiProxySettingsRequest);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleApiProxySettingsRequest();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealNavigationDirectoryAnchor();
    });
  }

  @override
  void dispose() {
    _navigationRequest?.apiProxySettingsRevision
        .removeListener(_handleApiProxySettingsRequest);
    _scrollController
      ..removeListener(_rememberScrollOffset)
      ..dispose();
    super.dispose();
  }

  void _rememberScrollOffset() {
    if (!_scrollController.hasClients) return;
    viewmodel.navigationDirectoryScrollOffset = _scrollController.offset;
  }

  void _revealNavigationDirectoryAnchor() {
    if (!mounted) return;
    final destination = viewmodel.navigationDirectoryAnchor;
    viewmodel.navigationDirectoryAnchor = null;
    final anchorContext = destination == null
        ? null
        : _navigationDestinationKeys[destination]?.currentContext;
    if (anchorContext == null) return;
    Scrollable.ensureVisible(
      anchorContext,
      duration: Duration.zero,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
  }

  void _openNavigationDestination(AppDestination destination) {
    _rememberScrollOffset();
    viewmodel.openNavigationDestination(destination);
  }

  void _handleApiProxySettingsRequest() {
    if (!mounted || _apiProxyDialogOpen) return;
    if (!(_navigationRequest?.takeOpenApiProxySettingsRequest() ?? false)) {
      return;
    }
    _showApiProxySettingsDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    final content = ChangeNotifierProvider.value(
      value: viewmodel,
      child: Consumer<SettingsPageViewmodel>(
        builder: (context, viewmodel, child) => Column(
          children: [
            _buildApiProxySettingsTile(context),
            _buildEraseMetadataTile(context),
            if (viewmodel.supportsDesktopJpegStorage())
              _buildOutputSelectionTile(),
            if (viewmodel.supportsDesktopJpegStorage())
              _buildJpegStorageTiles(),
            _buildPrefixKeyTile(),
            _buildRememberSequentialProgressTile(),
            _buildPromptModeConfirmationTile(),
            _buildPromptAutocompleteTile(),
            const Divider(),
            NavigationDirectory(
              configuration: viewmodel.settings.navigation,
              destinationKeys: _navigationDestinationKeys,
              onOpenDestination: _openNavigationDestination,
              onEnabledChanged: (change) =>
                  viewmodel.setNavigationDestinationEnabled(
                change.destination,
                change.enabled,
              ),
              onReorder: viewmodel.reorderNavigationDestination,
            ),
            const Divider(),
            _buildSavedConfigTile(context),
            _buildRestoreInitialSettingsTile(context),
            _buildThemeModeTile(context),
            _buildLanguageTile(context),
          ],
        ),
      ),
    );

    final buttons = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        FloatingActionButton(
          onPressed: () => viewmodel.loadJsonConfig(context),
          tooltip: tr('import_settings_from_file'),
          heroTag: 'settings_import_fab',
          child: const Icon(Icons.file_open),
        ),
        const SizedBox(height: 20),
        FloatingActionButton(
          onPressed: () => viewmodel.saveJsonConfig(),
          tooltip: tr('export_settings_to_file'),
          heroTag: 'settings_export_fab',
          child: const Icon(Icons.save),
        ),
      ],
    );

    return Scaffold(
      body: SingleChildScrollView(
        key: const Key('settings-scroll-view'),
        controller: _scrollController,
        child: content,
      ),
      floatingActionButton: buttons,
    );
  }

  Widget _buildApiProxySettingsTile(BuildContext context) {
    final tokenCount = viewmodel.settings.apiTokens.length;
    return ListTile(
      key: const Key('api-proxy-settings-tile'),
      leading: const Icon(Icons.vpn_key_outlined),
      title: Text(tr('api_proxy_settings')),
      subtitle: Text(
        tokenCount == 0
            ? tr('api_proxy_settings_summary')
            : tr('api_proxy_settings_summary_with_optional', namedArgs: {
                'count': tokenCount.toString(),
              }),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showApiProxySettingsDialog(context),
    );
  }

  Future<void> _showApiProxySettingsDialog(BuildContext context) async {
    if (_apiProxyDialogOpen) return;
    _apiProxyDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => _ApiProxySettingsDialog(viewmodel: viewmodel),
      );
      viewmodel.refresh();
    } finally {
      _apiProxyDialogOpen = false;
      _handleApiProxySettingsRequest();
    }
  }

  Widget _buildRememberSequentialProgressTile() {
    return SwitchListTile(
      key: const Key('remember-sequential-progress'),
      secondary: const Icon(Icons.history),
      title: Text(tr('remember_sequential_progress')),
      subtitle: Text(tr('remember_sequential_progress_hint')),
      value: viewmodel.settings.rememberSequentialProgress,
      onChanged: viewmodel.setRememberSequentialProgress,
    );
  }

  Widget _buildPromptModeConfirmationTile() {
    return SwitchListTile(
      key: const Key('confirm-prompt-mode-switch'),
      secondary: const Icon(Icons.swap_horiz),
      title: Text(tr('confirm_prompt_mode_switch')),
      subtitle: Text(tr('confirm_prompt_mode_switch_hint')),
      value: viewmodel.settings.confirmPromptModeSwitch,
      onChanged: viewmodel.setConfirmPromptModeSwitch,
    );
  }

  Widget _buildPromptAutocompleteTile() {
    return SwitchListTile(
      key: const Key('prompt-autocomplete-enabled'),
      secondary: const Icon(Icons.auto_awesome),
      title: Text(tr('prompt_autocomplete_enabled')),
      subtitle: Text(tr('prompt_autocomplete_enabled_hint')),
      value: viewmodel.settings.promptAutocompleteEnabled,
      onChanged: viewmodel.setPromptAutocompleteEnabled,
    );
  }

  Widget _buildEraseMetadataTile(BuildContext context) {
    List<Widget> tiles = [
      SwitchListTile(
          key: const Key('metadata-erase-enabled'),
          secondary: const Icon(Icons.delete_sweep),
          title: Text(tr('metadata_erase_enabled')),
          value: viewmodel.settings.metadataEraseEnabled,
          onChanged: (value) => viewmodel.setEraseMetadataEnabled(value))
    ];
    if (viewmodel.settings.metadataEraseEnabled) {
      tiles.add(Padding(
          padding: const EdgeInsets.only(left: 20),
          child: SwitchListTile(
              key: const Key('custom-metadata-enabled'),
              secondary: const Icon(Icons.edit_note),
              title: Text(tr('custom_metadata_enabled')),
              value: viewmodel.settings.customMetadataEnabled,
              onChanged: (value) =>
                  viewmodel.setCustomMetadataEnabled(value))));
    }
    if (viewmodel.settings.metadataEraseEnabled &&
        viewmodel.settings.customMetadataEnabled) {
      tiles.add(Padding(
          padding: const EdgeInsets.only(left: 30),
          child: ListTile(
            title: Text(tr('custom_metadata_content')),
            subtitle: Text(
              viewmodel.settings.customMetadataContent,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _showEditCustomMetadataDialog(context),
          )));
    }
    return Column(
      children: tiles,
    );
  }

  Widget _buildOutputSelectionTile() {
    if (kIsWeb || Platform.isAndroid) return const SizedBox.shrink();
    final outputDirPath = viewmodel.settings.outputFolderPath == ''
        ? '<${tr('system_document_folder')}>${Platform.pathSeparator}'
            'nai-generated'
        : viewmodel.settings.outputFolderPath;
    return ListTile(
      key: const Key('output-folder'),
      leading: const Icon(Icons.folder_outlined),
      title: Text(tr('output_folder')),
      subtitle: Text(outputDirPath),
      onTap: () => viewmodel.pickOutputFolderPath(),
    );
  }

  Widget _buildJpegStorageTiles() {
    return Column(
      children: [
        SwitchListTile(
          key: const Key('jpeg-storage-enabled'),
          secondary: const Icon(Icons.photo_library_outlined),
          title: Text(tr('jpeg_storage_enabled')),
          subtitle: Text(tr('jpeg_storage_enabled_hint')),
          value: viewmodel.settings.jpegStorageEnabled,
          onChanged: (value) {
            viewmodel.setJpegStorageEnabled(value);
          },
        ),
        if (viewmodel.settings.jpegStorageEnabled)
          SwitchListTile(
            key: const Key('retain-original-png'),
            secondary: const Icon(Icons.archive_outlined),
            title: Text(tr('retain_original_png')),
            subtitle: Text(tr('retain_original_png_hint')),
            value: viewmodel.settings.retainOriginalPng,
            onChanged: viewmodel.setRetainOriginalPng,
          ),
      ],
    );
  }

  void _showEditCustomMetadataDialog(context) {
    final controller =
        TextEditingController(text: viewmodel.settings.customMetadataContent);
    submit() {
      viewmodel.setCustomMetadataContent(controller.text);
      Navigator.of(context).pop();
    }

    showDialog(
        context: context,
        builder: (context) => StatefulBuilder(
              builder: (context, setState) => AlertDialog(
                title: Text(
                    tr('edit') + tr('colon') + tr('custom_metadata_content')),
                content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(tr('edit_custom_metadata_content_hint')),
                      TextField(
                        maxLines: null,
                        autofocus: true,
                        controller: controller,
                        onSubmitted: (_) => submit(),
                      )
                    ]),
                actions: [
                  Row(
                    children: [
                      TextButton(
                          onPressed: () => setState(
                              () => controller.text = defaultWatermarkContent),
                          child: const Text('👻')),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(tr('cancel')),
                      ),
                      TextButton(
                        onPressed: () => submit(),
                        child: Text(tr('confirm')),
                      )
                    ],
                  ),
                ],
              ),
            ));
  }

  Widget _buildPrefixKeyTile() {
    final shownPrefix = viewmodel.settings.fileNamePrefixKey.isNotEmpty
        ? viewmodel.settings.fileNamePrefixKey
        : 'nai-generated';
    return EditableListTile(
      key: const Key('output-file-name-prefix'),
      leading: const Icon(Icons.description),
      title: tr('output_file_name_prefix'),
      notice: tr('output_file_name_prefix_hint'),
      editValue: viewmodel.settings.fileNamePrefixKey,
      currentValue: shownPrefix,
      confirmOnSubmit: true,
      onEditComplete: (value) => viewmodel.setFileNamePrefixKey(value),
    );
  }

  Widget _buildThemeModeTile(BuildContext context) {
    return SelectableListTile(
      title: tr('theme_mode'),
      leading: const Icon(Icons.dark_mode_outlined),
      currentValue: viewmodel.payloadConfig.settings.themeMode,
      options: themeModeStrings,
      onSelectComplete: (value) => viewmodel.setThemeMode(value, context),
    );
  }

  Widget _buildLanguageTile(BuildContext context) {
    return ListTile(
      title: const Text('Language'),
      leading: const Icon(Icons.translate),
      subtitle: Text(context.locale.toLanguageTag()),
      onTap: () => _showLanguageSelectionDialog(context),
    );
  }

  void _showLanguageSelectionDialog(BuildContext context) {
    final locales = context.supportedLocales;
    String getLocaleName(Locale locale) {
      if (locale.countryCode == null) {
        return locale.languageCode;
      } else {
        return '${locale.languageCode}-${locale.countryCode}';
      }
    }

    showDialog(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Select language...'),
                content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: locales
                        .map((l) => ListTile(
                              title: Text(getLocaleName(l)),
                              onTap: () {
                                Navigator.of(context).pop();
                                context.setLocale(l);
                              },
                            ))
                        .toList()),
                actions: [
                  TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                      child: Text(context.tr('confirm')))
                ]));
  }

  Widget _buildSavedConfigTile(BuildContext context) {
    return ListTile(
      title: Text(tr('saved_config')),
      leading: const Icon(Icons.save_outlined),
      onTap: () {
        viewmodel.saveCurrentConfig();
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) => ConfigSelectionPageView(
                      notificationCallback: () => viewmodel.notify(),
                    )));
      },
    );
  }

  Widget _buildRestoreInitialSettingsTile(BuildContext context) {
    return ListTile(
      key: const Key('restore-initial-settings-tile'),
      title: Text(tr('restore_initial_settings')),
      subtitle: Text(tr('restore_initial_settings_hint')),
      leading: const Icon(Icons.restart_alt),
      onTap: () => _showRestoreInitialSettingsDialog(context),
    );
  }

  Future<void> _showRestoreInitialSettingsDialog(BuildContext context) async {
    final action = await showDialog<_RestoreInitialSettingsAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('restore_initial_settings')),
        content: Text(tr('restore_initial_settings_warning')),
        actions: [
          TextButton(
            key: const Key('restore-initial-settings-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('cancel')),
          ),
          TextButton(
            key: const Key('restore-initial-settings-backup'),
            onPressed: () => Navigator.of(dialogContext).pop(
              _RestoreInitialSettingsAction.backupAndRestore,
            ),
            child: Text(tr('backup_and_restore')),
          ),
          TextButton(
            key: const Key('restore-initial-settings-direct'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(
              _RestoreInitialSettingsAction.restoreDirectly,
            ),
            child: Text(tr('restore_directly')),
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;
    await viewmodel.restoreInitialSettings(
      context,
      backupCurrent: action == _RestoreInitialSettingsAction.backupAndRestore,
    );
  }
}

class _ApiProxySettingsDialog extends StatefulWidget {
  final SettingsPageViewmodel viewmodel;

  const _ApiProxySettingsDialog({required this.viewmodel});

  @override
  State<_ApiProxySettingsDialog> createState() =>
      _ApiProxySettingsDialogState();
}

class _ApiProxySettingsDialogState extends State<_ApiProxySettingsDialog> {
  late final TextEditingController _apiController;
  late final TextEditingController _proxyController;
  bool _obscureToken = true;
  bool _detecting = false;
  String? _detectionMessage;
  bool _detectionSucceeded = false;

  bool get _desktopDetection =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  void initState() {
    super.initState();
    _apiController =
        TextEditingController(text: widget.viewmodel.settings.apiKey);
    _proxyController =
        TextEditingController(text: widget.viewmodel.settings.proxy);
  }

  @override
  void dispose() {
    _apiController.dispose();
    _proxyController.dispose();
    super.dispose();
  }

  void _saveSettings() {
    widget.viewmodel.setApiKey(_apiController.text);
    widget.viewmodel.setProxy(_proxyController.text.trim());
  }

  Future<void> _openTokenManager() async {
    _saveSettings();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TokenManagerPageView()),
    );
    if (!mounted) return;
    widget.viewmodel.refresh();
    setState(() {});
  }

  Future<void> _detectProxy() async {
    setState(() {
      _detecting = true;
      _detectionMessage = tr('proxy_detecting');
      _detectionSucceeded = false;
    });
    final found = await widget.viewmodel.detectProxy();
    if (!mounted) return;
    setState(() {
      _detecting = false;
      if (found == null) {
        _detectionMessage = tr('proxy_detect_not_found');
        _detectionSucceeded = false;
      } else {
        _proxyController.text = found;
        _detectionMessage = tr(
          'proxy_detect_found',
          namedArgs: {'proxy': found},
        );
        _detectionSucceeded = true;
      }
    });
  }

  void _submit() {
    _saveSettings();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.viewmodel.settings.apiTokens;
    final enabledCount = tokens.where((entry) => entry.enabled).length;
    return AlertDialog(
      title: Text(tr('api_proxy_settings')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('api-token-input'),
                controller: _apiController,
                obscureText: _obscureToken,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr('api_token_required'),
                  helperText: tr('NAI_API_key_hint'),
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: tr(
                      _obscureToken ? 'show_api_token' : 'hide_api_token',
                    ),
                    onPressed: () => setState(
                      () => _obscureToken = !_obscureToken,
                    ),
                    icon: Icon(
                      _obscureToken ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ),
                onSubmitted: (_) {
                  _submit();
                },
              ),
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  key: const Key('api-tokens-optional-tile'),
                  leading: const Icon(Icons.key_outlined),
                  title: Text(tr('api_tokens_optional')),
                  subtitle: Text(
                    tokens.isEmpty
                        ? tr('api_tokens_optional_hint')
                        : tr('api_tokens_optional_summary', namedArgs: {
                            'count': tokens.length.toString(),
                            'enabled': enabledCount.toString(),
                          }),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openTokenManager,
                ),
              ),
              if (!kIsWeb) ...[
                const SizedBox(height: 20),
                Text(
                  tr('proxy_settings'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(tr(_desktopDetection
                    ? 'proxy_settings_notice_desktop'
                    : 'proxy_settings_notice_mobile')),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('proxy-settings-input'),
                        controller: _proxyController,
                        decoration: const InputDecoration(
                          hintText: '127.0.0.1:7890',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                    if (_desktopDetection) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 56,
                        child: OutlinedButton.icon(
                          key: const Key('proxy-detect-button'),
                          onPressed: _detecting ? null : _detectProxy,
                          icon: _detecting
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.radar),
                          label: Text(tr('proxy_detect')),
                        ),
                      ),
                    ],
                  ],
                ),
                if (_detectionMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _detectionMessage!,
                    key: const Key('proxy-detection-result'),
                    style: TextStyle(
                      color: _detectionSucceeded
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('cancel')),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(tr('confirm')),
        ),
      ],
    );
  }
}
