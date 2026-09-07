import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:nai_casrand/ui/precise_reference/view_models/precise_reference_list_viewmodel.dart';
import 'package:nai_casrand/ui/precise_reference/widgets/precise_reference_list_view.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/utils/platform_support.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../viewmodels/vibe_config_v4_list_viewmodel.dart';
import '../viewmodels/vibe_config_v4_viewmodel.dart';
import 'vibe_config_v4_view.dart';

class VibeConfigV4ListView extends StatelessWidget {
  final VibeConfigV4ListViewmodel viewmodel;

  const VibeConfigV4ListView({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    final addVibeImage = Icon(
      Icons.add_photo_alternate_outlined,
      size: 120.0,
      color: Colors.grey.withAlpha(127),
    );

    final addVibeDropArea = InkWell(
      onTap: () => viewmodel.pickAndAddNewConfig(context),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              addVibeImage,
              Text(context.tr('vibe_add_reference')),
            ],
          ),
        ),
      ),
    );

    final pageTipCard = ListTile(
      leading: const Icon(Icons.info_outline),
      title: MarkdownBody(data: tr('vibe_v4_page_tip')),
      dense: true,
    );

    return ListenableBuilder(
      listenable: viewmodel,
      builder: (context, child) {
        return ListView(
          padding: const EdgeInsets.only(bottom: 24.0),
          children: [
            Card(
              margin: const EdgeInsets.fromLTRB(4.0, 4.0, 4.0, 8.0),
              child: ListTile(
                leading: const Icon(Icons.auto_awesome_motion_outlined),
                title: Text(context.tr('vibe_transfer')),
                subtitle: Text(context.tr('vibe_transfer_section_tip')),
                trailing: Switch(
                  key: const Key('vibe-feature-switch'),
                  value: viewmodel.featureEnabled,
                  onChanged: viewmodel.vibeList.isEmpty
                      ? null
                      : (value) {
                          final disabledPrecise = value &&
                              viewmodel.payloadConfig.preciseReferenceEnabled;
                          viewmodel.setFeatureEnabled(value);
                          if (disabledPrecise) {
                            showInfoBar(
                              context,
                              tr(
                                'advanced_feature_conflict_kept',
                                namedArgs: {
                                  'enabled': 'Vibe Transfer',
                                  'disabled': 'Precise Reference',
                                },
                              ),
                            );
                          }
                        },
                ),
              ),
            ),
            if (viewmodel.featureEnabled && viewmodel.estimatedExtraAnlas > 0)
              Card(
                color: Colors.amber.withAlpha(44),
                margin: const EdgeInsets.symmetric(
                  vertical: 4.0,
                  horizontal: 4.0,
                ),
                child: ListTile(
                  leading: const Icon(Icons.local_fire_department_outlined),
                  title: Text(
                    context.tr(
                      'vibe_cost_notice',
                      namedArgs: {
                        'vibe_count': viewmodel.vibeList.length.toString(),
                        'n_samples': viewmodel.nSamples.toString(),
                        'anlas': viewmodel.estimatedExtraAnlas.toString(),
                      },
                    ),
                  ),
                ),
              ),
            if (viewmodel.featureEnabled && viewmodel.pendingEncodingCount > 0)
              Card(
                color: Colors.orange.withAlpha(36),
                margin: const EdgeInsets.symmetric(
                  vertical: 4.0,
                  horizontal: 4.0,
                ),
                child: ListTile(
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: Text(
                    context.tr(
                      'vibe_encoding_cost_notice',
                      namedArgs: {
                        'count': viewmodel.pendingEncodingCount.toString(),
                        'anlas': viewmodel.estimatedEncodingAnlas.toString(),
                      },
                    ),
                  ),
                ),
              ),
            if (viewmodel.unavailableEncodingCount > 0)
              Card(
                color: Colors.red.withAlpha(28),
                margin: const EdgeInsets.symmetric(
                  vertical: 4.0,
                  horizontal: 4.0,
                ),
                child: ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(context.tr('vibe_encoding_model_unavailable')),
                ),
              ),
            for (final (index, config) in viewmodel.vibeList.indexed)
              VibeConfigV4View(
                key: ObjectKey(config),
                viewmodel: VibeConfigV4Viewmodel(
                  config: config,
                  model: viewmodel.currentModel,
                  onChanged: viewmodel.notifyConfigChanged,
                ),
                onDelete: () => viewmodel.removeConfigAtIndex(index),
              ),
            if (!supportsSuperNativeExtensions)
              addVibeDropArea
            else
              DropRegion(
                formats: Formats.standardFormats,
                onDropOver: (_) => DropOperation.copy,
                onPerformDrop: (event) => viewmodel.handleVibeDropEvent(
                  context,
                  event,
                ),
                child: addVibeDropArea,
              ),
            pageTipCard,
            const Divider(height: 32.0),
            PreciseReferenceListView(
              viewmodel: PreciseReferenceListViewmodel(),
            ),
          ],
        );
      },
    );
  }
}
