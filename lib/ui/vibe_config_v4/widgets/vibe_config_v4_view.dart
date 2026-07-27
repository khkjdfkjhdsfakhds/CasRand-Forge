import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';

import '../viewmodels/vibe_config_v4_viewmodel.dart';

class VibeConfigV4View extends StatelessWidget {
  final VibeConfigV4Viewmodel viewmodel;
  final VoidCallback? onDelete; // Callback for delete action

  const VibeConfigV4View({
    super.key,
    required this.viewmodel,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    // Changed Object to BuildContext
    final thumbnail = viewmodel.imageBytes != null
        ? Image.memory(viewmodel.imageBytes!, fit: BoxFit.cover)
        : const Icon(Icons.broken_image_outlined, size: 50);

    final widgetImage = SizedBox(
      height: 120.0, // Adjusted size for better fit in a list
      width: 120.0,
      child: ClipRRect(
        // Optional: to make image have rounded corners
        borderRadius: BorderRadius.circular(8.0),
        child: thumbnail,
      ),
    );

    return ListenableBuilder(
      listenable: viewmodel,
      builder: (context, child) {
        return Card(
          // Wrap with Card for better visual separation
          margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                widgetImage,
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Text(
                        viewmodel.fileName,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      // Reference Strength
                      Text(
                          'Strength: ${viewmodel.referenceStrength.toStringAsFixed(2)}'),
                      Row(children: [
                        Expanded(
                          child: Slider(
                            value: viewmodel.referenceStrength.clamp(0.0, 1.0),
                            min: 0.0,
                            max: 1.0,
                            divisions: 100,
                            label:
                                viewmodel.referenceStrength.toStringAsFixed(2),
                            onChanged: (value) =>
                                viewmodel.setReferenceStrength(value),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_note), // Changed icon
                          tooltip: "Edit Strength Value",
                          onPressed: () => _showEditReferenceStrengthDialog(
                              context, viewmodel),
                        )
                      ]),
                    ],
                  ),
                ),
                if (onDelete !=
                    null) // Show delete button only if callback is provided
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: Colors.red[700]),
                    tooltip: "Delete Vibe Config",
                    onPressed: onDelete,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showEditReferenceStrengthDialog(
      BuildContext context, VibeConfigV4Viewmodel vm) {
    showSliderValueInputDialog(
      context: context,
      title: 'Strength',
      value: vm.referenceStrength,
      min: 0,
      max: 1,
      divisions: 100,
      decimalPlaces: 2,
      onChanged: vm.setReferenceStrength,
    );
  }
}
