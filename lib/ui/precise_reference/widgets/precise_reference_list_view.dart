import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/ui/core/utils/platform_support.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';
import 'package:nai_casrand/ui/precise_reference/view_models/precise_reference_list_viewmodel.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class PreciseReferenceListView extends StatelessWidget {
  final PreciseReferenceListViewmodel viewmodel;

  const PreciseReferenceListView({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([viewmodel, viewmodel.payloadConfig]),
      builder: (context, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            if (!viewmodel.isSupported) _buildUnsupportedNotice(context),
            if (viewmodel.featureEnabled && viewmodel.activeReferenceCount > 0)
              _buildCostNotice(context),
            if (viewmodel.activeReferenceCount > 0 &&
                viewmodel.activeVibeCount > 0)
              _buildVibeConflictNotice(context),
            for (final (index, config) in viewmodel.referenceList.indexed)
              _PreciseReferenceCard(
                config: config,
                enabled: viewmodel.isSupported,
                onDelete: () => viewmodel.removeConfigAtIndex(index),
                onEnabledChanged: (value) =>
                    viewmodel.setEnabled(config, value),
                onTypeChanged: (value) => viewmodel.setType(config, value),
                onStrengthChanged: (value) =>
                    viewmodel.setStrength(config, value),
                onFidelityChanged: (value) =>
                    viewmodel.setFidelity(config, value),
              ),
            _buildDropArea(context),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Card(
      key: const Key('precise-reference-section'),
      margin: const EdgeInsets.fromLTRB(4.0, 16.0, 4.0, 8.0),
      child: ListTile(
        leading: const Icon(Icons.center_focus_strong),
        title: Text(context.tr('precise_reference')),
        subtitle: Text(context.tr('precise_reference_page_tip')),
        trailing: Switch(
          key: const Key('precise-reference-feature-switch'),
          value: viewmodel.featureEnabled,
          onChanged: viewmodel.referenceList.isEmpty || !viewmodel.isSupported
              ? null
              : (value) {
                  final disabledVibe =
                      value && viewmodel.payloadConfig.vibeEnabled;
                  viewmodel.setFeatureEnabled(value);
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
                },
        ),
      ),
    );
  }

  Widget _buildUnsupportedNotice(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 4.0),
      child: ListTile(
        leading: const Icon(Icons.info_outline),
        title: Text(context.tr('precise_reference_v45_only')),
      ),
    );
  }

  Widget _buildCostNotice(BuildContext context) {
    return Card(
      color: Colors.amber.withAlpha(44),
      margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 4.0),
      child: ListTile(
        leading: const Icon(Icons.local_fire_department_outlined),
        title: Text(context.tr(
          'precise_reference_cost_notice',
          namedArgs: {
            'reference_count': viewmodel.activeReferenceCount.toString(),
            'n_samples': viewmodel.nSamples.toString(),
            'anlas': viewmodel.estimatedExtraAnlas.toString(),
          },
        )),
      ),
    );
  }

  Widget _buildVibeConflictNotice(BuildContext context) {
    return Card(
      color: Colors.orange.withAlpha(38),
      margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 4.0),
      child: ListTile(
        leading: const Icon(Icons.sync_problem),
        title: Text(context.tr('precise_reference_vibe_conflict_notice')),
      ),
    );
  }

  Widget _buildDropArea(BuildContext context) {
    final content = Opacity(
      opacity: viewmodel.isSupported ? 1.0 : 0.45,
      child: InkWell(
        onTap: viewmodel.isSupported
            ? () => viewmodel.pickAndAddNewReference(context)
            : null,
        child: Card(
          margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.add_photo_alternate_outlined,
                  size: 100.0,
                  color: Colors.grey.withAlpha(127),
                ),
                Text(context.tr('precise_reference_add')),
              ],
            ),
          ),
        ),
      ),
    );

    if (!supportsSuperNativeExtensions || !viewmodel.isSupported) {
      return content;
    }
    return DropRegion(
      formats: Formats.standardFormats,
      onDropOver: (_) => DropOperation.copy,
      onPerformDrop: (event) =>
          viewmodel.handleReferenceDropEvent(context, event),
      child: content,
    );
  }
}

class _PreciseReferenceCard extends StatelessWidget {
  final PreciseReferenceConfig config;
  final bool enabled;
  final VoidCallback onDelete;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<PreciseReferenceType> onTypeChanged;
  final ValueChanged<double> onStrengthChanged;
  final ValueChanged<double> onFidelityChanged;

  const _PreciseReferenceCard({
    required this.config,
    required this.enabled,
    required this.onDelete,
    required this.onEnabledChanged,
    required this.onTypeChanged,
    required this.onStrengthChanged,
    required this.onFidelityChanged,
  });

  @override
  Widget build(BuildContext context) {
    final thumbnail = Image.memory(
      base64Decode(config.imageB64),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );

    return Opacity(
      opacity: enabled && config.enabled ? 1.0 : 0.55,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 120.0,
                width: 120.0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8.0),
                  child: thumbnail,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            config.fileName,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Switch(
                          value: config.enabled,
                          onChanged: enabled
                              ? (value) => onEnabledChanged(value)
                              : null,
                        ),
                      ],
                    ),
                    DropdownButton<PreciseReferenceType>(
                      value: config.type,
                      isExpanded: true,
                      onChanged: enabled
                          ? (value) {
                              if (value != null) onTypeChanged(value);
                            }
                          : null,
                      items: PreciseReferenceType.values
                          .map(
                            (type) => DropdownMenuItem(
                              value: type,
                              child: Text(type.displayName),
                            ),
                          )
                          .toList(),
                    ),
                    _buildSliderRow(
                      context: context,
                      title: context.tr('precise_reference_strength'),
                      value: config.strength,
                      onChanged: enabled ? onStrengthChanged : null,
                    ),
                    _buildSliderRow(
                      context: context,
                      title: context.tr('precise_reference_fidelity'),
                      value: config.fidelity,
                      onChanged: enabled ? onFidelityChanged : null,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, color: Colors.red[700]),
                tooltip: context.tr('precise_reference_delete'),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSliderRow({
    required BuildContext context,
    required String title,
    required double value,
    required ValueChanged<double>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title: ${value.toStringAsFixed(2)}'),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: value.clamp(0.0, 1.0),
                min: 0.0,
                max: 1.0,
                divisions: 100,
                label: value.toStringAsFixed(2),
                onChanged: onChanged,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit_note),
              tooltip: title,
              onPressed: onChanged == null
                  ? null
                  : () => _showEditValueDialog(
                        context,
                        title,
                        value,
                        onChanged,
                      ),
            ),
          ],
        ),
      ],
    );
  }

  void _showEditValueDialog(
    BuildContext context,
    String title,
    double value,
    ValueChanged<double> onChanged,
  ) {
    showSliderValueInputDialog(
      context: context,
      title: title,
      value: value,
      min: 0,
      max: 1,
      divisions: 100,
      decimalPlaces: 2,
      onChanged: onChanged,
    );
  }
}
