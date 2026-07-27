import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/core/widgets/hover_expandable_fab.dart';
import 'package:nai_casrand/ui/core/widgets/prompt_mode_switch_button.dart';
import 'package:nai_casrand/ui/generation_page/widgets/classic_info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_settings_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/result_actions.dart'
    show formatAnlasBadge, formatAnlasTooltip;
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
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: viewmodel.colNum,
                          childAspectRatio: 1.6,
                          mainAxisSpacing: 8.0,
                          crossAxisSpacing: 8.0,
                        ),
                        padding: const EdgeInsets.all(8.0),
                        itemCount: itemCount,
                        itemBuilder: (context, index) => ClassicInfoCard(
                          command: viewmodel.commandList[itemCount - 1 - index],
                        ),
                      )
                    : WaterfallFlow.builder(
                        gridDelegate:
                            SliverWaterfallFlowDelegateWithFixedCrossAxisCount(
                                crossAxisCount: viewmodel.colNum),
                        padding: const EdgeInsets.all(8.0),
                        itemCount: itemCount,
                        itemBuilder: (context, index) => InfoCard(
                          command: viewmodel.commandList[itemCount - 1 - index],
                        ),
                      ),
              ),
            ],
          );
        });
    final buttons = ListenableBuilder(
      listenable: viewmodel,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          HoverExpandableFab(
            heroTag: 'gpfab1',
            buttonKey: const Key('generation-settings-fab'),
            onPressed: () => _showDisplaySettingsDialog(context),
            tooltip: tr('generation_settings'),
            icon: const Icon(Icons.handyman_outlined),
            label: Text(tr('generation_settings')),
          ),
          const SizedBox(height: 12.0),
          PromptModeSwitchButton(
            payloadConfig: viewmodel.payloadConfig,
            onChanged: viewmodel.promptModeChanged,
            heroTag: 'gpfab-mode',
            expandOnHover: true,
          ),
          const SizedBox(height: 12.0),
          HoverExpandableFab(
            heroTag: 'gpfab2',
            buttonKey: const Key('generate-prompt-fab'),
            onPressed: () => viewmodel.addTestPromptInfoCardContent(),
            tooltip: tr('generate_one_prompt'),
            icon: const Icon(Icons.add),
            label: Text(tr('generate_one_prompt')),
          ),
          const SizedBox(height: 12.0),
          _buildGenerationFab(context),
        ],
      ),
    );
    return Scaffold(
      body: content,
      floatingActionButton: buttons,
    );
  }

  /// Start/stop button. While idle it shows the estimated Anlas of the next
  /// generation ("免费" under Opus); while generating it is a stop button.
  Widget _buildGenerationFab(BuildContext context) {
    viewmodel.refreshCostEstimate();
    return ListenableBuilder(
      listenable: Listenable.merge([
        viewmodel.commandStatus.isGenerationActive,
        viewmodel.nextCostEstimate,
      ]),
      builder: (context, _) {
        final active = viewmodel.commandStatus.isGenerationActive.value;
        if (active) {
          return HoverExpandableFab(
            heroTag: 'gpfab3',
            buttonKey: const Key('generation-toggle-fab'),
            onPressed: () => viewmodel.toggleGeneration(),
            tooltip: tr('stop_generation'),
            icon: const Icon(Icons.stop),
            label: Text(tr('stop_generation')),
          );
        }
        final cost = viewmodel.nextCostEstimate.value;
        final badge = formatAnlasBadge(cost);
        if (badge.isEmpty) {
          return HoverExpandableFab(
            heroTag: 'gpfab3',
            buttonKey: const Key('generation-toggle-fab'),
            onPressed: () => viewmodel.toggleGeneration(),
            tooltip: tr('start_generation'),
            icon: const Icon(Icons.play_arrow),
            label: Text(tr('start_generation')),
          );
        }
        final bound = viewmodel.nextCostIsUpperBound &&
                cost != null &&
                !cost.isFreeUnderOpus
            ? '≤ '
            : '';
        return HoverExpandableFab(
          heroTag: 'gpfab3',
          buttonKey: const Key('generation-toggle-fab'),
          onPressed: () => viewmodel.toggleGeneration(),
          tooltip: formatAnlasTooltip(
            cost,
            isUpperBound: viewmodel.nextCostIsUpperBound,
          ),
          icon: const Icon(Icons.play_arrow),
          label: Text('${tr('start_generation')} · $bound$badge'),
        );
      },
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
