import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

void showPromptSelectionHint(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(
      key: const Key('prompt-selection-hint'),
      content: Text('prompt_selection_unsafe'.tr()),
      duration: const Duration(seconds: 2),
    ));
}
