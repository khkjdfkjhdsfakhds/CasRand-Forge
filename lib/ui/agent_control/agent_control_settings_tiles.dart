import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/agent_control/agent_control_controller.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';

/// "Agent control" rows of the settings page.
class AgentControlSettingsTiles extends StatelessWidget {
  const AgentControlSettingsTiles({super.key, required this.controller});

  final AgentControlController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final running = controller.isRunning;
        final error = controller.lastError;
        final activity = controller.lastActivity;
        final String subtitle;
        if (error != null && controller.enabled && !running) {
          subtitle = tr('agent_control_failed', namedArgs: {'error': '$error'});
        } else if (running) {
          subtitle = tr('agent_control_running',
              namedArgs: {'url': controller.mcpUrl ?? ''});
        } else {
          subtitle = tr('agent_control_hint');
        }
        return Column(
          children: [
            SwitchListTile(
              key: const Key('agent-control-enabled'),
              secondary: const Icon(Icons.smart_toy_outlined),
              title: Text(tr('agent_control_enable')),
              subtitle: Text(subtitle),
              value: controller.enabled,
              onChanged: controller.setEnabled,
            ),
            if (running) ...[
              ListTile(
                key: const Key('agent-control-copy-command'),
                leading: const Icon(Icons.terminal),
                title: Text(tr('agent_control_copy_command')),
                subtitle: Text(tr('agent_control_copy_command_hint')),
                onTap: () async {
                  final command = controller.claudeCodeCommand;
                  if (command == null) return;
                  await Clipboard.setData(ClipboardData(text: command));
                  if (context.mounted) {
                    showInfoBar(context, tr('agent_control_copied'));
                  }
                },
              ),
              if (controller.discoveryFilePath != null)
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(tr('agent_control_discovery_file')),
                  subtitle: SelectableText(controller.discoveryFilePath!),
                ),
              ListTile(
                key: const Key('agent-control-regenerate-token'),
                leading: const Icon(Icons.key_outlined),
                title: Text(tr('agent_control_regenerate_token')),
                subtitle: Text(tr('agent_control_regenerate_token_hint')),
                onTap: () async {
                  await controller.regenerateToken();
                  if (context.mounted) {
                    showInfoBar(context, tr('agent_control_token_regenerated'));
                  }
                },
              ),
              if (activity != null)
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(tr('agent_control_last_activity')),
                  subtitle: Text(
                    '${agentActionLabel(activity.action)} · '
                    '${TimeOfDay.fromDateTime(activity.time).format(context)}',
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// A readable label for an agent tool name, falling back to the name.
String agentActionLabel(String action) {
  final key = 'agent_action_$action';
  final label = tr(key);
  return label == key ? action : label;
}
