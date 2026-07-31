import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';

/// The actions offered on a finished image, mirroring the official result
/// toolbar. Generate Variations and Upscale are deliberately not included.
/// Every action hands the image off to its own destination and switches the
/// main navigation there.
class ResultActions {
  final InfoCardContent content;

  ResultActions({required this.content});

  PayloadConfig get _payloadConfig => GetIt.I<PayloadConfig>();
  ImageHandoffCoordinator get _handoff => GetIt.I<ImageHandoffCoordinator>();

  bool get hasImage => content.imageBytes != null;

  /// The prompt actually sent for this image, when it is known.
  String? get sourcePrompt {
    final input = content.additionalInfo['input'];
    return input is String && input.isNotEmpty ? input : null;
  }

  /// The seed this image was generated with, when it is known.
  int? get sourceSeed {
    final seed = content.additionalInfo['seed'];
    if (seed is int) return seed;
    if (seed is String) return int.tryParse(seed);
    return null;
  }

  int? get sourceSteps {
    final steps = content.additionalInfo['steps'];
    return steps is int ? steps : null;
  }

  /// Closes the detail page (and any viewer above it) so the navigation
  /// shell, already switched to the target destination, becomes visible.
  void _returnToShell(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void useAsBaseImage(BuildContext context) {
    final bytes = content.imageBytes;
    if (bytes == null || !_handoff.useAsBaseImage(bytes)) return;
    showInfoBar(context, tr('action_use_as_base_done'));
    _returnToShell(context);
  }

  void sendToInpaint(BuildContext context) {
    final bytes = content.imageBytes;
    if (bytes == null || !_handoff.sendToInpaint(bytes)) return;
    showInfoBar(context, tr('action_inpaint_done'));
    _returnToShell(context);
  }

  void sendToEnhance(BuildContext context) {
    final bytes = content.imageBytes;
    if (bytes == null) return;
    final rawModel = content.additionalInfo['model'];
    if (!_handoff.sendToEnhance(
      bytes,
      metadata: content.additionalInfo,
      prompt: sourcePrompt,
      model: rawModel is String ? rawModel : null,
    )) {
      return;
    }
    showInfoBar(context, tr('action_enhance_fixed_mode_done'));
    _returnToShell(context);
  }

  void sendToDirectorTools(BuildContext context) {
    final bytes = content.imageBytes;
    if (bytes == null || !_handoff.sendToDirectorTools(bytes)) return;
    showInfoBar(context, tr('action_director_done'));
    _returnToShell(context);
  }

  /// Estimated Anlas for an Enhance run of this image at the Enhance page's
  /// current magnification and preset, or null when the size is unknown.
  AnlasCost? estimateEnhanceCost() {
    final width = content.additionalInfo['width'];
    final height = content.additionalInfo['height'];
    if (width is! int || height is! int) return null;
    if (!_payloadConfig.settings.subscriptionStatusKnown) return null;
    final enhance = _payloadConfig.enhanceConfig;
    int snap(int value) => value < 64 ? 64 : (value / 64).round() * 64;
    final targetW = snap((width * enhance.scale).round());
    final targetH = snap((height * enhance.scale).round());
    final paramConfig = _payloadConfig.paramConfig;
    final smActive = !paramConfig.model.contains('diffusion-4');
    return estimateAnlasCost(
      width: targetW,
      height: targetH,
      steps: sourceSteps ?? paramConfig.steps,
      action: 'img2img',
      strength: enhance.preset.strength,
      sm: smActive && paramConfig.sm,
      smDyn: smActive && paramConfig.smDyn,
      tier: _payloadConfig.settings.subscriptionTier,
      subscriptionActive: _payloadConfig.settings.subscriptionActive,
    );
  }
}

/// Formats an Anlas estimate for a toolbar button.
String formatAnlasBadge(AnlasCost? cost) {
  if (cost == null) return '';
  return cost.anlas.toString();
}

/// Reader-facing hover text for any generation action.
String formatAnlasTooltip(AnlasCost? cost, {bool isUpperBound = false}) {
  if (cost == null) return tr('generation_cost_pending');
  return tr(
    isUpperBound
        ? 'generation_cost_tooltip_upper_bound'
        : 'generation_cost_tooltip',
    namedArgs: {'anlas': cost.anlas.toString()},
  );
}

/// Reader-facing hover text for tools whose displayed cost is an estimate.
String formatEstimatedAnlasTooltip(AnlasCost? cost) {
  if (cost == null) return tr('estimated_generation_cost_pending');
  return tr(
    'estimated_generation_cost_tooltip',
    namedArgs: {'anlas': cost.anlas.toString()},
  );
}

/// Action bar shown under a finished image: four evenly weighted tonal
/// buttons that hand the image off to Enhance / Img2Img / Inpaint / Director
/// Tools and switch the navigation there.
class ResultActionBar extends StatelessWidget {
  final InfoCardContent content;

  const ResultActionBar({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    final actions = ResultActions(content: content);
    if (!actions.hasImage) return const SizedBox.shrink();
    final badge = formatAnlasBadge(actions.estimateEnhanceCost());

    final buttons = [
      _ActionButton(
        actionKey: const Key('result-action-enhance'),
        icon: Icons.auto_awesome_outlined,
        label: tr('enhance_section'),
        badge: badge,
        onPressed: () => actions.sendToEnhance(context),
      ),
      _ActionButton(
        actionKey: const Key('result-action-base-image'),
        icon: Icons.image_outlined,
        label: tr('action_use_as_base'),
        onPressed: () => actions.useAsBaseImage(context),
      ),
      _ActionButton(
        actionKey: const Key('result-action-inpaint'),
        icon: Icons.brush_outlined,
        label: tr('inpaint_section'),
        onPressed: () => actions.sendToInpaint(context),
      ),
      _ActionButton(
        actionKey: const Key('result-action-director'),
        icon: Icons.auto_fix_high_outlined,
        label: tr('director_tool'),
        onPressed: () => actions.sendToDirectorTools(context),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Evenly weighted row when there is room; wrap on narrow layouts.
        final wide = constraints.maxWidth >= 560;
        if (wide) {
          return Row(
            children: [
              for (final (index, button) in buttons.indexed) ...[
                if (index > 0) const SizedBox(width: 8),
                Expanded(child: button),
              ],
            ],
          );
        }
        return Wrap(spacing: 8, runSpacing: 8, children: buttons);
      },
    );
  }
}

class _ActionButton extends StatelessWidget {
  final Key actionKey;
  final IconData icon;
  final String label;
  final String badge;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.badge = '',
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      key: actionKey,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (badge.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(badge, style: Theme.of(context).textTheme.labelSmall),
            ),
          ],
        ],
      ),
    );
  }
}
