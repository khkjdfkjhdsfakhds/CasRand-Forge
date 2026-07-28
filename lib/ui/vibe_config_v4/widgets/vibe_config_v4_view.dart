import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';

import '../viewmodels/vibe_config_v4_viewmodel.dart';

class VibeConfigV4View extends StatelessWidget {
  final VibeConfigV4Viewmodel viewmodel;
  final VoidCallback? onDelete;

  const VibeConfigV4View({
    super.key,
    required this.viewmodel,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewmodel,
      builder: (context, child) {
        final imageBytes = viewmodel.imageBytes;
        final thumbnail = imageBytes != null
            ? Image.memory(
                imageBytes,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.broken_image_outlined, size: 50),
              )
            : const Icon(Icons.auto_awesome_outlined, size: 50);

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 120,
                  width: 120,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: thumbnail,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        viewmodel.fileName,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      _EncodingStatus(viewmodel: viewmodel),
                      const SizedBox(height: 8),
                      _VibeSlider(
                        title: context.tr('vibe_reference_strength'),
                        value: viewmodel.referenceStrength,
                        keyPrefix: 'vibe-reference-strength',
                        onChanged: viewmodel.setReferenceStrength,
                        onEdit: () => _showReferenceStrengthDialog(context),
                      ),
                      _VibeSlider(
                        title: context.tr('vibe_information_extracted'),
                        value: viewmodel.informationExtracted,
                        keyPrefix: 'vibe-information-extracted',
                        onChanged: viewmodel.setInformationExtracted,
                        onEdit: () => _showInformationExtractedDialog(context),
                      ),
                    ],
                  ),
                ),
                if (onDelete != null)
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: Colors.red[700]),
                    tooltip: context.tr('vibe_delete'),
                    onPressed: onDelete,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showReferenceStrengthDialog(BuildContext context) {
    showSliderValueInputDialog(
      context: context,
      title: context.tr('vibe_reference_strength'),
      value: viewmodel.referenceStrength,
      min: 0,
      max: 1,
      divisions: 100,
      decimalPlaces: 2,
      onChanged: viewmodel.setReferenceStrength,
    );
  }

  void _showInformationExtractedDialog(BuildContext context) {
    showSliderValueInputDialog(
      context: context,
      title: context.tr('vibe_information_extracted'),
      value: viewmodel.informationExtracted,
      min: 0,
      max: 1,
      divisions: 100,
      decimalPlaces: 2,
      onChanged: viewmodel.setInformationExtracted,
    );
  }
}

class _EncodingStatus extends StatelessWidget {
  final VibeConfigV4Viewmodel viewmodel;

  const _EncodingStatus({required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = viewmodel.encodingReady
        ? (
            Icons.check_circle_outline,
            Colors.green,
            context.tr('vibe_encoding_ready'),
          )
        : viewmodel.canEncode
            ? (
                Icons.pending_outlined,
                Colors.orange,
                context.tr('vibe_encoding_pending'),
              )
            : (
                Icons.error_outline,
                Colors.red,
                context.tr('vibe_encoding_unavailable'),
              );
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _VibeSlider extends StatelessWidget {
  final String title;
  final double value;
  final String keyPrefix;
  final ValueChanged<double> onChanged;
  final VoidCallback onEdit;

  const _VibeSlider({
    required this.title,
    required this.value,
    required this.keyPrefix,
    required this.onChanged,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: Key('$keyPrefix-label'),
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('$title: ${value.toStringAsFixed(2)}'),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Slider(
                key: Key('$keyPrefix-slider'),
                value: value.clamp(0.0, 1.0),
                min: 0,
                max: 1,
                divisions: 100,
                label: value.toStringAsFixed(2),
                onChanged: onChanged,
              ),
            ),
            IconButton(
              key: Key('$keyPrefix-edit'),
              icon: const Icon(Icons.edit_note),
              tooltip: context.tr('edit_value'),
              onPressed: onEdit,
            ),
          ],
        ),
      ],
    );
  }
}
