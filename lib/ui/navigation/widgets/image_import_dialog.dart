import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/core/constants/parameters.dart';
import 'package:nai_casrand/data/models/image_import_capabilities.dart';
import 'package:nai_casrand/data/models/metadata_import_options.dart';
import 'package:nai_casrand/ui/navigation/view_models/metadata_drop_area_viewmodel.dart';

typedef ImageMetadataExtractor = Future<String?> Function(Uint8List bytes);
typedef ImageImportCandidateLoader = Future<ImageImportCandidate> Function();

class ImageImportCandidate {
  final Uint8List bytes;
  final String fileName;
  final Map<String, dynamic>? metadata;
  final String? prompt;
  final String? model;
  final Object? metadataError;

  const ImageImportCandidate({
    required this.bytes,
    required this.fileName,
    this.metadata,
    this.prompt,
    this.model,
    this.metadataError,
  });

  bool get hasMetadata => metadata != null;
  bool get hasUnrecognizedModel => metadata != null && model == null;

  bool get hasUnrecoverableGenerationInputs {
    final value = metadata;
    if (value == null) return false;
    const referenceFields = {
      'reference_strength_multiple',
      'reference_information_extracted_multiple',
      'director_reference_descriptions',
      'director_reference_information_extracted',
      'director_reference_strengths',
      'director_reference_strength_values',
      'director_reference_secondary_strengths',
      'director_reference_secondary_strength_values',
    };
    for (final field in referenceFields) {
      final item = value[field];
      if (item is List && item.isNotEmpty) return true;
    }
    if (value['strength'] is num ||
        value['noise'] is num ||
        value['inpaintImg2ImgStrength'] is num) {
      return true;
    }
    final requestType = value['request_type']?.toString().toLowerCase() ?? '';
    return requestType.contains('img2img') ||
        requestType.contains('image2image') ||
        requestType.contains('inpaint');
  }

  static Future<ImageImportCandidate> fromImageBytes({
    required Uint8List bytes,
    required String fileName,
    required ImageMetadataExtractor extractMetadata,
  }) async {
    try {
      final metadataString = await extractMetadata(bytes);
      if (metadataString == null || metadataString.trim().isEmpty) {
        return ImageImportCandidate(bytes: bytes, fileName: fileName);
      }
      final envelope = jsonDecode(metadataString);
      if (envelope is! Map) {
        throw const FormatException('NovelAI metadata is not an object.');
      }
      final normalizedEnvelope = envelope.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final rawComment = normalizedEnvelope['Comment'];
      final decodedComment =
          rawComment is String ? jsonDecode(rawComment) : rawComment;
      if (decodedComment is! Map) {
        throw const FormatException('NovelAI Comment metadata is invalid.');
      }
      final metadata = decodedComment.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final source = normalizedEnvelope['Source']?.toString() ?? '';
      final description = normalizedEnvelope['Description'];
      return ImageImportCandidate(
        bytes: bytes,
        fileName: fileName,
        metadata: metadata,
        prompt: description is String ? description : null,
        model: modelFromSource(source),
        metadataError: _metadataShapeError(
          metadata,
          description: description,
        ),
      );
    } catch (error) {
      return ImageImportCandidate(
        bytes: bytes,
        fileName: fileName,
        metadataError: error,
      );
    }
  }

  static FormatException? _metadataShapeError(
    Map<String, dynamic> metadata, {
    Object? description,
  }) {
    if (description != null && description is! String) {
      return const FormatException('Description metadata is not text.');
    }
    const numericFields = {
      'steps',
      'scale',
      'cfg_rescale',
      'width',
      'height',
      'seed',
      'n_samples',
    };
    for (final field in numericFields) {
      final value = metadata[field];
      if (value != null && value is! num) {
        return FormatException('$field metadata is not numeric.');
      }
    }
    const boolFields = {
      'random_seed',
      'qualityToggle',
      'sm',
      'sm_dyn',
      'dynamic_thresholding',
      'legacy',
      'add_original_image',
    };
    for (final field in boolFields) {
      final value = metadata[field];
      if (value != null && value is! bool) {
        return FormatException('$field metadata is not a true/false value.');
      }
    }
    return null;
  }
}

Future<void> showImageImportDialog(
  BuildContext context, {
  required ImageImportCandidate candidate,
  required MetadataDropAreaViewmodel viewmodel,
  ImageImportCandidateLoader? metadataLoader,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ImageImportDialog(
      candidate: candidate,
      viewmodel: viewmodel,
      metadataLoader: metadataLoader,
    ),
  );
}

