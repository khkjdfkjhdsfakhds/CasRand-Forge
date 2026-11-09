import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/generation_profile.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/parameters_config/view_models/parameters_config_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';

class ConfigPageViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I();

  ConfigPageViewmodel();

  /// Follow the active profile; used by the fixed-mode tabs and the page-level
  /// floating buttons.
  late final PromptTabViewmodel activePromptViewmodel =
      PromptTabViewmodel(payloadConfig: payloadConfig);
  late final ParametersConfigViewmodel activeParametersViewmodel =
      ParametersConfigViewmodel();

  GenerationPageViewmodel? get _generation =>
      GetIt.I.isRegistered<GenerationPageViewmodel>()
          ? GetIt.I<GenerationPageViewmodel>()
          : null;

  Listenable get promptSchemeChanges {
    final generation = _generation;
    return Listenable.merge([
      this,
      payloadConfig,
      if (generation != null) ...[
        generation,
        generation.commandStatus.isGenerationActive,
        generation.commandStatus.isStopping,
      ],
    ]);
  }

  bool get isGenerating {
    final generation = _generation;
    if (generation == null) return false;
    return generation.commandStatus.isGenerationActive.value ||
        generation.commandStatus.isStopping.value ||
        generation.isBusyPreparingOrSingle;
  }

  bool get isFixedMode => payloadConfig.promptMode == PromptMode.fixed;

  bool get canChangePromptSchemes => !isGenerating;

  bool get canDeletePromptScheme =>
      canChangePromptSchemes && payloadConfig.promptSchemes.length > 1;

  // ---------------------------------------------------------------------------
  // Which cards are open is view state only, and is keyed by name because a
  // reloaded configuration replaces every scheme object.

  Set<String>? _expandedNames;
  Set<String> _knownNames = const {};
  final Map<String, int> _selectedTabs = {};

  /// Opens the active card the first time a configuration is shown.
  void syncPromptSchemeViewState() {
    final names = {for (final s in payloadConfig.promptSchemes) s.name};
    if (_expandedNames == null || names.intersection(_knownNames).isEmpty) {
      _expandedNames = {payloadConfig.currentPromptScheme.name};
    }
    _knownNames = names;
  }

  bool isPromptSchemeExpanded(PromptScheme scheme) =>
      _expandedNames?.contains(scheme.name) ?? false;

  void togglePromptSchemeExpanded(PromptScheme scheme) {
    final expanded = _expandedNames ??= {};
    if (!expanded.remove(scheme.name)) expanded.add(scheme.name);
    notifyListeners();
  }

  int selectedTab(PromptScheme scheme) => _selectedTabs[scheme.name] ?? 0;

  void setSelectedTab(PromptScheme scheme, int tab) {
    _selectedTabs[scheme.name] = tab;
  }

  // ---------------------------------------------------------------------------
  // Scheme list changes

  void activatePromptScheme(int index) {
    if (!canChangePromptSchemes) return;
    payloadConfig.selectPromptScheme(index);
    _saveAfterFrame();
  }

  /// Appends a copy of the active scheme, collapsed and not yet active.
  void createPromptScheme(String name) {
    if (!canChangePromptSchemes) return;
    payloadConfig.createPromptSchemeFromCurrent(name, activate: false);
    _saveAfterFrame();
  }

  void renamePromptScheme(int index, String name) {
    if (!canChangePromptSchemes) return;
    final previous = payloadConfig.promptSchemes[index].name;
    payloadConfig.renamePromptScheme(index, name);
    final renamed = payloadConfig.promptSchemes[index].name;
    if (_expandedNames?.remove(previous) ?? false) {
      _expandedNames!.add(renamed);
    }
    final tab = _selectedTabs.remove(previous);
    if (tab != null) _selectedTabs[renamed] = tab;
    _saveAfterFrame();
  }

  void movePromptScheme(int from, int to) {
    if (!canChangePromptSchemes) return;
    payloadConfig.movePromptScheme(from, to);
    _saveAfterFrame();
  }

  void deletePromptScheme(int index) {
    if (!canDeletePromptScheme) return;
    final removed = payloadConfig.promptSchemes[index].name;
    payloadConfig.deletePromptScheme(index);
    _expandedNames?.remove(removed);
    _selectedTabs.remove(removed);
    _saveAfterFrame();
  }

  PromptSchemeNameError? validatePromptSchemeName(
    String name, {
    required int index,
  }) {
    return payloadConfig.validatePromptSchemeName(name, ignoreIndex: index);
  }

  /// Serializing the whole configuration is left until the changed page has
  /// been painted, so a large configuration cannot delay the visible change.
  Future<void> _saveAfterFrame() async {
    await SchedulerBinding.instance.endOfFrame;
    if (GetIt.I.isRegistered<ConfigService>()) {
      await GetIt.I<ConfigService>().saveConfig(payloadConfig.toJson());
    }
  }
}
