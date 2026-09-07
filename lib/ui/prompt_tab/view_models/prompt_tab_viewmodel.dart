import 'package:flutter/foundation.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';

class PromptTabViewmodel extends ChangeNotifier {
  final PayloadConfig? payloadConfig;
  final PromptConfig? _promptConfig;
  final PromptConfig? _negativePromptConfig;
  final List<CharacterConfig>? _characterConfigList;
  final List<PromptConfig>? _savedConfigList;
  final ParamConfig? _paramConfig;

  PromptConfig get promptConfig =>
      payloadConfig?.rootPromptConfig ?? _promptConfig!;
  PromptConfig get negativePromptConfig =>
      payloadConfig?.negativePromptConfig ?? _negativePromptConfig!;
  List<CharacterConfig> get characterConfigList =>
      payloadConfig?.characterConfigList ?? _characterConfigList!;
  List<PromptConfig> get savedConfigList =>
      payloadConfig?.savedPromptConfigList ?? _savedConfigList!;
  ParamConfig get paramConfig => payloadConfig?.paramConfig ?? _paramConfig!;
  bool get isFixedMode => payloadConfig?.promptMode == PromptMode.fixed;
  bool get promptAutocompleteEnabled =>
      payloadConfig?.settings.promptAutocompleteEnabled ?? true;
  String get fixedPromptText =>
      promptConfig.strs.isEmpty ? '' : promptConfig.strs.first;
  String get fixedNegativePromptText =>
      negativePromptConfig.strs.isEmpty ? '' : negativePromptConfig.strs.first;

  String fixedCharacterPromptText(int index) {
    final config = characterConfigList[index].positivePromptConfig;
    return config.strs.isEmpty ? '' : config.strs.first;
  }

  String fixedCharacterNegativePromptText(int index) {
    final config = characterConfigList[index].negativePromptConfig;
    return config.strs.isEmpty ? '' : config.strs.first;
  }

  PromptTabViewmodel({
    this.payloadConfig,
    PromptConfig? promptConfig,
    PromptConfig? negativePromptConfig,
    List<CharacterConfig>? characterConfigList,
    List<PromptConfig>? savedConfigList,
    ParamConfig? paramConfig,
  })  : _promptConfig = promptConfig,
        _negativePromptConfig = negativePromptConfig,
        _characterConfigList = characterConfigList,
        _savedConfigList = savedConfigList,
        _paramConfig = paramConfig,
        assert(
          payloadConfig != null ||
              (promptConfig != null &&
                  negativePromptConfig != null &&
                  characterConfigList != null &&
                  savedConfigList != null &&
                  paramConfig != null),
        );

  void promptModeChanged() => notifyListeners();

  void setFixedPrompt(String value) {
    if (!isFixedMode) return;
    payloadConfig!.fixedProfile.rootPromptConfig =
        PayloadConfig.fixedPromptConfig(value);
  }

  void setFixedNegativePrompt(String value) {
    if (!isFixedMode) return;
    payloadConfig!.fixedProfile.negativePromptConfig =
        PayloadConfig.fixedPromptConfig(value, negative: true);
    payloadConfig!.fixedProfile.paramConfig.negativePrompt = value;
  }

  void setFixedCharacterPrompt(int index, String value) {
    characterConfigList[index].positivePromptConfig =
        PayloadConfig.fixedPromptConfig(value);
  }

  void setFixedCharacterNegativePrompt(int index, String value) {
    characterConfigList[index].negativePromptConfig =
        PayloadConfig.fixedPromptConfig(value, negative: true);
  }

  void setCharacterEnabled(int index, bool value) {
    characterConfigList[index].enabled = value;
    notifyListeners();
  }

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
