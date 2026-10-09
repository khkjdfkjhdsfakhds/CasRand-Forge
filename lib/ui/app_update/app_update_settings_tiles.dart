import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/app_update/app_update_controller.dart';
import 'package:nai_casrand/ui/app_update/app_update_dialog.dart';

/// "Software update" rows of the settings page.
class AppUpdateSettingsTiles extends StatelessWidget {
  const AppUpdateSettingsTiles({super.key, required this.controller});

  final AppUpdateController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final release = controller.latestRelease;
        final available = controller.updateAvailable && release != null;
        return Column(
          children: [
            ListTile(
              key: const Key('app-update-check-tile'),
              leading: Badge(
                isLabelVisible: available,
                child: const Icon(Icons.system_update_alt),
              ),
              title: Text(tr('app_update_check')),
              subtitle: Text(available
                  ? tr('app_update_check_hint_available',
                      namedArgs: {'version': release.tagName})
                  : tr('app_update_check_hint',
                      namedArgs: {'version': controller.currentVersion})),
              trailing: controller.isBusy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: () =>
                  available && controller.phase != AppUpdatePhase.failed
                      ? showAppUpdateDialog(context, controller)
                      : checkForUpdatesInteractively(context, controller),
            ),
            SwitchListTile(
              key: const Key('app-update-auto-check'),
              secondary: const Icon(Icons.update),
              title: Text(tr('app_update_auto_check')),
              subtitle: Text(tr('app_update_auto_check_hint')),
              value: controller.autoCheckEnabled,
              onChanged: controller.setAutoCheckEnabled,
            ),
          ],
        );
      },
    );
  }
}
