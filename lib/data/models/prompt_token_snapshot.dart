import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:nai_casrand/data/models/batch_tool_snapshot.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/use_cases/enhance_request_options.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/novelai_text_rendering.dart';

class PromptTokenSnapshot {
  final String model;
  final List<String> positive, negative;
  final bool recentTask;
  const PromptTokenSnapshot(
      {required this.model,
      required this.positive,
      required this.negative,
      this.recentTask = false});
  List<String> get texts => [...positive, ...negative];

  factory PromptTokenSnapshot.fromPayload(Map<String, dynamic> payload) {
    final parameters = payload['parameters'] as Map;
    List<String> captions(String key, String fallback) {
      final prompt = parameters[key];
      final caption = prompt is Map ? prompt['caption'] : null;
      if (caption is! Map) return [fallback];
      return [
        caption['base_caption'] as String? ?? '',
        for (final c in (caption['char_captions'] as List? ?? []))
          (c as Map)['char_caption'] as String? ?? ''
      ];
    }

    return PromptTokenSnapshot(
        model: payload['model'] as String,
        positive: List.unmodifiable(
            captions('v4_prompt', payload['input'] as String? ?? '')),
        negative: List.unmodifiable(captions('v4_negative_prompt',
            parameters['negative_prompt'] as String? ?? '')),
        recentTask: true);
  }

  /// Pure fixed-editor projection. Never selects candidates or advances a
  /// sequence. Focus and nonliteral imported trees use actual task snapshots.
  static PromptTokenSnapshot? fixed(PayloadConfig config) {
    if (config.promptMode != PromptMode.fixed) return null;
    final tool = config.activeBatchTool;
    if (tool?.kind == BatchToolKind.director) return null;
    if (config.i2iEnabled &&
        config.i2iConfig.hasInpaintSelection &&
        tool == null) {
      return null;
    }
    final params = tool?.parameters ?? config.paramConfig;
    final chars = (params.model.contains('diffusion-4') ||
            params.model.contains('diffusion-5'))
        ? config.characterConfigList
            .where((c) => c.enabled)
            .toList(growable: false)
        : <CharacterConfig>[];
    final promptConfigs = [
      config.rootPromptConfig,
      config.negativePromptConfig,
      for (final c in chars) ...[c.positivePromptConfig, c.negativePromptConfig]
    ];
    if (promptConfigs.any((p) =>
        p.type != 'str' ||
        p.prompts.isNotEmpty ||
        p.strs.length > 1 ||
        p.selectionMethod != 'all' ||
        p.randomBracketsLower != 0 ||
        p.randomBracketsUpper != 0 ||
        (config.savedPromptConfigList.isNotEmpty &&
            p.strs.any((text) => text.contains('__'))))) {
      return null;
    }
    String literal(PromptConfig p, {bool character = false}) {
      if (!p.enabled || p.strs.isEmpty) return '';
      return character
          ? (PromptConfig.promptTextForEntry(p.strs.first) ?? '')
          : p.strs.first;
    }

    var base = literal(config.rootPromptConfig);
    final model = params.model;
    if (tool?.kind == BatchToolKind.enhance) {
      base = EnhanceRequestOptions(upscale: tool!.upscale).prompt(base, model);
    }
    if (model.contains('diffusion-5')) {
      if (params.transparentBackground) {
        base = NovelAiTextRendering.appendTransparentBackground(base);
      }
      final textChars = <TextRenderingCharacter>[];
      for (final c in chars) {
        // Multiple legacy positions are chosen by the real generation path.
        // Wait for its snapshot instead of making a second random choice.
        if (c.freeCenter == null && c.positions.length > 1) return null;
        final grid = c.positions.isEmpty
            ? CharacterConfig.defaultPosition
            : c.positions.first;
        final center = c.freeCenter ??
            Point<double>(CharacterConfig.gridToNormalized[grid.x] ?? .5,
                CharacterConfig.gridToNormalized[grid.y] ?? .5);
        textChars.add(TextRenderingCharacter(
            prompt: literal(c.positivePromptConfig, character: true),
            center: GeneratePayloadUseCase.effectiveCharacterCenter(center,
                model: model)));
      }
      base = NovelAiTextRendering.appendToBase(base, textChars,
          useCoords:
              !params.autoPosition || chars.any((c) => c.freeCenter != null));
    }
    return PromptTokenSnapshot(
        model: model,
        positive: List.unmodifiable([
          base,
          for (final c in chars)
            literal(c.positivePromptConfig, character: true)
        ]),
        negative: List.unmodifiable([
          literal(config.negativePromptConfig),
          for (final c in chars)
            literal(c.negativePromptConfig, character: true)
        ]));
  }
}

class PromptTokenTicket {
  final int sequence;
  final Object profile;
  final String selectedModel;
  final Object? tool;
  final PromptMode mode;
  PromptTokenTicket(this.sequence, PayloadConfig config)
      : profile = config.activeProfile,
        selectedModel = config.paramConfig.model,
        tool = config.activeBatchTool,
        mode = config.promptMode;
  bool matches(PayloadConfig config) =>
      identical(profile, config.activeProfile) &&
      selectedModel == config.paramConfig.model &&
      identical(tool, config.activeBatchTool) &&
      mode == config.promptMode;
}

/// Transient, text-only state. Recording never starts or awaits tokenization.
class PromptTokenSnapshots extends ChangeNotifier {
  static final instance = PromptTokenSnapshots();
  final _snapshots = Expando<(PromptTokenTicket, PromptTokenSnapshot)>();
  int _sequence = 0;
  bool _notificationPending = false;
  PromptTokenTicket begin(PayloadConfig config) =>
      PromptTokenTicket(++_sequence, config);
  void record(PayloadConfig config, PromptTokenTicket ticket,
      Map<String, dynamic> payload) {
    if (!ticket.matches(config) ||
        payload['parameters'] is! Map ||
        payload['model'] is! String) {
      return;
    }
    final previous = _snapshots[config];
    if (previous != null && previous.$1.sequence > ticket.sequence) return;
    try {
      _snapshots[config] = (ticket, PromptTokenSnapshot.fromPayload(payload));
    } catch (_) {
      // Optional display statistics must never interrupt request submission.
      return;
    }
    if (_notificationPending || !hasListeners) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      notifyListeners();
    });
  }

  PromptTokenSnapshot? latest(PayloadConfig config) {
    final saved = _snapshots[config];
    return saved != null && saved.$1.matches(config) ? saved.$2 : null;
  }
}
