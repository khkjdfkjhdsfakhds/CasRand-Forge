import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:nai_casrand/ui/precise_reference/view_models/precise_reference_list_viewmodel.dart';
import 'package:nai_casrand/ui/precise_reference/widgets/precise_reference_list_view.dart';
import 'package:nai_casrand/ui/core/utils/platform_support.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:url_launcher/url_launcher.dart';

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
              Text(context.tr('drag_and_drop_image_notice')),
            ],
          ),
        ),
      ),
    );

    final vibeHeaderCard = Card(
      margin: const EdgeInsets.fromLTRB(4.0, 4.0, 4.0, 8.0),
      child: ListTile(
        leading: const Icon(Icons.auto_awesome_motion_outlined),
        title: Text(context.tr('vibe_transfer')),
        subtitle: Text(context.tr('vibe_transfer_section_tip')),
      ),
    );

    final pageTipCard = ListTile(
      leading: const Icon(Icons.info_outline),
      title: MarkdownBody(
        data: tr('vibe_v4_page_tip'),
        onTapLink: (text, href, title) => launchUrl(
          Uri.parse(href!),
        ),
      ),
      dense: true,
    );

    return ListenableBuilder(
      listenable: viewmodel,
      builder: (context, child) {
        return ListView(
          padding: const EdgeInsets.only(bottom: 24.0),
          children: [
            vibeHeaderCard,
            for (final (index, config) in viewmodel.vibeList.indexed)
              VibeConfigV4View(
                key: ValueKey(config.vibeB64),
                viewmodel: VibeConfigV4Viewmodel(config: config),
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
