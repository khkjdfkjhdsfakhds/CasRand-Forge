import 'dart:io';

import 'package:flutter/foundation.dart';

bool get supportsSuperNativeExtensions {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}
