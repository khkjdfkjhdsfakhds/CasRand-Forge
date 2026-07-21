import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class PreciseReferenceListViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  List<PreciseReferenceConfig> get referenceList =>
      payloadConfig.preciseReferenceConfigList;

  bool get isSupported => payloadConfig.paramConfig.model.contains('-4-5-');
  int get nSamples => payloadConfig.paramConfig.nSamples;
  int get activeReferenceCount =>
      referenceList.where((config) => config.enabled).length;
  int get activeVibeCount => payloadConfig.vibeConfigListV4.length;
  int get estimatedExtraAnlas => activeReferenceCount * nSamples * 5;

  Future<void> pickAndAddNewReference(BuildContext context) async {
    if (!isSupported) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        withData: true,
      );
      if (result == null || result.files.single.bytes == null) return;
      final file = result.files.single;
      await addReferenceBytes(file.bytes!, file.name);
      if (!context.mounted) return;
      showInfoBar(context, 'Added ${file.name} as Precise Reference.');
    } catch (err) {
      if (!context.mounted) return;
      showErrorBar(context, 'Error adding Precise Reference: $err');
    }
  }

  Future<void> addReferenceBytes(Uint8List bytes, String fileName) async {
    referenceList.add(await PreciseReferenceConfig.fromBytes(bytes, fileName));
    notifyListeners();
  }

  Future<void> handleReferenceDropEvent(
    BuildContext context,
    PerformDropEvent event,
  ) async {
    if (!isSupported) return;
    final item = event.session.items.first;
    final reader = item.dataReader;
    if (reader == null) return;
    reader.getFile(null, (file) async {
      try {
        final bytes = await file.readAll();
        await addReferenceBytes(bytes, file.fileName ?? 'Imported reference');
        if (!context.mounted) return;
        showInfoBar(context, 'Added Precise Reference.');
      } catch (err) {
        if (!context.mounted) return;
        showErrorBar(context, 'Error adding Precise Reference: $err');
      }
    });
  }

  void removeConfigAtIndex(int index) {
    if (index < 0 || index >= referenceList.length) return;
    referenceList.removeAt(index);
    notifyListeners();
  }

  void setEnabled(PreciseReferenceConfig config, bool value) {
    config.enabled = value;
    notifyListeners();
  }

  void setType(PreciseReferenceConfig config, PreciseReferenceType type) {
    config.type = type;
    notifyListeners();
  }

  void setStrength(PreciseReferenceConfig config, double value) {
    config.strength = value.clamp(0.0, 1.0);
    notifyListeners();
  }

  void setFidelity(PreciseReferenceConfig config, double value) {
    config.fidelity = value.clamp(0.0, 1.0);
    notifyListeners();
  }
}
