import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:nai_casrand/core/constants/parameters.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/vibe_config.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';

const Map<int, String> xMapping = {
  0: 'X',
  1: 'A',
  2: 'B',
  3: 'C',
  4: 'D',
  5: 'E',
};

const Map<int, double> doubleMapping = {
  0: 0.0,
  1: 0.1,
  2: 0.3,
  3: 0.5,
  4: 0.7,
  5: 0.9
};

class PromptCommentPair {
  String prompt;
  String comment;

  PromptCommentPair({
    required this.prompt,
    required this.comment,
  });
}

class PayloadGenerationResult {
  Map<String, dynamic> payload;
  String comment;
  String suggestedFileName;

  PayloadGenerationResult({
    required this.payload,
    required this.comment,
    required this.suggestedFileName,
  });
}

class GeneratePayloadUseCase {
  final PayloadConfig payloadConfig;

  /// Optional img2img / inpainting request plan. When present the payload
  /// switches to the corresponding action and uses the plan's request size.
  final I2iRequestPlan? i2iPlan;

  /// Per-request overrides used by transient flows such as Enhance. They do
  /// not mutate the user's saved prompt or seed settings.
  final int? seedOverride;
  final bool applyI2iAreaRandomSeed;
  final String promptSuffix;
  final Random _random;

  GeneratePayloadUseCase({
    required this.payloadConfig,
    this.i2iPlan,
    this.seedOverride,
    this.applyI2iAreaRandomSeed = false,
    this.promptSuffix = '',
    Random? random,
  }) : _random = random ?? Random();

  ParamConfig get paramConfig => payloadConfig.paramConfig;
  PromptConfig get rootPromptConfig => payloadConfig.rootPromptConfig;
  PromptConfig get negativePromptConfig => payloadConfig.negativePromptConfig;
  List<CharacterConfig> get characterConfigList =>
      payloadConfig.characterConfigList;
  List<PromptConfig> get savedConfigList => payloadConfig.savedPromptConfigList;
  List<VibeConfig> get vibeConfigList => payloadConfig.vibeConfigList;
  List<VibeConfigV4> get vibeConfigV4List => payloadConfig.vibeConfigListV4;
  List<PreciseReferenceConfig> get preciseReferenceConfigList =>
      payloadConfig.preciseReferenceConfigList;
  String get fileNameKey => payloadConfig.settings.fileNamePrefixKey;

