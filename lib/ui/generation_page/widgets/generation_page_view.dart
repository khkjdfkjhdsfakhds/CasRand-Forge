import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/core/constants/feature_flags.dart';
import 'package:nai_casrand/ui/core/widgets/editable_list_tile.dart';
import 'package:nai_casrand/ui/generation_page/widgets/classic_info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_settings_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:waterfall_flow/waterfall_flow.dart';

class GenerationPageView extends StatelessWidget {
  final GenerationPageViewmodel viewmodel;

  const GenerationPageView({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    final content = ListenableBuilder(
        listenable: viewmodel,
        builder: (context, _) {
          final itemCount = viewmodel.commandList.length;
          final useClassicMode =
              viewmodel.payloadConfig.settings.resultDisplayMode == 'classic';
          return Column(
            children: [
              Expanded(
                child: useClassicMode
                    ? GridView.builder(
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: viewmodel.colNum,
                          childAspectRatio: 1.6,
                          mainAxisSpacing: 8.0,
                          crossAxisSpacing: 8.0,
                        ),
                        padding: const EdgeInsets.all(8.0),
                        itemCount: itemCount,
                        itemBuilder: (context, index) => ClassicInfoCard(
                          command:
                              viewmodel.commandList[itemCount - 1 - index],
                        ),
                      )
                    : WaterfallFlow.builder(
                        gridDelegate:
                            SliverWaterfallFlowDelegateWithFixedCrossAxisCount(
                                crossAxisCount: viewmodel.colNum),
                        padding: const EdgeInsets.all(8.0),
                        itemCount: itemCount,
                        itemBuilder: (context, index) => InfoCard(
                          command:
                              viewmodel.commandList[itemCount - 1 - index],
                        ),
                      ),
              ),
              if (FeatureFlags.overridePrompt &&
                  viewmodel.payloadConfig.useOverridePrompt)
                EditableListTile(
                  title: tr('override_prompt'),
                  leading: const Icon(Icons.edit_note),
                  maxLines: 2,
                  keyboardType: TextInputType.multiline,
                  currentValue: viewmodel.payloadConfig.overridePrompt,
                  onEditComplete: (value) => viewmodel.setOverridePrompt(value),
                  confirmOnSubmit: true,
                ),
              if (FeatureFlags.overridePrompt &&
                  viewmodel.payloadConfig.useOverridePrompt)
                EditableListTile(
                  title: tr('uc'),
                  leading: const Icon(Icons.do_not_disturb),
                  maxLines: 1,
                  keyboardType: TextInputType.multiline,
                  currentValue:
                      viewmodel.payloadConfig.paramConfig.negativePrompt,
                  onEditComplete: (value) => viewmodel.setUC(value),
                  confirmOnSubmit: true,
                )
            ],
          );
        });
    final buttons = Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        FloatingActionButton(
          heroTag: 'gpfab1',
          onPressed: () => _showDisplaySettingsDialog(context),
          tooltip: tr('generation_settings'),
          child: const Icon(Icons.handyman_outlined),
        ),
        const SizedBox(height: 20.0),
        FloatingActionButton(
          heroTag: 'gpfab2',
          onPressed: () => viewmodel.addTestPromptInfoCardContent(),
          tooltip: tr('generate_one_prompt'),
          child: const Icon(Icons.add),
        ),
        const SizedBox(height: 20.0),
        FloatingActionButton(
          heroTag: 'gpfab3',
          onPressed: () => viewmodel.toggleGeneration(),
          tooltip: tr('toggle_generation'),
          child: ListenableBuilder(
            listenable: viewmodel.commandStatus.isGenerationActive,
            builder: (context, child) => Icon(
                viewmodel.commandStatus.isGenerationActive.value
                    ? Icons.stop
                    : Icons.play_arrow),
          ),
        ),
      ],
    );
    return Scaffold(
      body: content,
      floatingActionButton: buttons,
    );
  }

  void _showDisplaySettingsDialog(BuildContext context) {
    showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text(dialogContext.tr('generation_settings')),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 560,
                  maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.72,
                ),
                child: GenerationSettingsView(viewmodel: viewmodel),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(dialogContext.tr('confirm')))
              ],
            ));
  }
}
