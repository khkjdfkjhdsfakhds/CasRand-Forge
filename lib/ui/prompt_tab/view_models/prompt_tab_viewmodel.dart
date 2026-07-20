import 'package:flutter/foundation.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';

class PromptTabViewmodel extends ChangeNotifier {
  PromptConfig promptConfig;
  PromptConfig negativePromptConfig;
  List<CharacterConfig> characterConfigList;
  List<PromptConfig> savedConfigList;
  ParamConfig paramConfig;

  PromptTabViewmodel({
    required this.promptConfig,
    required this.negativePromptConfig,
    required this.characterConfigList,
    required this.savedConfigList,
    required this.paramConfig,
  });

  void reorderCharacter(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    var item = characterConfigList.removeAt(oldIndex);
    characterConfigList.insert(newIndex, item);
    notifyListeners();
  }

  void removeCharacter(int index) {
    characterConfigList.removeAt(index);
    notifyListeners();
  }

  void setAutoPosition(bool value) {
    paramConfig.autoPosition = value;
    if (!value) {
      for (final character in characterConfigList) {
        if (character.positions.isEmpty) {
          character.positions = [CharacterConfig.defaultPosition];
        }
      }
    }
    notifyListeners();
  }

  void addCharacter() {
    if (characterConfigList.length >= 6) return;
    characterConfigList.add(CharacterConfig.fromEmpty());
    notifyListeners();
  }
}
