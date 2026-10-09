import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:nai_casrand/data/services/app_update_service.dart';
import 'package:nai_casrand/ui/app_update/app_update_controller.dart';
import 'package:url_launcher/url_launcher.dart';

/// Runs a user-initiated check and shows its outcome.
Future<void> checkForUpdatesInteractively(
  BuildContext context,
  AppUpdateController controller,
) async {
  if (controller.phase == AppUpdatePhase.readyToRestart || controller.isBusy) {
    return showAppUpdateDialog(context, controller);
  }
  final dialog = showAppUpdateDialog(context, controller);
  await controller.check();
  await dialog;
}

/// Shows the update dialog bound to [controller]'s current state.
/// [automatic] adds the "skip this version" choice used by background checks.
Future<void> showAppUpdateDialog(
  BuildContext context,
  AppUpdateController controller, {
  bool automatic = false,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AppUpdateDialog(
      controller: controller,
      automatic: automatic,
    ),
  );
}

class AppUpdateDialog extends StatelessWidget {
  const AppUpdateDialog({
    super.key,
    required this.controller,
    this.automatic = false,
  });

  final AppUpdateController controller;
  final bool automatic;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final width = min(520.0, MediaQuery.sizeOf(context).width - 48);
        return AlertDialog(
          key: const Key('app-update-dialog'),
          title: Text(_title()),
          content: SizedBox(width: width, child: _content(context)),
          actions: _actions(context),
        );
      },
    );
  }

  ReleaseInfo? get _release => controller.latestRelease;

  String _title() {
    final release = _release;
    return switch (controller.phase) {
      AppUpdatePhase.idle ||
      AppUpdatePhase.checking =>
        tr('app_update_checking'),
      AppUpdatePhase.upToDate => tr('app_update_up_to_date_title'),
      AppUpdatePhase.failed => tr('app_update_failed_title'),
      AppUpdatePhase.readyToRestart => tr('app_update_ready_title'),
      _ => tr('app_update_available_title',
          namedArgs: {'version': release?.tagName ?? ''}),
    };
  }

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    switch (controller.phase) {
      case AppUpdatePhase.idle:
      case AppUpdatePhase.checking:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: LinearProgressIndicator(),
        );
      case AppUpdatePhase.upToDate:
        return Text(tr('app_update_up_to_date', namedArgs: {
          'version': controller.currentVersion,
        }));
      case AppUpdatePhase.failed:
        return Text(
          tr('app_update_error_${controller.errorCode ?? 'network'}'),
          key: const Key('app-update-error'),
        );
      case AppUpdatePhase.downloading:
        final total = controller.totalBytes;
        final received = controller.receivedBytes;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('app_update_downloading')),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              key: const Key('app-update-progress'),
              value: total == null || total == 0
                  ? null
                  : (received / total).clamp(0.0, 1.0),
            ),
            const SizedBox(height: 8),
            Text(
              total == null
                  ? _formatBytes(received)
                  : '${_formatBytes(received)} / ${_formatBytes(total)}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        );
      case AppUpdatePhase.preparing:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('app_update_preparing')),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        );
      case AppUpdatePhase.readyToRestart:
        return Text(tr('app_update_ready'));
      case AppUpdatePhase.installerOpened:
        return Text(tr('app_update_installer_opened'));
      case AppUpdatePhase.permissionRequired:
        return Text(tr('app_update_permission_required'));
      case AppUpdatePhase.manualInstall:
        return Text(tr(defaultTargetPlatform == TargetPlatform.windows
            ? 'app_update_manual_windows'
            : 'app_update_manual_macos'));
      case AppUpdatePhase.available:
        return _releaseSummary(context);
    }
  }

  Widget _releaseSummary(BuildContext context) {
    final release = _release!;
    final theme = Theme.of(context);
    final asset = controller.installableAsset;
    final details = <String>[
      tr('app_update_current_version',
          namedArgs: {'version': controller.currentVersion}),
      if (release.publishedAt != null)
        tr('app_update_published_at', namedArgs: {
          'date': DateFormat.yMd(context.locale.toLanguageTag())
              .format(release.publishedAt!.toLocal()),
        }),
      if (asset?.size != null)
        tr('app_update_package_size',
            namedArgs: {'size': _formatBytes(asset!.size!)}),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(details.join(' · '), style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: release.notes.isEmpty
                ? Text(tr('app_update_notes_unavailable'))
                : SingleChildScrollView(
                    child: MarkdownBody(
                      key: const Key('app-update-notes'),
                      data: release.notes,
                      onTapLink: (text, href, title) {
                        if (href != null) launchUrl(Uri.parse(href));
                      },
                    ),
                  ),
          ),
        ),
        if (asset == null) ...[
          const SizedBox(height: 12),
          Text(tr('app_update_manual_only'), style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }

  List<Widget> _actions(BuildContext context) {
    void close() => Navigator.of(context).pop();
    final openRelease = TextButton(
      key: const Key('app-update-open-github'),
      onPressed: () {
        launchUrl(
          _release?.pageUrl ?? Uri.parse(appUpdateLatestReleaseUrl),
          mode: LaunchMode.externalApplication,
        );
      },
      child: Text(tr('app_update_open_github')),
    );

    switch (controller.phase) {
      case AppUpdatePhase.idle:
      case AppUpdatePhase.checking:
        return [TextButton(onPressed: close, child: Text(tr('cancel')))];
      case AppUpdatePhase.upToDate:
        return [
          FilledButton(onPressed: close, child: Text(tr('confirm'))),
        ];
      case AppUpdatePhase.failed:
        return [
          openRelease,
          TextButton(onPressed: close, child: Text(tr('cancel'))),
          FilledButton(
            key: const Key('app-update-retry'),
            onPressed: controller.retry,
            child: Text(tr('app_update_retry')),
          ),
        ];
      case AppUpdatePhase.downloading:
        return [
          TextButton(
            key: const Key('app-update-cancel-download'),
            onPressed: controller.cancelDownload,
            child: Text(tr('cancel')),
          ),
        ];
      case AppUpdatePhase.preparing:
        return const [];
      case AppUpdatePhase.readyToRestart:
        return [
          TextButton(
            onPressed: () async {
              await controller.discardPreparedUpdate();
              if (context.mounted) close();
            },
            child: Text(tr('app_update_later')),
          ),
          FilledButton(
            key: const Key('app-update-restart'),
            onPressed: controller.restartToUpdate,
            child: Text(tr('app_update_restart_now')),
          ),
        ];
      case AppUpdatePhase.installerOpened:
      case AppUpdatePhase.permissionRequired:
        return [
          TextButton(onPressed: close, child: Text(tr('app_update_later'))),
          FilledButton(
            key: const Key('app-update-retry-install'),
            onPressed: controller.downloadAndInstall,
            child: Text(tr(controller.phase == AppUpdatePhase.installerOpened
                ? 'app_update_reopen_installer'
                : 'app_update_retry')),
          ),
        ];
      case AppUpdatePhase.manualInstall:
        return [
          openRelease,
          FilledButton(
            onPressed: () async {
              await controller.discardPreparedUpdate();
              if (context.mounted) close();
            },
            child: Text(tr('confirm')),
          ),
        ];
      case AppUpdatePhase.available:
        return [
          if (automatic)
            TextButton(
              key: const Key('app-update-skip'),
              onPressed: () {
                controller.skipLatestVersion();
                close();
              },
              child: Text(tr('app_update_skip_version')),
            ),
          TextButton(
            key: const Key('app-update-later'),
            onPressed: close,
            child: Text(tr('app_update_later')),
          ),
          if (controller.canInstallInApp) ...[
            openRelease,
            FilledButton(
              key: const Key('app-update-install'),
              onPressed: controller.downloadAndInstall,
              child: Text(tr('app_update_install')),
            ),
          ] else
            FilledButton(
              key: const Key('app-update-open-github'),
              onPressed: () => launchUrl(
                _release!.pageUrl,
                mode: LaunchMode.externalApplication,
              ),
              child: Text(tr('app_update_open_github')),
            ),
        ];
    }
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
