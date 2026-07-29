import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get_it/get_it.dart';
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
import '../../../data/services/config_service.dart';

class NavigationView extends StatefulWidget {
  final NavigationViewModel viewModel;

  const NavigationView({super.key, required this.viewModel});

  @override
  State<StatefulWidget> createState() => NavigationViewState();
}

class NavigationViewState extends State<NavigationView> {
  DateTime? _lastBackButtonPressTime;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showWelcomeDialog();
    });
  }

  @override
  Widget build(BuildContext context) {
    final appBar = NavigationAppBar(
      onRestoreWelcomeMessage: _restoreWelcomeMessage,
    );
    final body = Scaffold(
      appBar: appBar,
      body: MetadataDropArea(
        childBuilder: (context) => getBody(),
      ),
    );
    return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
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
            SystemNavigator.pop(); // 双击，退出应用
          }
        },
        child: body);
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
      configuration: settings.navigation,
      navigationRequest: _navigationRequest,
      pages: _pages,
      onDestinationOpened: (destination) {
        widget.viewModel.changeIndex(destination.index);
      },
      onConfigurationChanged: _saveNavigationConfiguration,
    );
  }

  void _showWelcomeDialog() {
    final dontShowAgainVersion =
        GetIt.I<PayloadConfig>().settings.welcomeMessageVersion;
    final packageInfo = GetIt.instance<ConfigService>().packageInfo;
    const appName = 'CasRand Forge';
    final appVersion = packageInfo.version;
    if (appVersion == dontShowAgainVersion) return;
    showDialog(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title:
                Text('${tr('welcome_message_title')} - $appName $appVersion'),
            content: MarkdownBody(
              data: tr('welcome_message_markdown'),
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