  PayloadGenerationResult call() {
    final pattern = RegExp(
      r'__([\p{L}0-9_\-（）().\u4e00-\u9fff\uff00-\uffef]+?)__',
      unicode: true,
    );

    // Get prompt
    final filterEntryComments = payloadConfig.promptMode != PromptMode.fixed;
    final basePromptResult = rootPromptConfig
        .getPrmpts(filterEntryComments: filterEntryComments)
        .replaceVariables(pattern, savedConfigList);
    final basePair = PromptCommentPair(
      prompt: basePromptResult.toPrompt(),
      comment: basePromptResult.toComment(),
    );
    final effectiveBasePrompt = _appendPromptSuffix(
      basePair.prompt,
      promptSuffix,
    );
    final plan = i2iPlan;
    final paramPayload = plan == null
        ? paramConfig.getPayload()
        : paramConfig.getPayload(
            overrideSize: GenerationSize(
              width: plan.width,
              height: plan.height,
            ),
          );
    if (seedOverride != null) {
      paramPayload['seed'] = seedOverride;
    } else if (plan != null &&
        applyI2iAreaRandomSeed &&
        payloadConfig.i2iConfig.useRandomSeed) {
      paramPayload['seed'] =
          (_random.nextInt(1 << 16) << 16) | _random.nextInt(1 << 16);
    }
    String payloadComment = basePair.comment;

    // Get character prompt
    final List<CharacterPromptResult> characterPromptResultList = [];
    for (final config in characterConfigList) {
      if (!config.enabled) continue;
      characterPromptResultList.add(config.getPrompt());
    }

    // Character prompts
    final characterPrompts = [];
    final v4CharPosCaptions = [];
    final v4CharNegCaptions = [];
    for (final (index, result) in characterPromptResultList.indexed) {
      final posAsString = '${xMapping[result.center.x]}${result.center.y}';
      final posAsDouble = {
        'x': doubleMapping[result.center.x]!,
        'y': doubleMapping[result.center.y]!,
      };
      result.prompt = result.prompt.replaceVariables(pattern, savedConfigList);
      result.uc = result.uc.replaceVariables(pattern, savedConfigList);
      final characterPair = PromptCommentPair(
        prompt: result.prompt.toPrompt(),
        comment: result.prompt.toComment(),
      );
      final characterNegativePair = PromptCommentPair(
        prompt: result.uc.toPrompt(),
        comment: result.uc.toComment(),
      );
      payloadComment += '\n\nCharacter ${index + 1} at $posAsString:\n'
          '${characterPair.comment}\n'
          '${tr('uc')}:\n${characterNegativePair.comment}';
      characterPrompts.add({
        'prompt': characterPair.prompt,
        'uc': characterNegativePair.prompt,
        'center': posAsDouble,
      });
      v4CharPosCaptions.add({
        'char_caption': characterPair.prompt,
        'centers': [posAsDouble],
      });
      v4CharNegCaptions.add({
        'char_caption': characterNegativePair.prompt,
        'centers': [posAsDouble],
      });
    }
    final negativePromptResult = negativePromptConfig
        .getPrmpts(filterEntryComments: filterEntryComments)
        .replaceVariables(pattern, savedConfigList);
    final negativePair = PromptCommentPair(
      prompt: negativePromptResult.toPrompt(),
      comment: negativePromptResult.toComment(),
    );
    payloadComment += '\n\n${tr('uc')}:\n${negativePair.comment}';
    paramPayload['negative_prompt'] = negativePair.prompt;
    final v4Prompt = {
      'caption': {
        'base_caption': effectiveBasePrompt,
        'char_captions': v4CharPosCaptions,
      },
      'use_coords': !paramConfig.autoPosition,
      'use_order': true,
    };
    final v4NegPrompt = {
      'caption': {
        'base_caption': negativePair.prompt,
        'char_captions': v4CharNegCaptions,
      },
      'legacy_uc': paramConfig.legacyUc,
    };
    paramPayload['v4_prompt'] = v4Prompt;
    paramPayload['v4_negative_prompt'] = v4NegPrompt;
    paramPayload['characterPrompts'] = characterPrompts;

    final activePreciseReferenceList = payloadConfig.preciseReferenceEnabled
        ? preciseReferenceConfigList
            .where((config) => config.enabled)
            .toList(growable: false)
        : <PreciseReferenceConfig>[];
    if (payloadConfig.vibeEnabled && paramConfig.model.contains('-3')) {
      // Vibe config for NAI3 models
      final imageB64List = [];
      final referenceStrengthList = [];
      final imformationExtractedList = [];
      for (final vc in vibeConfigList) {
        imageB64List.add(vc.imageB64);
        referenceStrengthList.add(vc.referenceStrength);
        imformationExtractedList.add(vc.infoExtracted);
      }
      paramPayload['reference_image_multiple'] = imageB64List;
      paramPayload['reference_strength_multiple'] = referenceStrengthList;
      paramPayload['reference_information_extracted_multiple'] =
          imformationExtractedList;
    } else if (paramConfig.model.contains('-4-5-') &&
        activePreciseReferenceList.isNotEmpty) {
      paramPayload['director_reference_images'] = activePreciseReferenceList
          .map((config) => config.imageB64)
          .toList(growable: false);
      paramPayload['director_reference_descriptions'] =
          activePreciseReferenceList.map((config) {
        return {
          'caption': {
            'base_caption': config.type.payloadCaption,
            'char_captions': [],
          },
          'legacy_uc': false,
        };
      }).toList(growable: false);
      paramPayload['director_reference_information_extracted'] =
          activePreciseReferenceList.map((_) => 1.0).toList(growable: false);
      paramPayload['director_reference_strength_values'] =
          activePreciseReferenceList
              .map((config) => config.strength)
              .toList(growable: false);
      paramPayload['director_reference_secondary_strength_values'] =
          activePreciseReferenceList
              .map((config) => 1.0 - config.fidelity)
              .toList(growable: false);
    } else if (payloadConfig.vibeEnabled && paramConfig.model.contains('-4-')) {
      // Vibe config for NAI4 models
      final imageB64List = [];
      final infoExtractedList = [];
      final referenceStrengthList = [];
      for (final vc in vibeConfigV4List) {
        final encoding = vc.encodingFor(paramConfig.model);
        if (encoding == null) {
          throw StateError(
            'Vibe encoding is not ready for ${vc.fileName} and '
            '${paramConfig.model}.',
          );
        }
        imageB64List.add(encoding);
        referenceStrengthList.add(vc.referenceStrength);
        infoExtractedList.add(vc.informationExtracted);
      }
      paramPayload['reference_image_multiple'] = imageB64List;
      paramPayload['reference_strength_multiple'] = referenceStrengthList;
      paramPayload['reference_information_extracted_multiple'] =
          infoExtractedList;
    }

    // img2img / inpainting request fields, mirroring the official frontend.
    var action = 'generate';
    var model = paramConfig.model;
    if (plan != null) {
      final seed = paramPayload['seed'] as int;
      paramPayload['image'] = plan.imageB64;
      paramPayload['extra_noise_seed'] = (seed - 1) & 0xFFFFFFFF;
      if (plan.isInpaint) {
        action = 'infill';
        model = inpaintModelMapping[model] ?? model;
        paramPayload['mask'] = plan.maskB64;
        // The official frontend always requests the raw infill result, then
        // blends it over the source image locally with a feathered mask.
        paramPayload['add_original_image'] = false;
        // The user-facing strength maps to inpaintImg2ImgStrength; the legacy
        // strength/noise pair takes fixed values on modern inpainting.
        paramPayload['strength'] = 0.7;
        paramPayload['noise'] = 0.2;
        paramPayload['inpaintImg2ImgStrength'] = plan.strength;
        if (plan.strength < 1) {
          paramPayload['img2img'] = {
            'strength': plan.strength,
            'color_correct': true,
          };
        }
      } else {
        action = 'img2img';
        paramPayload['strength'] = plan.strength;
        paramPayload['noise'] = plan.noise;
      }
      payloadComment += '\n\nI2I: ${plan.summary}';
    }

    final prefixComments = payloadConfig.collectPrefixComments();
    final List<String> extractedPrefixes = [];
    for (final comment in prefixComments) {
      final val = basePromptResult.findPromptWithKey(comment) ??
          characterPromptResultList
              .map((cp) => cp.prompt.findPromptWithKey(comment))
              .firstWhere((p) => p != null, orElse: () => null);
      if (val != null && val.trim().isNotEmpty) {
        extractedPrefixes.add(val.trim());
      }
    }

    final processedFileName = extractedPrefixes.isNotEmpty
        ? extractedPrefixes.join('-')
        : _processFileNameKey(fileNameKey, basePromptResult);

    return PayloadGenerationResult(
      comment: payloadComment,
      suggestedFileName: processedFileName,
      payload: {
        'input': effectiveBasePrompt,
        'model': model,
        'action': action,
        'parameters': paramPayload,
      },
    );
  }

