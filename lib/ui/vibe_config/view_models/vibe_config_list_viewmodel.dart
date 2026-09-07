import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../../core/constants/image_formats.dart';
import '../../../data/models/vibe_config.dart';
import '../../core/utils/flushbar.dart';

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
    payloadConfig.addVibeImage(bytes, image.name);
    notifyListeners();
  }

  Future<void> handleVibeDropEvent(
    BuildContext context,
    PerformDropEvent event,
  ) async {
    if (event.session.items.isEmpty) return;
    final item = event.session.items.first;
    final reader = item.dataReader;
    if (reader == null) {
      showErrorBar(context, tr('vibe_import_failed', namedArgs: {'error': ''}));
      return;
    }
    reader.getFile(imageFormat, (file) async {
      try {
        final data = await file.readAll();
        payloadConfig.addVibeImage(
          data,
          file.fileName ?? 'Unnamed Vibe',
        );
        notifyListeners();
      } catch (error) {
        if (context.mounted) {
          showErrorBar(
            context,
            tr('vibe_import_failed', namedArgs: {'error': '$error'}),
          );
        }
      }
    }, onError: (error) {
      if (context.mounted) {
        showErrorBar(
          context,
          tr('vibe_import_failed', namedArgs: {'error': '$error'}),
        );
      }
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
