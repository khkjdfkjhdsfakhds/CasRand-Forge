import 'package:nai_casrand/ui/parameters_config/widgets/prompt_token_usage.dart';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nai_casrand/core/constants/parameters.dart';
import 'package:nai_casrand/data/services/image_service.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/parameters_config/view_models/parameters_config_viewmodel.dart';
import 'package:nai_casrand/ui/core/widgets/editable_list_tile.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';

class ParametersConfigView extends StatelessWidget {
  final ParametersConfigViewmodel viewmodel;

  const ParametersConfigView({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    final content = ListenableBuilder(
      listenable: Listenable.merge([
        viewmodel,
        viewmodel.payloadConfig,
      ]),
      builder: (context, _) => Column(
        children: [
          _buildModelSelector(context),
          PromptTokenUsage(config: viewmodel.payloadConfig),
          if (viewmodel.isV4) _buildLegacyUcTile(context),
          // Steps
          SliderListTile(
              key: const Key('sampling-steps-control'),
              title: context.tr('sampling_steps') +
                  context.tr('colon') +
                  viewmodel.config.steps.toString(),
              sliderValue: viewmodel.config.steps.toDouble(),
              leading: const Icon(Icons.repeat),
              trailing: const Icon(Icons.edit_outlined),
              min: 0,
              max: 50,
              divisions: 50,
              onTitleTap: () => _showStepsInputDialog(context),
              onChanged: (value) => viewmodel.setSteps(value)),
          // CFG
          SliderListTile(
            title: context.tr('scale') +
                context.tr('colon') +
                viewmodel.config.scale.toStringAsFixed(1),
            sliderValue: viewmodel.config.scale,
            leading: const Icon(Icons.numbers),
            min: 0,
            max: 10,
            divisions: 100,
            onChanged: (value) => viewmodel.setScale(value),
          ),
          SliderListTile(
            leading: const Icon(Icons.numbers),
            title: context.tr('cfg_rescale') +
                context.tr('colon') +
                viewmodel.config.cfgRescale.toStringAsFixed(2),
            min: 0,
            max: 1,
            divisions: 20,
            sliderValue: viewmodel.config.cfgRescale,
            onChanged: (value) => viewmodel.setCfgRescale(value),
          ),
          // Sampler
          SelectableListTile(
              leading: const Icon(Icons.search),
              title: context.tr('sampler'),
              currentValue: viewmodel.config.sampler,
              options: viewmodel.isModern ? samplersV4 : samplers,
              onSelectComplete: (value) => viewmodel.setSampler(value)),
          SelectableListTile(
              leading: const Icon(Icons.search),
              title: context.tr('noise_scheduler'),
              currentValue: viewmodel.config.noiseSchedule,
              options: viewmodel.isV4 ? noiseSchedulesV4 : noiseSchedules,
              onSelectComplete: (value) => viewmodel.setNoiseScheduler(value)),
          // SMEA
          if (!viewmodel.isModern)
            _buildSwitchTile(
              context.tr('sm'),
              viewmodel.config.sm,
              (newValue) => viewmodel.setSm(newValue),
              const Icon(Icons.keyboard_double_arrow_right),
            ),
          if (!viewmodel.isModern)
            _buildSwitchTile(
              context.tr('sm_dyn'),
              viewmodel.config.smDyn,
              (newValue) => viewmodel.setSmDyn(newValue),
              const Icon(Icons.keyboard_double_arrow_right),
            ),
          // Variety+
          _buildSwitchTile(
            context.tr('variety_plus'),
            viewmodel.config.varietyPlus,
            (newValue) => viewmodel.setVarietyPlus(newValue),
            const Icon(Icons.add),
          ),
          // Transparent background is a V5-only tag hint on the official
          // frontend; hide it for legacy models.
          if (viewmodel.isV5)
            _buildSwitchTile(
              context.tr('transparent_background'),
              viewmodel.config.transparentBackground,
              (newValue) => viewmodel.setTransparentBackground(newValue),
              const Icon(Icons.layers_clear),
            ),
        ],
      ),
    );

    final fab = FloatingActionButton(
      tooltip: tr('import_metadata_from_image'),
      onPressed: () => _showImportMetadataDialog(context),
      child: const Icon(Icons.image_outlined),
    );
    return Scaffold(
      floatingActionButton: fab,
      body: SingleChildScrollView(
        child: content,
      ),
    );
  }

  Widget _buildSwitchTile(String title, bool currentValue,
      ValueChanged<bool> onChanged, Icon? icon) {
    return CheckboxListTile(
      secondary: icon,
      title: Text(title),
      value: currentValue,
      onChanged: (value) => onChanged(value!),
    );
  }

  Future<void> _showStepsInputDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _SamplingStepsInputDialog(
        initialValue: viewmodel.config.steps,
        onSubmit: viewmodel.setStepsFromText,
      ),
    );
  }

  Widget _buildModelSelector(BuildContext context) {
    return SelectableListTile(
      title: tr('generation_model'),
      leading: const Icon(Icons.auto_awesome_outlined),
      currentValue: viewmodel.config.model,
      options: models,
      onSelectComplete: (value) => viewmodel.setModel(value),
    );
  }

  Widget _buildLegacyUcTile(BuildContext context) {
    return CheckboxListTile(
      title: Text(tr('legacy_prompt_conditioning_mode')),
      secondary: const Icon(Icons.do_not_disturb),
      value: viewmodel.config.legacyUc,
      onChanged: (value) => viewmodel.setLegacyUc(value),
    );
  }

  Future _showImportMetadataDialog(BuildContext context) async {
    try {
      final picker = ImagePicker();
      final result = await picker.pickImage(source: ImageSource.gallery);
      if (result == null) return;
      final bytes = await result.readAsBytes();
      final metadataString =
          await ImageService().extractMetadataFromBytes(bytes);
      if (!context.mounted) return;
      if (metadataString == null) {
        showErrorBar(context, tr('metadata_not_found'));
        return;
      }
      final jsonData = json.decode(metadataString) as Map<String, dynamic>;
      final commentData =
          json.decode(jsonData['Comment']) as Map<String, dynamic>;
      final source = jsonData['Source'] ?? '';
      final String? model = modelFromSource(source);
      final String? prompt = jsonData['Description'];
      final toolTip = Padding(
        padding: const EdgeInsets.only(left: 8.0),
        child: Text(tr('tap_to_paste_parameters')),
      );
      final promptTile = prompt != null
          ? ListTile(
              title: Text(tr('prompt')),
              subtitle: Text(prompt),
              onTap: () => viewmodel.setOverridePrompt(context, prompt),
            )
          : const SizedBox.shrink();
      final modelTile = model != null
          ? ListTile(
              title: Text(tr('generation_model')),
              subtitle: Text(model),
              onTap: () => viewmodel.setModelFromMetadata(context, model),
            )
          : const SizedBox.shrink();
      final sizeTile = ListTile(
        title: Text(tr('image_size')),
        subtitle: Text(
          '${commentData['width']} × ${commentData['height']}',
        ),
        dense: true,
        onTap: () => viewmodel.loadSingleImageMetadata(
          context,
          {'width': commentData['width'], 'height': commentData['height']},
          tr('image_size'),
        ),
      );
      final tiles = commentKeys.map((key) {
        final value = commentData[key];
        if (value == null) return const SizedBox.shrink();
        return ListTile(
          title: Text(key),
          subtitle: Text(
            value.toString(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          dense: true,
          onTap: () =>
              viewmodel.loadSingleImageMetadata(context, {key: value}, key),
        );
      }).toList();
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(tr('metadata_found')),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                toolTip,
                promptTile,
                modelTile,
                sizeTile,
                ...tiles,
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('cancel')),
            ),
            TextButton(
                onPressed: () {
                  viewmodel.loadAllMetadata(
                    context,
                    commentData,
                    prompt,
                    model,
                  );
                  Navigator.pop(context);
                },
                child: Text(tr('import_all_metadata_from_image')))
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      showErrorBar(
          context, '${tr('import_metadata_from_image')}${tr('failed')}');
    }
  }
}

class _SamplingStepsInputDialog extends StatefulWidget {
  final int initialValue;
  final ValueChanged<String> onSubmit;

  const _SamplingStepsInputDialog({
    required this.initialValue,
    required this.onSubmit,
  });

  @override
  State<_SamplingStepsInputDialog> createState() =>
      _SamplingStepsInputDialogState();
}

class _SamplingStepsInputDialogState extends State<_SamplingStepsInputDialog> {
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initialValue.toString());
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    widget.onSubmit(controller.text);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        '${context.tr('edit')}${context.tr('colon')}'
        '${context.tr('sampling_steps')}',
      ),
      content: TextField(
        key: const Key('sampling-steps-input'),
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(helperText: '0–50'),
        onSubmitted: (_) => submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('cancel')),
        ),
        TextButton(
          onPressed: submit,
          child: Text(context.tr('confirm')),
        ),
      ],
    );
  }
}
