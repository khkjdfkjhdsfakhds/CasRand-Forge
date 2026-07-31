import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/widgets/fixed_tooltip_fab.dart';
import 'package:nai_casrand/ui/core/widgets/prompt_mode_switch_button.dart';
import 'package:nai_casrand/ui/generation_page/widgets/classic_info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_settings_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/result_actions.dart'
    show formatAnlasBadge, formatAnlasTooltip;
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:waterfall_flow/waterfall_flow.dart';

class GenerationPageView extends StatefulWidget {
  final GenerationPageViewmodel viewmodel;

  const GenerationPageView({super.key, required this.viewmodel});

  @override
  State<GenerationPageView> createState() => _GenerationPageViewState();
}

class _GenerationPageViewState extends State<GenerationPageView> {
  final Map<Command<void, InfoCardContent>, GlobalKey> _resultKeys = {};
  final ScrollController _resultScrollController = ScrollController();

  GenerationPageViewmodel get viewmodel => widget.viewmodel;

  GlobalKey _keyFor(Command<void, InfoCardContent> command) {
    return _resultKeys.putIfAbsent(command, GlobalKey.new);
  }

  @override
  void dispose() {
    _resultScrollController.dispose();
    super.dispose();
  }

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
                        controller: _resultScrollController,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: viewmodel.colNum,
                          childAspectRatio: 1.6,
                          mainAxisSpacing: 8.0,
                          crossAxisSpacing: 8.0,
                        ),
                        padding: const EdgeInsets.all(8.0),
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          final command =
                              viewmodel.commandList[itemCount - 1 - index];
                          return KeyedSubtree(
                            key: _keyFor(command),
                            child: ClassicInfoCard(
                              command: command,
                              onOpenDetail: () => _openResultGallery(command),
                            ),
                          );
                        },
                      )
                    : WaterfallFlow.builder(
                        controller: _resultScrollController,
                        gridDelegate:
                            SliverWaterfallFlowDelegateWithFixedCrossAxisCount(
                                crossAxisCount: viewmodel.colNum),
                        padding: const EdgeInsets.all(8.0),
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          final command =
                              viewmodel.commandList[itemCount - 1 - index];
                          return KeyedSubtree(
                            key: _keyFor(command),
                            child: InfoCard(
                              command: command,
                              onOpenDetail: () => _openResultGallery(command),
                            ),
                          );
                        },
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
          if (_hasAdvancedResources()) ...[
            FixedTooltipFab(
              heroTag: 'gpfab-advanced',
              buttonKey: const Key('advanced-features-fab'),
              onPressed: () => _showAdvancedFeaturesDialog(context),
              tooltip: tr('advanced_features_status'),
              icon: const Icon(Icons.layers_outlined),
              label: Text(tr('advanced_features_status')),
            ),
            const SizedBox(height: 12.0),
          ],
          FixedTooltipFab(
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

  Future<void> _openResultGallery(
    Command<void, InfoCardContent> initialCommand,
  ) async {
    if (initialCommand.isExecuting.value) return;
    final commands = viewmodel.commandList.reversed
        .where((command) => !command.isExecuting.value)
        .toList(growable: false);
    final initialIndex = commands.indexOf(initialCommand);
    if (initialIndex < 0) return;
    var returnIndex = initialIndex;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => InfoDetailPage.gallery(
          contents: commands.map((command) => command.value).toList(),
          initialIndex: initialIndex,
          onIndexChanged: (index) => returnIndex = index,
        ),
      ),
    );
    if (!mounted || returnIndex < 0 || returnIndex >= commands.length) return;
    await _revealResult(commands[returnIndex], commands);
  }

  Future<void> _revealResult(
    Command<void, InfoCardContent> command,
    List<Command<void, InfoCardContent>> displayOrder,
  ) async {
    final key = _keyFor(command);
    var targetContext = key.currentContext;
    if (targetContext == null && _resultScrollController.hasClients) {
      final index = displayOrder.indexOf(command);
      final denominator = max(1, displayOrder.length - 1);
      final target = _resultScrollController.position.maxScrollExtent *
          (index / denominator);
      await _resultScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      targetContext = key.currentContext;
    }
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  bool _hasAdvancedResources() {
    final config = viewmodel.payloadConfig;
    return config.i2iConfig.hasImage ||
        config.vibeConfigList.isNotEmpty ||
        config.vibeConfigListV4.isNotEmpty ||
        config.preciseReferenceConfigList.isNotEmpty;
  }

  void _showAdvancedFeaturesDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          final config = viewmodel.payloadConfig;
          final preciseSupported = config.paramConfig.model.contains('-4-5-');
          return AlertDialog(
            title: Text(tr('advanced_features_status')),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: Text(tr('i2i_inpaint')),
                    subtitle: Text(config.i2iConfig.hasImage
                        ? tr('resource_ready')
                        : tr('resource_missing')),
                    value: config.i2iEnabled,
                    onChanged: config.i2iConfig.hasImage
                        ? (value) => setState(() {
                              config.setI2iEnabled(value);
                              viewmodel.advancedFeaturesChanged();
                            })
                        : null,
                  ),
                  SwitchListTile(
                    title: const Text('Vibe Transfer'),
                    subtitle: Text(config.vibeConfigList.isNotEmpty ||
                            config.vibeConfigListV4.isNotEmpty
                        ? tr('resource_ready')
                        : tr('resource_missing')),
                    value: config.vibeEnabled,
                    onChanged: config.vibeConfigList.isNotEmpty ||
                            config.vibeConfigListV4.isNotEmpty
                        ? (value) {
                            final disabledPrecise =
                                value && config.preciseReferenceEnabled;
                            setState(() {
                              config.setVibeEnabled(value);
                              viewmodel.advancedFeaturesChanged();
                            });
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
                          }
                        : null,
                  ),
                  SwitchListTile(
                    title: const Text('Precise Reference'),
                    subtitle: Text(!preciseSupported
                        ? tr('precise_reference_v45_only')
                        : config.preciseReferenceConfigList.isNotEmpty
                            ? tr('resource_ready')
                            : tr('resource_missing')),
                    value: config.preciseReferenceEnabled,
                    onChanged: preciseSupported &&
                            config.preciseReferenceConfigList.isNotEmpty
                        ? (value) {
                            final disabledVibe = value && config.vibeEnabled;
                            setState(() {
                              config.setPreciseReferenceEnabled(value);
                              viewmodel.advancedFeaturesChanged();
                            });
                            if (disabledVibe) {
                              showInfoBar(
                                context,
                                tr(
                                  'advanced_feature_conflict_kept',
                                  namedArgs: {
                                    'enabled': 'Precise Reference',
                                    'disabled': 'Vibe Transfer',
                                  },
                                ),
                              );
                            }
                          }
                        : null,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  GetIt.I<NavigationRequest>()
                      .goTo(AppDestination.imageToImage);
                },
                icon: const Icon(Icons.image_outlined),
                label: Text(tr('open_i2i_settings')),
              ),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  GetIt.I<NavigationRequest>()
                      .goTo(AppDestination.vibeReference);
                },
                icon: const Icon(Icons.auto_awesome_motion_outlined),
                label: Text(tr('open_reference_settings')),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(tr('confirm')),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Start/stop button. While idle it shows the estimated Anlas of the next
  /// generation as a number (including zero); while generating it is a stop
  /// button.
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
          return FixedTooltipFab(
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
          return FixedTooltipFab(
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
        return FixedTooltipFab(
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
