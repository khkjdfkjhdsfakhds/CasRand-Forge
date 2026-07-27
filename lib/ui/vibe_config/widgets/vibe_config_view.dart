import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/ui/vibe_config/view_models/vibe_config_viewmodel.dart';

class VibeConfigView extends StatelessWidget {
  final VibeConfigViewmodel viewmodel;
  final VoidCallback? onDelete;

  const VibeConfigView({
    super.key,
    required this.viewmodel,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final widgetImage = SizedBox(
        height: 120.0,
        width: 120.0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8.0),
          child: Image.memory(
            base64Decode(viewmodel.config.imageB64),
          ),
        ));

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
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value:
                                  viewmodel.referenceStrength.clamp(0.0, 1.0),
                              min: 0.0,
                              max: 1.0,
                              divisions: 100,
                              label: viewmodel.referenceStrength
                                  .toStringAsFixed(2),
                              onChanged: (value) =>
                                  viewmodel.setReferenceStrength(value),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_note), // Changed icon
                            tooltip: "Edit Strength Value",
                            onPressed: () => _showEditReferenceStrengthDialog(
                                context, viewmodel),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Info extracted
                      Text(
                          'Information extracted: ${viewmodel.infoExtracted.toStringAsFixed(2)}'),
                      Row(children: [
                        Expanded(
                          child: Slider(
                            value: viewmodel.infoExtracted.clamp(0.0, 1.0),
                            min: 0.0,
                            max: 1.0,
                            divisions: 100,
                            label: viewmodel.infoExtracted.toStringAsFixed(2),
                            onChanged: (value) =>
                                viewmodel.setInfoExtracted(value),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_note), // Changed icon
                          tooltip: "Edit Information Extracted",
                          onPressed: () =>
                              _showEditInfoExtractedDialog(context, viewmodel),
                        )
                      ]),
                    ],
                  )),
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
        });
  }

  void _showEditReferenceStrengthDialog(
      BuildContext context, VibeConfigViewmodel vm) {
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

  void _showEditInfoExtractedDialog(
      BuildContext context, VibeConfigViewmodel vm) {
    showSliderValueInputDialog(
      context: context,
      title: 'Information extracted',
      value: vm.infoExtracted,
      min: 0,
      max: 1,
      divisions: 100,
      decimalPlaces: 2,
      onChanged: vm.setInfoExtracted,
    );
  }
}