class ImageImportDialog extends StatefulWidget {
  final ImageImportCandidate candidate;
  final MetadataDropAreaViewmodel viewmodel;
  final ImageImportCandidateLoader? metadataLoader;

  const ImageImportDialog({
    super.key,
    required this.candidate,
    required this.viewmodel,
    this.metadataLoader,
  });

  @override
  State<ImageImportDialog> createState() => _ImageImportDialogState();
}

class _ImageImportDialogState extends State<ImageImportDialog> {
  bool _busy = false;
  bool _allowClose = false;
  bool _metadataLoading = false;
  Object? _error;
  late ImageImportCandidate _candidate;
  late MetadataImportAvailability _metadataAvailability;
  late bool _importPrompt;
  late bool _importUndesired;
  late bool _importCharacters;
  late bool _importSettings;
  late bool _importSeed;
  bool _append = false;
  bool _cleanImports = false;

  @override
  void initState() {
    super.initState();
    _candidate = widget.candidate;
    _refreshMetadataAvailability();
    if (widget.metadataLoader != null) {
      _metadataLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMetadata());
    }
  }

  void _refreshMetadataAvailability() {
    final metadata = _candidate.metadata;
    _metadataAvailability = metadata == null
        ? const MetadataImportAvailability(
            prompt: false,
            undesiredContent: false,
            characters: false,
            settings: false,
            seed: false,
          )
        : widget.viewmodel.metadataImportAvailability(
            metadata,
            prompt: _candidate.prompt,
            model: _candidate.model,
          );
    _importPrompt = _metadataAvailability.prompt;
    _importUndesired = _metadataAvailability.undesiredContent;
    _importCharacters = _metadataAvailability.characters;
    _importSettings = _metadataAvailability.settings;
    _importSeed = _metadataAvailability.seed;
  }

  Future<void> _loadMetadata() async {
    try {
      final candidate = await widget.metadataLoader!();
      if (!mounted) return;
      setState(() {
        _candidate = candidate;
        _metadataLoading = false;
        _refreshMetadataAvailability();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _candidate = ImageImportCandidate(
          bytes: _candidate.bytes,
          fileName: _candidate.fileName,
          metadataError: error,
        );
        _metadataLoading = false;
        _refreshMetadataAvailability();
      });
    }
  }

  Future<void> _runAction(Future<bool> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await WidgetsBinding.instance.endOfFrame;
      final accepted = await action();
      if (!accepted) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      if (!mounted) return;
      setState(() => _allowClose = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (kDebugMode) debugPrint('Image import action failed: $error');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  Future<void> _useAsImageToImage() => _runAction(
        () async => widget.viewmodel.useAsImageToImage(
          _candidate.bytes,
        ),
      );

  Future<void> _useAsInpaint() => _runAction(
        () async => widget.viewmodel.useAsInpaint(
          _candidate.bytes,
        ),
      );

  Future<void> _useAsVibeTransfer() => _runAction(
        () => widget.viewmodel.useAsVibeTransfer(
          _candidate.bytes,
          _candidate.fileName,
        ),
      );

  Future<void> _useAsPreciseReference() => _runAction(
        () => widget.viewmodel.useAsPreciseReference(
          _candidate.bytes,
          _candidate.fileName,
        ),
      );

  bool get _hasSelectedMetadata =>
      _importPrompt ||
      _importUndesired ||
      _importCharacters ||
      _importSettings ||
      _importSeed;

  Future<void> _importMetadata() => _runAction(() async {
        final metadata = _candidate.metadata;
        if (metadata == null) return false;
        return widget.viewmodel.importSelectedMetadata(
              context,
              metadata,
              prompt: _candidate.prompt,
              model: _candidate.model,
              options: MetadataImportOptions(
                prompt: _importPrompt,
                undesiredContent: _importUndesired,
                characters: _importCharacters,
                settings: _importSettings,
                seed: _importSeed,
                append: _append,
                cleanImports: _cleanImports,
              ),
            ) >
            0;
      });

  @override
  Widget build(BuildContext context) {
    final capabilities = widget.viewmodel.imageImportCapabilities;
    return PopScope(
      canPop: !_busy || _allowClose,
      child: AlertDialog(
        title: Text(context.tr('image_import_title')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  label: context.tr('image_import_preview'),
                  image: true,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: Image.memory(
                      _candidate.bytes,
                      key: const Key('image-import-preview'),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (capabilities.supports(ImageImportAction.imageToImage))
                      FilledButton.icon(
                        key: const Key('image-import-i2i'),
                        onPressed: _busy ? null : _useAsImageToImage,
                        icon: const Icon(Icons.image_outlined),
                        label: Text(context.tr('image_import_image_to_image')),
                      ),
                    if (capabilities.supports(ImageImportAction.inpaint))
                      FilledButton.icon(
                        key: const Key('image-import-inpaint'),
                        onPressed: _busy ? null : _useAsInpaint,
                        icon: const Icon(Icons.brush_outlined),
                        label: Text(context.tr('inpaint_section')),
                      ),
                    if (capabilities.supports(ImageImportAction.vibeTransfer))
                      FilledButton.icon(
                        key: const Key('image-import-vibe'),
                        onPressed: _busy ? null : _useAsVibeTransfer,
                        icon: const Icon(Icons.auto_awesome_motion_outlined),
                        label: Text(context.tr('image_import_vibe_transfer')),
                      ),
                    if (capabilities
                        .supports(ImageImportAction.preciseReference))
                      FilledButton.icon(
                        key: const Key('image-import-precise-reference'),
                        onPressed: _busy ? null : _useAsPreciseReference,
                        icon: const Icon(Icons.center_focus_strong),
                        label: Text(context.tr('precise_reference')),
                      ),
                  ],
                ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(
                    key: Key('image-import-action-loading'),
                  ),
                ],
                if (_metadataLoading) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(
                    key: Key('image-import-metadata-loading'),
                  ),
                ],
                if (_candidate.hasMetadata && _metadataAvailability.hasAny) ...[
                  const SizedBox(height: 24),
                  _buildMetadataSection(context),
                ],
                if (_candidate.metadataError != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(context.tr('image_import_metadata_invalid')),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    context.tr('image_import_action_failed'),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(context.tr('cancel')),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataSection(BuildContext context) {
    final hasPromptCategories = _metadataAvailability.prompt ||
        _metadataAvailability.undesiredContent ||
        _metadataAvailability.characters;
    return Card(
      key: const Key('image-import-metadata-section'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr('image_import_metadata_found'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Container(
              key: const Key('image-import-fixed-mode-warning'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.push_pin_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.tr('image_import_fixed_mode_warning'),
                    ),
                  ),
                ],
              ),
            ),
            if (_candidate.hasUnrecoverableGenerationInputs) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('image-import-unrecoverable-input-warning'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_outlined, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.tr('image_import_unrecoverable_input_warning'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_candidate.hasUnrecognizedModel) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('image-import-unknown-model-warning'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_outlined, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.tr('image_import_unknown_model_warning'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_metadataAvailability.prompt)
              _metadataCheckbox(
                key: const Key('metadata-import-prompt'),
                label: context.tr('image_import_prompt'),
                value: _importPrompt,
                onChanged: (value) => _importPrompt = value,
              ),
            if (_metadataAvailability.undesiredContent)
              _metadataCheckbox(
                key: const Key('metadata-import-undesired'),
                label: context.tr('image_import_undesired_content'),
                value: _importUndesired,
                onChanged: (value) => _importUndesired = value,
              ),
            if (_metadataAvailability.characters)
              _metadataCheckbox(
                key: const Key('metadata-import-characters'),
                label: context.tr('image_import_characters'),
                value: _importCharacters,
                onChanged: (value) => _importCharacters = value,
              ),
            if (_metadataAvailability.settings)
              _metadataCheckbox(
                key: const Key('metadata-import-settings'),
                label: context.tr('image_import_settings'),
                value: _importSettings,
                onChanged: (value) => _importSettings = value,
              ),
            if (_metadataAvailability.seed)
              _metadataCheckbox(
                key: const Key('metadata-import-seed'),
                label: context.tr('image_import_seed'),
                value: _importSeed,
                onChanged: (value) => _importSeed = value,
              ),
            if (hasPromptCategories) ...[
              SwitchListTile(
                key: const Key('metadata-import-append'),
                contentPadding: EdgeInsets.zero,
                title: Text(context.tr('image_import_append')),
                value: _append,
                onChanged:
                    _busy ? null : (value) => setState(() => _append = value),
              ),
              SwitchListTile(
                key: const Key('metadata-import-clean'),
                contentPadding: EdgeInsets.zero,
                title: Text(context.tr('image_import_clean_imports')),
                subtitle: Text(context.tr('image_import_clean_imports_hint')),
                value: _cleanImports,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _cleanImports = value),
              ),
            ],
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('metadata-import-confirm'),
              onPressed:
                  _busy || !_hasSelectedMetadata ? null : _importMetadata,
              icon: const Icon(Icons.download_done_outlined),
              label: Text(context.tr('image_import_metadata_confirm')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metadataCheckbox({
    required Key key,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return CheckboxListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(label),
      value: value,
      onChanged:
          _busy ? null : (next) => setState(() => onChanged(next ?? false)),
    );
  }
}