  /// Applies one tile plan to an already-generated payload without consulting
  /// mutable prompt/reference settings or advancing any random/sequential
  /// prompt source. Used by split inpainting so every tile belongs to the same
  /// immutable generation batch.
  static Map<String, dynamic> applyI2iPlanToPayload(
    Map<String, dynamic> basePayload,
    I2iRequestPlan plan,
  ) {
    final payload = _deepCopyJsonMap(basePayload);
    final parameters = payload['parameters'] as Map<String, dynamic>;
    final seed = parameters['seed'] as int;
    parameters
      ..['width'] = plan.width
      ..['height'] = plan.height
      ..['image'] = plan.imageB64
      ..['extra_noise_seed'] = (seed - 1) & 0xFFFFFFFF;

    if (plan.isInpaint) {
      payload
        ..['action'] = 'infill'
        ..['model'] = inpaintModelMapping[payload['model']] ?? payload['model'];
      parameters
        ..['mask'] = plan.maskB64
        ..['add_original_image'] = false
        ..['strength'] = 0.7
        ..['noise'] = 0.2
        ..['inpaintImg2ImgStrength'] = plan.strength;
      if (plan.strength < 1) {
        parameters['img2img'] = {
          'strength': plan.strength,
          'color_correct': true,
        };
      } else {
        parameters.remove('img2img');
      }
    } else {
      payload['action'] = 'img2img';
      parameters
        ..remove('mask')
        ..remove('inpaintImg2ImgStrength')
        ..remove('img2img')
        ..['strength'] = plan.strength
        ..['noise'] = plan.noise;
    }
    return payload;
  }

  static Map<String, dynamic> _deepCopyJsonMap(Map<String, dynamic> source) {
    dynamic copy(dynamic value) {
      if (value is Map) {
        return value.map<String, dynamic>(
          (key, item) => MapEntry(key.toString(), copy(item)),
        );
      }
      if (value is List) return value.map(copy).toList(growable: false);
      return value;
    }

    return copy(source) as Map<String, dynamic>;
  }

  String _appendPromptSuffix(String prompt, String suffix) {
    var normalizedSuffix = suffix.trim();
    if (normalizedSuffix.isEmpty) return prompt;
    if (normalizedSuffix.startsWith(',')) {
      normalizedSuffix = normalizedSuffix.substring(1).trimLeft();
    }
    if (prompt.trim().isEmpty) return normalizedSuffix;

    final normalizedPrompt = prompt.trimRight();
    final separator = normalizedPrompt.endsWith(',') ? ' ' : ', ';
    return '$normalizedPrompt$separator$normalizedSuffix';
  }

  String _processFileNameKey(
    String rawKey,
    NestedPrompt prompt,
  ) {
    return rawKey.replaceAllMapped(
      // 允许Unicode字符
      RegExp(
        r'__([\p{L}0-9_\-（）().\u4e00-\u9fff\uff00-\uffef]+?)__',
        unicode: true,
      ),
      (match) =>
          prompt.findPromptWithKey(match[1].toString()) ?? '__${match[1]}__',
    );
  }
}
