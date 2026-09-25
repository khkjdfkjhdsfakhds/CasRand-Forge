import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:nai_casrand/ui/i2i_tab/view_models/i2i_tab_viewmodel.dart';
import 'package:nai_casrand/ui/vibe_config/view_models/vibe_config_list_viewmodel.dart';
import 'package:nai_casrand/ui/vibe_config/widgets/vibe_config_list_view.dart';
import 'package:nai_casrand/ui/vibe_config_v4/viewmodels/vibe_config_v4_list_viewmodel.dart';
import 'package:nai_casrand/ui/vibe_config_v4/widgets/vibe_config_v4_list_view.dart';

class I2iTabView extends StatelessWidget {
  final I2iTabViewmodel viewmodel;

  const I2iTabView({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([viewmodel, viewmodel.payloadConfig]),
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final vibeWidget = !viewmodel.isLegacy
        ? VibeConfigV4ListView(viewmodel: VibeConfigV4ListViewmodel())
        : VibeConfigListView(viewmodel: VibeConfigListViewmodel());

    if (viewmodel.isV5) {
      return Column(
        children: [
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            margin: const EdgeInsets.fromLTRB(4.0, 4.0, 4.0, 0.0),
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(tr('nai5_reference_unavailable')),
            ),
          ),
          Expanded(child: vibeWidget),
        ],
      );
    }

    return vibeWidget;
  }
}
