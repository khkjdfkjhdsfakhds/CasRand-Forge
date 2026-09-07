import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/batch_tool_snapshot.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

class ToolBatchSendButton extends StatelessWidget {
  const ToolBatchSendButton(
      {super.key,
      required this.kind,
      required this.viewmodel,
      required this.enabled});

  final BatchToolKind kind;
  final GenerationPageViewmodel viewmodel;
  final bool enabled;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        key: Key('${kind.name}-send-to-batch'),
        onPressed: enabled && viewmodel.canChangeBatchTool
            ? () async {
                final sent = await viewmodel.sendToolToBatch(kind);
                if (!context.mounted) return;
                if (sent) {
                  GetIt.I<NavigationRequest>().goTo(AppDestination.generation);
                } else if (viewmodel.toolBatchError != null) {
                  showErrorBar(context,
                      '${tr('image_handoff_failed')}: ${viewmodel.toolBatchError}');
                }
              }
            : null,
        icon: viewmodel.isSendingToolToBatch
            ? const SizedBox.square(
                dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.playlist_add),
        label: Text(tr('send_parameters_to_batch')),
      );
}
