import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';

class PromptModeSwitchButton extends StatelessWidget {
  const PromptModeSwitchButton({
    super.key,
    required this.payloadConfig,
    required this.onChanged,
    this.heroTag,
  });

  final PayloadConfig payloadConfig;
  final VoidCallback onChanged;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final fixed = payloadConfig.promptMode == PromptMode.fixed;
    void onPressed() {
      showPromptModeSwitchDialog(
        context,
        payloadConfig: payloadConfig,
        onChanged: onChanged,
      );
    }

    final label = context.tr(
      fixed ? 'prompt_mode_fixed' : 'prompt_mode_random',
    );
    return FloatingActionButton.extended(
      key: const Key('prompt-mode-switch'),
      heroTag: heroTag,
      onPressed: onPressed,
      tooltip: label,
      isExtended: false,
      icon: Icon(fixed ? Icons.push_pin : Icons.shuffle),
      label: Text(label),
    );
  }
}

Future<void> showPromptModeSwitchDialog(
  BuildContext context, {
  required PayloadConfig payloadConfig,
  required VoidCallback onChanged,
}) async {
  Future<void> switchMode() async {
    payloadConfig.switchPromptMode();
    onChanged();
    if (GetIt.I.isRegistered<ConfigService>()) {
      await GetIt.I<ConfigService>().saveConfig(payloadConfig.toJson());
    }
    if (context.mounted) {
      showPromptModeNotice(context, payloadConfig.promptMode);
    }
  }

  if (!payloadConfig.settings.confirmPromptModeSwitch) {
    await switchMode();
    return;
  }

  var doNotAskAgain = false;
  final currentFixed = payloadConfig.promptMode == PromptMode.fixed;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(context.tr('prompt_mode_switch_title')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr(
                  'prompt_mode_current',
                  namedArgs: {
                    'mode': context.tr(
                      currentFixed ? 'prompt_mode_fixed' : 'prompt_mode_random',
                    ),
                  },
                ),
              ),
              const SizedBox(height: 12),
              Text(
                context.tr(
                  currentFixed
                      ? 'prompt_mode_switch_to_random_effect'
                      : 'prompt_mode_switch_to_fixed_effect',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lock_outline, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(context.tr('prompt_mode_profiles_preserved')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('prompt-mode-dont-ask-again'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(context.tr('do_not_ask_again')),
                value: doNotAskAgain,
                onChanged: (value) =>
                    setState(() => doNotAskAgain = value ?? false),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.tr('cancel')),
          ),
          FilledButton(
            key: const Key('prompt-mode-confirm-switch'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.tr('prompt_mode_confirm_switch')),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true || !context.mounted) return;
  if (doNotAskAgain) {
    payloadConfig.settings.confirmPromptModeSwitch = false;
  }
  await switchMode();
}

void showPromptModeNotice(BuildContext context, PromptMode mode) {
  showInfoBar(
    context,
    context.tr(
      mode == PromptMode.fixed
          ? 'prompt_mode_fixed_notice'
          : 'prompt_mode_random_notice',
    ),
  );
}

void showFixedModeImportNotice(BuildContext context, String detail) {
  showInfoBar(
    context,
    '$detail\n${context.tr('prompt_mode_fixed_notice')}',
  );
}
