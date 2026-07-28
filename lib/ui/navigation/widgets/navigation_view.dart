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
import 'package:nai_casrand/ui/navigation/widgets/compact_navigation_rail_label.dart';
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
  AppDestination _currentDestination = AppDestination.generation;

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

  List<AppDestination> get _visibleDestinations {
    final settings = GetIt.I<PayloadConfig>().settings;
    return [
      AppDestination.generation,
      AppDestination.config,
      if (settings.showImageToImagePage) AppDestination.imageToImage,
      if (settings.showVibeReferencePage) AppDestination.vibeReference,
      if (settings.showEnhancePage) AppDestination.enhance,
      if (settings.showDirectorToolsPage) AppDestination.directorTools,
      AppDestination.settings,
    ];
  }

  void _changeDestination(AppDestination destination) {
    widget.viewModel.changeIndex(destination.index);
    setState(() {
      _currentDestination = destination;
    });
  }

  void _changeIndex(int visibleIndex) {
    final visible = _visibleDestinations;
    if (visibleIndex < 0 || visibleIndex >= visible.length) return;
    _changeDestination(visible[visibleIndex]);
  }

  bool _isDestinationVisible(AppDestination destination) =>
      _visibleDestinations.contains(destination);

  /// A direct result action is an explicit request to use a workspace. If the
  /// user previously hid that destination from navigation, reveal it again
  /// instead of making the action appear broken.
  void _ensureDestinationVisible(AppDestination destination) {
    final settings = GetIt.I<PayloadConfig>().settings;
    var changed = false;
    switch (destination) {
      case AppDestination.imageToImage:
        changed = !settings.showImageToImagePage;
        settings.showImageToImagePage = true;
        break;
      case AppDestination.vibeReference:
        changed = !settings.showVibeReferencePage;
        settings.showVibeReferencePage = true;
        break;
      case AppDestination.enhance:
        changed = !settings.showEnhancePage;
        settings.showEnhancePage = true;
        break;
      case AppDestination.directorTools:
        changed = !settings.showDirectorToolsPage;
        settings.showDirectorToolsPage = true;
        break;
      case AppDestination.generation:
      case AppDestination.config:
      case AppDestination.settings:
        return;
    }
    if (!changed) return;
    GetIt.I<ConfigService>().saveConfig(GetIt.I<PayloadConfig>().toJson());
  }

  /// Handles a jump asked for by another page (e.g. "use as base image").
  void _handleNavigationRequest() {
    final destination = _navigationRequest.requestedDestination.value;
    if (destination == null) return;
    if (!_isDestinationVisible(destination)) {
      _ensureDestinationVisible(destination);
    }
    _changeDestination(destination);
    _navigationRequest.consume();
  }

  void _handleVisibilityChange() {
    if (!mounted) return;
    setState(() {
      if (!_visibleDestinations.contains(_currentDestination)) {
        _currentDestination = AppDestination.generation;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _navigationRequest.requestedDestination
        .addListener(_handleNavigationRequest);
    _navigationRequest.visibilityRevision.addListener(_handleVisibilityChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showWelcomeDialog();
    });
  }

  @override
  void dispose() {
    _navigationRequest.requestedDestination
        .removeListener(_handleNavigationRequest);
    _navigationRequest.visibilityRevision
        .removeListener(_handleVisibilityChange);
    super.dispose();
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
    _changeDestination(AppDestination.generation);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showWelcomeDialog();
    });
  }

  Widget getBody() {
    final destinations = _visibleDestinations;
    final selectedIndex = destinations.indexOf(_currentDestination);
    final selectedDestination =
        selectedIndex < 0 ? AppDestination.generation : _currentDestination;
    final content = LayoutBuilder(
      builder: (context, constraints) {
        // 使用 LayoutBuilder 来监听父容器的宽度变化
        bool isHorizontal = constraints.maxWidth >= 640;
        if (isHorizontal) {
          // 横向布局 (Row - NavigationRail)
          return Row(
            children: [
              NavigationRail(
                selectedIndex: destinations.indexOf(selectedDestination),
                onDestinationSelected: _changeIndex,
                labelType: NavigationRailLabelType.all,
                groupAlignment: -1.0,
                destinations: destinations
                    .map(
                      (destination) => NavigationRailDestination(
                        icon: Icon(_iconFor(destination)),
                        label: CompactNavigationRailLabel(
                          label: context.tr(_labelKeyFor(destination)),
                        ),
                      ),
                    )
                    .toList(),
              ),
              Expanded(child: _pages[selectedDestination]!), // 内容区域
            ],
          );
        } else {
          // 纵向布局 (Column - BottomNavigationBar)
          return Column(
            children: [
              Expanded(child: _pages[selectedDestination]!), // 内容区域
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: constraints.maxWidth > destinations.length * 88.0
                      ? constraints.maxWidth
                      : destinations.length * 88.0,
                  child: NavigationBar(
                    selectedIndex: destinations.indexOf(selectedDestination),
                    labelBehavior:
                        NavigationDestinationLabelBehavior.onlyShowSelected,
                    destinations: destinations
                        .map(
                          (destination) => NavigationDestination(
                            icon: Icon(_iconFor(destination)),
                            label: context.tr(_labelKeyFor(destination)),
                          ),
                        )
                        .toList(),
                    onDestinationSelected: _changeIndex,
                  ),
                ),
              )
            ],
          );
        }
      },
    );
    return Center(child: content);
  }

  String _labelKeyFor(AppDestination destination) {
    return switch (destination) {
      AppDestination.generation => 'generation',
      AppDestination.config => 'prompt_config',
      AppDestination.imageToImage => 'i2i_inpaint',
      AppDestination.vibeReference => 'vibe_transfer',
      AppDestination.enhance => 'enhance_section',
      AppDestination.directorTools => 'director_tool',
      AppDestination.settings => 'settings',
    };
  }

  IconData _iconFor(AppDestination destination) {
    return switch (destination) {
      AppDestination.generation => Icons.create,
      AppDestination.config => Icons.visibility,
      AppDestination.imageToImage => Icons.brush,
      AppDestination.vibeReference => Icons.auto_awesome_motion_outlined,
      AppDestination.enhance => Icons.auto_awesome,
      AppDestination.directorTools => Icons.auto_fix_high,
      AppDestination.settings => Icons.settings,
    };
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
