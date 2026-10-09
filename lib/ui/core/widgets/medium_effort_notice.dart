import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Explains what V5 Full Medium effort pins (fixed settings, no custom
/// negative prompts) next to the controls it affects.
class MediumEffortNotice extends StatelessWidget {
  const MediumEffortNotice({
    super.key,
    this.messageKey = 'medium_effort_negative_prompt_notice',
  });

  final String messageKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: Key('medium-effort-notice-$messageKey'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.tr(messageKey),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
