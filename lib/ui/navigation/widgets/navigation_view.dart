import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/app_identity.dart';
import 'package:nai_casrand/ui/config_page/widgets/config_page_view.dart';
import 'package:nai_casrand/ui/config_page/view_models/config_page_viewmodel.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_page_view.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/ui/director_page/view_models/director_page_viewmodel.dart';
import 'package:nai_casrand/ui/director_page/widgets/director_page_view.dart';
import 'package:nai_casrand/ui/enhance_page/view_models/enhance_page_viewmodel.dart';
import 'package:nai_casrand/ui/enhance_page/widgets/enhance_page_view.dart';
import 'package:nai_casrand/ui/i2i_page/view_models/i2i_page_viewmodel.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/i2i_page_view.dart';
import 'package:nai_casrand/ui/i2i_tab/widgets/vibe_reference_page_view.dart';
import 'package:nai_casrand/ui/navigation/view_models/navigation_view_model.dart';
import 'package:nai_casrand/ui/navigation/widgets/application_navigation_shell.dart';
import 'package:nai_casrand/ui/navigation/widgets/metadata_drop_area.dart';
import 'package:nai_casrand/ui/navigation/widgets/navigation_appbar.dart';
import 'package:nai_casrand/ui/settings_page/widgets/settings_page_view.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/models/payload_config.dart';
import '../../../data/services/account_service.dart';
import '../../../data/services/config_service.dart';
import '../../../data/services/generated_image_storage.dart';

class NavigationView extends StatefulWidget {
  final NavigationViewModel viewModel;

  const NavigationView({super.key, required this.viewModel});

  @override
  State<StatefulWidget> createState() => NavigationViewState();
}

