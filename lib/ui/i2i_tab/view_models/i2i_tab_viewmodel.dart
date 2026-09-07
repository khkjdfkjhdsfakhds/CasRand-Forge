import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/image_import_capabilities.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';

class I2iTabViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  ParamConfig get paramConfig => payloadConfig.paramConfig;
  ImageImportCapabilities get capabilities =>
      ImageImportCapabilities.forModel(paramConfig.model);
  bool get isV4 => capabilities.isV4Family;
  bool get isV5 => capabilities.isV5Family;
}
