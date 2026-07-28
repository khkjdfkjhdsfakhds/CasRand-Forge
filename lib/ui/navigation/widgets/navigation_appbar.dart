import 'dart:math';

import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:get_it/get_it.dart';
import 'package:blinking_text/blinking_text.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/navigation/widgets/debug_settings_view.dart';
import 'package:url_launcher/url_launcher.dart';

enum AppState { idle, generating, waitingForNextGeneration }

class NavigationAppBar extends StatefulWidget implements PreferredSizeWidget {
  final CommandStatus commandStatus = GetIt.instance();
  final VoidCallback onRestoreWelcomeMessage;

  NavigationAppBar({
    super.key,
    required this.onRestoreWelcomeMessage,
  });

  @override
  NavigationAppBarState createState() => NavigationAppBarState();

  @override
  Size get preferredSize =>
      const Size.fromHeight(kToolbarHeight); // 默认的AppBar高度
}

class NavigationAppBarState extends State<NavigationAppBar>
    with SingleTickerProviderStateMixin {
  late final _iconAnimationController = AnimationController(
    duration: const Duration(seconds: 3), // 控制旋转速度
    vsync: this,
  );
  late final _animation = CurvedAnimation(
    parent: _iconAnimationController,
    curve: Curves.linear,
  );
  AppState _state = AppState.idle;

  @override
  void initState() {
    super.initState();

    // 在生成状态变化时改变样式
    widget.commandStatus.isGenerationActive.addListener(refreshDisplay);
    widget.commandStatus.isWaitingForNextGeneration.addListener(refreshDisplay);
    refreshDisplay(); // 初始化状态
  }

  void refreshDisplay() {
    AppState newState;
    if (widget.commandStatus.isWaitingForNextGeneration.value) {
      newState = AppState.waitingForNextGeneration;
    } else if (widget.commandStatus.isGenerationActive.value) {
      newState = AppState.generating;
    } else {
      newState = AppState.idle;
    }
    setState(() => _state = newState);
  }

  @override
  Widget build(BuildContext context) {
    Widget title;
    switch (_state) {
      case AppState.idle:
        title = Text(
          context.tr('appbar_idle'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
        _iconAnimationController.stop();
        break;
      case AppState.generating:
        title = BlinkText(
          context.tr('appbar_regular'),
          beginColor: Theme.of(context).textTheme.titleMedium?.color,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
        _iconAnimationController.repeat();
        break;
      case AppState.waitingForNextGeneration:
        title = BlinkText(
          context.tr('appbar_generation_interval'),
          beginColor: Theme.of(context).textTheme.titleMedium?.color,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
        _iconAnimationController.stop();
        break;
    }
    Widget icon = RotationTransition(
        turns: _animation,
        child: Image.asset(
          'assets/appicon.png',
          filterQuality: FilterQuality.medium,
          height: widget.preferredSize.height - 16.0,
        ));
    final titleBar = Row(
      children: [
        InkWell(
          child: icon,
          onTap: () => _iconAnimationController
              .animateTo(Random().nextDouble())
              .whenComplete(refreshDisplay),
        ),
        const SizedBox(width: 8.0),
        Expanded(
          child: InkWell(
            onTap: () => _showDebugDialog(context),
            child: Align(alignment: Alignment.centerLeft, child: title),
          ),
        ),
        IconButton(
          key: const Key('app-help-button'),
          onPressed: () => _showAppInfoDialog(context),
          icon: const Icon(Icons.help_outline),
        ),
      ],
    );
    return AppBar(
      title: titleBar,
    );
  }

  @override
  void dispose() {
    widget.commandStatus.isGenerationActive.removeListener(refreshDisplay);
    widget.commandStatus.isWaitingForNextGeneration
        .removeListener(refreshDisplay);
    _iconAnimationController.dispose();
    super.dispose();
  }

  void _showAppInfoDialog(BuildContext context) {
    final packageInfo = GetIt.instance<ConfigService>().packageInfo;
    const appName = 'CasRand Forge';
    final appVersion = packageInfo.version;
    final iconImage = Image.asset(
      'assets/appicon.png',
      width: 64,
      height: 64,
      filterQuality: FilterQuality.medium,
    );

    showAboutDialog(
        context: context,
        applicationName: appName,
        applicationVersion: appVersion,
        applicationIcon: iconImage,
        children: [
          _buildLinkTile(),
          _buildDonationLink(context),
          _buildRestoreWelcomeMessageTile(context),
        ]);
  }

  Widget _buildRestoreWelcomeMessageTile(BuildContext context) {
    return ListTile(
      key: const Key('restore-welcome-message'),
      title: Text(tr('restore_welcome_message')),
      subtitle: Text(tr('restore_welcome_message_hint')),
      leading: const Icon(Icons.refresh),
      onTap: () {
        Navigator.of(context).pop();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.onRestoreWelcomeMessage();
        });
      },
    );
  }

  Widget _buildLinkTile() {
    const repositoryUrl = 'https://github.com/khkjdfkjhdsfakhds/CasRand-Forge';
    return ListTile(
      title: Text(tr('github_repo')),
      leading: const Icon(Icons.link),
      subtitle: const Text(repositoryUrl),
      onTap: () => launchUrl(Uri.parse(repositoryUrl)),
    );
  }

  Widget _buildDonationLink(BuildContext context) {
    return ListTile(
      title: Text(tr('donation_link')),
      subtitle: Text(tr('donation_link_subtitle')),
      leading: const Icon(Icons.coffee_outlined),
      onTap: () => _showDonationQRCode(context),
    );
  }

  void _showDonationQRCode(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return LayoutBuilder(
          builder: (dialogContext, viewportConstraints) {
            final mediaSize = MediaQuery.sizeOf(dialogContext);
            final viewportWidth = viewportConstraints.maxWidth.isFinite
                ? viewportConstraints.maxWidth
                : mediaSize.width;
            final viewportHeight = viewportConstraints.maxHeight.isFinite
                ? viewportConstraints.maxHeight
                : mediaSize.height;
            // 24 px dialog inset + 16 px content padding on each side.
            final availableWidth = max(0.0, viewportWidth - 80);
            final contentWidth = min(640.0, availableWidth);
            final useRow = contentWidth >= 520;
            final codeWidth =
                useRow ? (contentWidth - 16) / 2 : min(320.0, contentWidth);

            Widget buildCode(
              String labelKey,
              String assetPath,
              Key imageKey,
            ) {
              return SizedBox(
                width: codeWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(labelKey.tr()),
                    const SizedBox(height: 8),
                    AspectRatio(
                      aspectRatio: 2 / 3,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(
                              dialogContext,
                            ).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Image.asset(
                          assetPath,
                          key: imageKey,
                          fit: BoxFit.contain,
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            final wechat = buildCode(
              'donation_wechat',
              'assets/donation/wechat-pay.png',
              const Key('donation-wechat-code'),
            );
            final alipay = buildCode(
              'donation_alipay',
              'assets/donation/alipay.jpg',
              const Key('donation-alipay-code'),
            );
            return AlertDialog(
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              title: Text(tr('donation_link')),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: contentWidth,
                  maxHeight: viewportHeight * 0.72,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        tr('donation_dialog_message'),
                        key: const Key('donation-dialog-message'),
                        textAlign: TextAlign.center,
                        style: Theme.of(dialogContext)
                            .textTheme
                            .titleMedium
                            ?.copyWith(height: 1.45),
                      ),
                      const SizedBox(height: 20),
                      if (useRow)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            wechat,
                            const SizedBox(width: 16),
                            alipay,
                          ],
                        )
                      else
                        Column(
                          children: [
                            wechat,
                            const SizedBox(height: 20),
                            alipay,
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(tr('confirm')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showDebugDialog(BuildContext context) {
    showDialog(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Debug Settings'),
              content: DebugSettingsView(),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      tr('confirm'),
                    ))
              ],
            ));
  }
}