class NavigationViewState extends State<NavigationView>
    with WidgetsBindingObserver {
  DateTime? _lastBackButtonPressTime;
  bool _exitInProgress = false;
  final GlobalKey<ApplicationNavigationShellState> _navigationShellKey =
      GlobalKey();

  /// Pages are created once and reused across rebuilds, so their viewmodels
  /// stay alive: async work (image imports, cost estimates) must notify the
  /// same instance the page is listening to.
  late final Map<AppDestination, Widget> _pages = {
    AppDestination.generation: GenerationPageView(viewmodel: GetIt.I()),
    AppDestination.config: ConfigPageView(
      viewmodel: ConfigPageViewmodel(),
    ),
    AppDestination.imageToImage: I2iPageView(viewmodel: I2iPageViewmodel()),
    AppDestination.vibeReference: const VibeReferencePageView(),
    AppDestination.enhance: EnhancePageView(viewmodel: EnhancePageViewmodel()),
    AppDestination.directorTools:
        DirectorPageView(viewmodel: DirectorPageViewmodel()),
    AppDestination.settings: SettingsPageView(),
  };

  NavigationRequest get _navigationRequest => GetIt.I<NavigationRequest>();

  void _saveNavigationConfiguration() {
    final config = GetIt.I<PayloadConfig>();
    GetIt.I<ConfigService>().saveConfig(config.toJson());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showWelcomeDialog();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    return await _prepareGeneratedImageStorageForExit()
        ? AppExitResponse.exit
        : AppExitResponse.cancel;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (_navigationShellKey.currentState?.returnToSettingsIfTransient() ??
              false) {
            _lastBackButtonPressTime = null;
            return;
          }
          // 使用 onPopInvoked 回调
          final now = DateTime.now();
          final timeDiff = _lastBackButtonPressTime == null
              ? null
              : now.difference(_lastBackButtonPressTime!);
          if (timeDiff == null || timeDiff > const Duration(seconds: 2)) {
            _lastBackButtonPressTime = now;
            showInfoBar(context, tr('press_again_to_exit')); // 提示用户双击退出
            return; // 阻止默认的 pop 行为
          } else {
            unawaited(_exitAfterStorageIsReady());
          }
        },
        child: MetadataDropArea(
          childBuilder: (context) => getBody(),
        ));
  }

  Future<void> _exitAfterStorageIsReady() async {
    if (await _prepareGeneratedImageStorageForExit()) {
      await SystemNavigator.pop();
    }
  }

  Future<bool> _prepareGeneratedImageStorageForExit() async {
    if (_exitInProgress || !mounted) return false;
    _exitInProgress = true;
    try {
      if (GetIt.I.isRegistered<ConfigService>()) {
        final configs = GetIt.I<ConfigService>();
        // Flush only drains previously accepted writes; prompt edits may still
        // exist only in memory until a page change. Accept the exit snapshot
        // before draining so a successful exit always includes the latest edit.
        try {
          await configs.saveConfig(GetIt.I<PayloadConfig>().toJson());
        } finally {
          // Also consume a queued persistence failure before a user retries.
          await configs.flush();
        }
      }
      if (!mounted) return false;
      if (!GetIt.I.isRegistered<GeneratedImageStorageService>()) return true;
      final storage = GetIt.I<GeneratedImageStorageService>();
      var abandon = false;
      if (storage.hasPendingWork) {
        final choice = await showDialog<_StorageExitChoice>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text(tr('jpeg_storage_exit_title')),
            content: Text(tr('jpeg_storage_exit_message')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _StorageExitChoice.cancel,
                ),
                child: Text(tr('cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _StorageExitChoice.abandon,
                ),
                child: Text(tr('jpeg_storage_exit_abandon')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _StorageExitChoice.wait,
                ),
                child: Text(tr('jpeg_storage_exit_wait')),
              ),
            ],
          ),
        );
        if (choice == null || choice == _StorageExitChoice.cancel) return false;
        abandon = choice == _StorageExitChoice.abandon;
      }

      final closeFuture = storage.close(abandon: abandon);
      if (storage.hasPendingWork && mounted) {
        unawaited(showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: Text(tr('jpeg_storage_exit_finishing')),
              content: const Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Expanded(child: LinearProgressIndicator()),
                ],
              ),
            ),
          ),
        ));
      }
      await closeFuture;
      AccountService.shared.invalidate();
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      return true;
    } catch (error) {
      if (mounted) showErrorBar(context, '$error');
      return false;
    } finally {
      _exitInProgress = false;
    }
  }

  void _restoreWelcomeMessage() {
    if (!mounted) return;
    final config = GetIt.I<PayloadConfig>();
    config.settings.welcomeMessageVersion = '';
    GetIt.I<ConfigService>().saveConfig(config.toJson());
    _navigationRequest.goTo(AppDestination.generation);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showWelcomeDialog();
    });
  }

  Widget getBody() {
    final settings = GetIt.I<PayloadConfig>().settings;
    return ApplicationNavigationShell(
      key: _navigationShellKey,
      configuration: settings.navigation,
      navigationRequest: _navigationRequest,
      pages: _pages,
      onDestinationOpened: (destination) {
        widget.viewModel.changeIndex(destination.index);
      },
      onConfigurationChanged: _saveNavigationConfiguration,
      appBar: NavigationAppBar(
        onRestoreWelcomeMessage: _restoreWelcomeMessage,
      ),
    );
  }

  void _showWelcomeDialog() {
    final dontShowAgainVersion =
        GetIt.I<PayloadConfig>().settings.welcomeMessageVersion;
    final packageInfo = GetIt.instance<ConfigService>().packageInfo;
    final appVersion = packageInfo.version;
    if (appVersion == dontShowAgainVersion) return;
    showDialog(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(
              '${tr('welcome_message_title')} - '
              '$appDisplayName $appVersion',
            ),
            content: MarkdownBody(
              data: tr(
                'welcome_message_markdown',
                namedArgs: {'appName': appDisplayName},
              ),
              onTapLink: (text, href, title) {
                if (href == null) return;
                if (href == '#jump_to_api_proxy_settings') {
                  Navigator.of(dialogContext).pop();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _navigationRequest.goToApiProxySettings();
                  });
                } else {
                  // Launch link
                  launchUrl(Uri.parse(href));
                }
              },
            ),
            actions: [
              TextButton(
                  onPressed: () {
                    GetIt.I<PayloadConfig>().settings.welcomeMessageVersion =
                        appVersion;
                    // Save the config
                    final config = GetIt.instance<PayloadConfig>();
                    final service = GetIt.instance<ConfigService>();
                    service.saveConfig(config.toJson());
                    Navigator.of(dialogContext).pop();
                  },
                  child: Text(tr('dont_show_again'))),
              TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(tr('confirm')))
            ],
          );
        });
  }
}

enum _StorageExitChoice { cancel, wait, abandon }
