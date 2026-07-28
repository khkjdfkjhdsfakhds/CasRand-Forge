import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../../core/constants/image_formats.dart';
import '../../../data/models/vibe_config.dart';

class VibeConfigListViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  List<VibeConfig> get vibeList => payloadConfig.vibeConfigList;
  bool get featureEnabled => payloadConfig.vibeEnabled;

  void setFeatureEnabled(bool value) {
    payloadConfig.setVibeEnabled(value);
    notifyListeners();
  }

  VibeConfigListViewmodel();

  void removeVibeConfigAt(int idx) {
    vibeList.removeAt(idx);
    if (!payloadConfig.hasVibeResources) {
      payloadConfig.clearVibeResourceState();
    }
    notifyListeners();
  }

  void addNewVibe() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;
    final bytes = await image.readAsBytes();
    var newConfig = VibeConfig.fromBytes(bytes, image.name, 1.0, 0.3);
    final wasEmpty = !payloadConfig.hasVibeResources;
    vibeList.add(newConfig);
    payloadConfig.noteVibeImported(wasEmpty: wasEmpty);
    notifyListeners();
  }

  Future<void> handleVibeDropEvent(PerformDropEvent event) async {
    final wasEmpty = !payloadConfig.hasVibeResources;
    final item = event.session.items.first;
    final reader = item.dataReader!;
    reader.getFile(imageFormat, (file) async {
      final data = await file.readAll();
      vibeList.add(
          VibeConfig.fromBytes(data, file.fileName ?? 'Unnamed Vibe', 1, 0.3));
      payloadConfig.noteVibeImported(wasEmpty: wasEmpty);
      notifyListeners();
    });
  }

  void removeConfigAtIndex(int index) {
    if (index >= 0 && index < vibeList.length) {
      vibeList.removeAt(index);
      if (!payloadConfig.hasVibeResources) {
        payloadConfig.clearVibeResourceState();
      }
      notifyListeners();
    }
  }
}
