import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class VibeConfigV4ListViewmodel extends ChangeNotifier {
  static const imageExtensions = {'png', 'jpg', 'jpeg', 'webp'};
  static const vibeExtensions = {'naiv4vibe', 'naiv4vibebundle'};

  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  List<VibeConfigV4> get vibeList => payloadConfig.vibeConfigListV4;
  bool get featureEnabled => payloadConfig.vibeEnabled;
  int get nSamples => payloadConfig.paramConfig.nSamples;
  String get currentModel => payloadConfig.paramConfig.model;

  int get pendingEncodingCount => vibeList
      .where((config) =>
          config.canEncode && config.encodingFor(currentModel) == null)
      .length;

  int get unavailableEncodingCount => vibeList
      .where((config) =>
          !config.canEncode && config.encodingFor(currentModel) == null)
      .length;

  int get estimatedEncodingAnlas => pendingEncodingCount * 2;

  int get estimatedExtraAnlas => featureEnabled
      ? (vibeList.length > freeVibeCount
              ? vibeList.length - freeVibeCount
              : 0) *
          extraVibeAnlas *
          nSamples
      : 0;

  void setFeatureEnabled(bool value) {
    payloadConfig.setVibeEnabled(value);
    notifyListeners();
  }

  void notifyConfigChanged() => notifyListeners();

  Future<void> pickAndAddNewConfig(
    BuildContext context, {
    double initialReferenceStrength = 0.6,
    double initialInformationExtracted = 0.7,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          ...imageExtensions,
          ...vibeExtensions,
        ],
        withData: true,
      );
      if (result == null || result.files.single.bytes == null) return;
      final file = result.files.single;
      final count = addVibeBytes(
        file.bytes!,
        file.name,
        initialReferenceStrength: initialReferenceStrength,
        initialInformationExtracted: initialInformationExtracted,
      );
      if (!context.mounted) return;
      showInfoBar(
        context,
        count == 1
            ? 'Added ${file.name} as a Vibe reference.'
            : 'Added $count Vibes from ${file.name}.',
      );
    } catch (error) {
      if (!context.mounted) return;
      showErrorBar(context, 'Could not add Vibe reference: $error');
    }
  }

  int addVibeBytes(
    Uint8List fileBytes,
    String fileName, {
    double initialReferenceStrength = 0.6,
    double initialInformationExtracted = 0.7,
  }) {
    final extension = _extensionOf(fileName);
    final wasEmpty = !payloadConfig.hasVibeResources;
    final added = <VibeConfigV4>[];

    if (imageExtensions.contains(extension)) {
      final count = payloadConfig.addVibeImage(
        fileBytes,
        fileName,
        referenceStrength: initialReferenceStrength,
        informationExtracted: initialInformationExtracted,
      );
      notifyListeners();
      return count;
    } else if (extension == 'naiv4vibe') {
      added.add(
        VibeConfigV4.fromNaiV4VibeJson(
          fileName,
          _decodeJsonObject(fileBytes, fileName),
          initialReferenceStrength,
          defaultInformationExtracted: initialInformationExtracted,
        ),
      );
    } else if (extension == 'naiv4vibebundle') {
      final bundle = _decodeJsonObject(fileBytes, fileName);
      final entries = bundle['vibes'];
      if (entries is! List || entries.isEmpty) {
        throw const FormatException(
          'The .naiv4vibebundle file does not contain any Vibes.',
        );
      }
      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        if (entry is! Map) continue;
        try {
          added.add(
            VibeConfigV4.fromNaiV4VibeJson(
              '$fileName#$index',
              entry.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
              initialReferenceStrength,
              defaultInformationExtracted: initialInformationExtracted,
            ),
          );
        } catch (error) {
          if (kDebugMode) {
            debugPrint('Skipped invalid Vibe bundle entry $index: $error');
          }
        }
      }
      if (added.isEmpty) {
        throw const FormatException(
          'The .naiv4vibebundle file contains no usable Vibes.',
        );
      }
    } else {
      throw const FormatException(
        'Unsupported file type. Use PNG, JPG, WebP, .naiv4vibe, or '
        '.naiv4vibebundle.',
      );
    }

    vibeList.addAll(added);
    payloadConfig.noteVibeImported(wasEmpty: wasEmpty);
    notifyListeners();
    return added.length;
  }

  Future<void> handleVibeDropEvent(
    BuildContext context,
    PerformDropEvent event,
  ) async {
    final item = event.session.items.first;
    final reader = item.dataReader;
    if (reader == null) return;
    reader.getFile(null, (file) async {
      try {
        final bytes = await file.readAll();
        final fileName = file.fileName ?? 'Imported Vibe.png';
        final count = addVibeBytes(bytes, fileName);
        if (!context.mounted) return;
        showInfoBar(
          context,
          count == 1
              ? 'Added $fileName as a Vibe reference.'
              : 'Added $count Vibes.',
        );
      } catch (error) {
        if (!context.mounted) return;
        showErrorBar(context, 'Could not add Vibe reference: $error');
      }
    });
  }

  void removeConfigAtIndex(int index) {
    if (index < 0 || index >= vibeList.length) return;
    vibeList.removeAt(index);
    if (!payloadConfig.hasVibeResources) {
      payloadConfig.clearVibeResourceState();
    }
    notifyListeners();
  }

  static String _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }

  static Map<String, dynamic> _decodeJsonObject(
    Uint8List bytes,
    String fileName,
  ) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw FormatException("'$fileName' is not a valid Vibe JSON object.");
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }
}
