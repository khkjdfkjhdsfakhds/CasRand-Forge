import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';

/// The actions offered on a finished image, mirroring the official result
/// toolbar. Generate Variations and Upscale are deliberately not included.
class ResultActions {
  final InfoCardContent content;

  ResultActions({required this.content});

  PayloadConfig get _payloadConfig => GetIt.I<PayloadConfig>();
  NavigationRequest get _navigation => GetIt.I<NavigationRequest>();

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

  /// Loads the image into the Img2Img config and jumps to that page.
  ///
  /// [carryPromptAndSeed] reproduces the official behaviour of Enhance, which
  /// continues from the same prompt and seed rather than rolling new ones.
  void _sendToI2i(
    BuildContext context, {
    required I2iEntryMode mode,
    required bool carryPromptAndSeed,
  }) {
    final bytes = content.imageBytes;
    if (bytes == null) return;
    final config = _payloadConfig.i2iConfig;
    config.setImage(Uint8List.fromList(bytes));

    if (carryPromptAndSeed) {
      final prompt = sourcePrompt;
      if (prompt != null) {
        _payloadConfig
          ..overridePrompt = prompt
          ..useOverridePrompt = true;
      }
      final seed = sourceSeed;
      if (seed != null) {
        _payloadConfig.paramConfig
          ..seed = seed
          ..randomSeed = false;
      }
    }
    _navigation.goToI2i(mode);
  }

  void useAsBaseImage(BuildContext context) {
    _sendToI2i(context, mode: I2iEntryMode.baseImage, carryPromptAndSeed: false);
    showInfoBar(context, tr('action_use_as_base_done'));
  }

  void sendToInpaint(BuildContext context) {
    _sendToI2i(context, mode: I2iEntryMode.inpaint, carryPromptAndSeed: false);
    showInfoBar(context, tr('action_inpaint_done'));
  }

  void sendToEnhance(BuildContext context) {
    // Enhance continues from the same prompt and seed, like the official one.
    _sendToI2i(context, mode: I2iEntryMode.enhance, carryPromptAndSeed: true);
    showInfoBar(context, tr('action_enhance_done'));
  }

  void sendToDirectorTools(BuildContext context) {
    final bytes = content.imageBytes;
    if (bytes == null) return;
    _payloadConfig.directorToolConfig.setImage(Uint8List.fromList(bytes));
    _navigation.goToI2i(I2iEntryMode.director);
    showInfoBar(context, tr('action_director_done'));
  }

  /// Estimated Anlas for an Enhance run at the given magnification, or null
  /// when the image size is unknown.
  AnlasCost? estimateEnhanceCost(double scale) {
    final width = content.additionalInfo['width'];
    final height = content.additionalInfo['height'];
    if (width is! int || height is! int) return null;
    int snap(int value) => value < 64 ? 64 : (value / 64).round() * 64;
    final targetW = snap((width * scale).round());
    final targetH = snap((height * scale).round());
    final preset = enhancePresets[_payloadConfig.i2iConfig.enhancePresetIndex
        .clamp(0, enhancePresets.length - 1)];
    return estimateAnlasCost(
      width: targetW,
      height: targetH,
      steps: sourceSteps ?? _payloadConfig.paramConfig.steps,
      action: 'img2img',
      strength: preset.strength,
      tier: _payloadConfig.settings.subscriptionTier,
    );
  }
}

/// Formats an Anlas estimate for a toolbar button.
String formatAnlasBadge(AnlasCost? cost) {
  if (cost == null) return '';
  if (cost.isFreeUnderOpus) return tr('anlas_free');
  return cost.anlas.toString();
}

/// Action bar shown above a finished image, mirroring the official result
/// toolbar. Generate Variations and Upscale are intentionally absent.
class ResultActionBar extends StatelessWidget {
  final InfoCardContent content;

  const ResultActionBar({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    final actions = ResultActions(content: content);
    if (!actions.hasImage) return const SizedBox.shrink();
    final enhanceCost = actions.estimateEnhanceCost(1.5);
    final badge = formatAnlasBadge(enhanceCost);

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
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
            ],
          ),
        ),
      ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: TextButton.icon(
        key: actionKey,
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (badge.isNotEmpty) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  badge,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
