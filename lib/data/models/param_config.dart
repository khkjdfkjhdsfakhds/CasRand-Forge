import 'dart:math';

import '../../core/constants/defaults.dart';
import 'generation_size.dart';

class ParamConfig {
  static const String defaultModel = 'nai-diffusion-5-full';
  static const double defaultScale = 5.0;
  static const double defaultCfgRescale = 0.0;

  List<GenerationSize> sizes;
  int nSamples;

  int steps;
  String sampler;
  String noiseSchedule;
  double scale;
  double cfgRescale;
  bool sm;
  bool smDyn;
  bool varietyPlus;

  bool? deliberateEulerAncestralBug;
  bool? preferBrownian;

  bool randomSeed;
  int? seed;

  bool dynamicThresholding;
  double controlNetStrength;
  double uncondScale;

  bool qualityToggle;
  int ucPreset;
  String negativePrompt;

  bool legacy;
  bool addOriginalImage;

  String model = defaultModel;

  bool autoPosition;
  bool legacyUc;

  ParamConfig({
    this.model = defaultModel,
    this.sizes = const [GenerationSize(height: 1216, width: 832)],
    this.scale = defaultScale,
    this.sampler = 'k_euler_ancestral',
    this.steps = 28,
    this.randomSeed = true,
    this.seed = 0,
    this.nSamples = 1,
    this.ucPreset = 2,
    this.qualityToggle = false,
    this.sm = true,
    this.smDyn = true,
    this.dynamicThresholding = false,
    this.controlNetStrength = 1.0,
    this.legacy = false,
    this.addOriginalImage = false,
    this.uncondScale = 1.0,
    this.cfgRescale = defaultCfgRescale,
    this.noiseSchedule = 'native',
    this.varietyPlus = false,
    this.deliberateEulerAncestralBug,
    this.preferBrownian,
    this.negativePrompt = defaultUC,
    this.autoPosition = true,
    this.legacyUc = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'model': model,
      'sizes': sizes.map((elem) => elem.toJson()).toList(),
      'scale': scale,
      'sampler': sampler,
      'steps': steps,
      'n_samples': nSamples,
      'ucPreset': ucPreset,
      'qualityToggle': qualityToggle,
      'sm': sm,
      'sm_dyn': smDyn,
      'random_seed': randomSeed,
      'seed': seed,
      'dynamic_thresholding': dynamicThresholding,
      'controlnet_strength': controlNetStrength,
      'legacy': legacy,
      'add_original_image': addOriginalImage,
      'uncond_scale': uncondScale,
      'cfg_rescale': cfgRescale,
      'noise_schedule': noiseSchedule,
      'negative_prompt': negativePrompt,
      'reference_image_multiple': [],
      'reference_information_extracted_multiple': [],
      'reference_strength_multiple': [],
      'variety_plus': varietyPlus,
      'deliberate_euler_ancestral_bug': deliberateEulerAncestralBug,
      'prefer_brownian': preferBrownian,
      'auto_position': autoPosition,
      'legacy_uc': legacyUc,
    };
  }

  /// Picks the generation size for one request (uniformly random when
  /// multiple sizes are configured).
  GenerationSize pickSize() => sizes[Random().nextInt(sizes.length)];

  /// Different from toJson(), some fields in payload need to be calculated from other params.
  /// [overrideSize] replaces the random size pick (used by img2img/inpaint
  /// requests whose size is derived from the input image).
  Map<String, dynamic> getPayload({GenerationSize? overrideSize}) {
    bool? effectiveDeliberateEulerAncestralBug = deliberateEulerAncestralBug;
    bool? effectivePreferBrownian = preferBrownian;
    final hasImportedSamplerOverrides =
        deliberateEulerAncestralBug != null || preferBrownian != null;
    if (!hasImportedSamplerOverrides &&
        sampler == 'k_euler_ancestral' &&
        noiseSchedule != 'native') {
      effectiveDeliberateEulerAncestralBug = false;
      effectivePreferBrownian = true;
    }
    double? skipCfgAboveSigma;
    final selectedSize = overrideSize ?? pickSize();
    final width = selectedSize.width;
    final height = selectedSize.height;
    if (varietyPlus) {
      final w = width / 8;
      final h = height / 8;
      final v = pow(4.0 * w * h / 63232, 0.5);
      skipCfgAboveSigma = 19.0 * v;
    }
    var payload = {
      "params_version": 3,
      "width": width,
      "height": height,
      "scale": scale,
      "sampler": sampler,
      "steps": steps,
      "n_samples": nSamples,
      "ucPreset": 2,
      "qualityToggle": false,
      'sm': sm,
      'sm_dyn': smDyn,
      "dynamic_thresholding": dynamicThresholding,
      "controlnet_strength": controlNetStrength,
      "legacy": legacy,
      "add_original_image": true,
      "cfg_rescale": cfgRescale,
      "noise_schedule": noiseSchedule,
      "skip_cfg_above_sigma": skipCfgAboveSigma,
      "use_coords": true,
      "seed": randomSeed ? Random().nextInt(1 << 32 - 1) : seed ?? 0,
      "characterPrompts": [],
      "v4_prompt": {},
      "v4_negative_prompt": {},
      "negative_prompt": negativePrompt,
      "reference_image_multiple": [],
      "reference_information_extracted_multiple": [],
      "reference_strength_multiple": [],
      "deliberate_euler_ancestral_bug": effectiveDeliberateEulerAncestralBug,
      "prefer_brownian": effectivePreferBrownian,
      "legacy_uc": legacyUc,
    };
    payload['legacy_v3_extend'] = false;
    payload.removeWhere((k, v) => v == null);
    if (model.contains('diffusion-4') || model.contains('diffusion-5')) {
      payload.remove('sm');
      payload.remove('sm_dyn');
      if (model.contains('diffusion-4') && noiseSchedule.contains('native')) {
        payload['noise_schedule'] = 'karras';
      }
    }
    return payload;
  }

  factory ParamConfig.fromJson(Map<String, dynamic> json) {
    return ParamConfig(
      model: json['model'] ?? defaultModel,
      sizes: (json['sizes'] as List<dynamic>?)
              ?.map((elem) => GenerationSize.fromJson(elem))
              .toList() ??
          const [GenerationSize(height: 1216, width: 832)],
      scale: (json['scale'] as num?)?.toDouble() ?? defaultScale,
      sampler: json['sampler'] ?? 'k_euler_ancestral',
      steps: json['steps'] ?? 28,
      nSamples: json['n_samples'] ?? 1,
      randomSeed: json['random_seed'] ?? true,
      seed: json['seed'] ?? 0,
      ucPreset: json['ucPreset'] ?? 0,
      qualityToggle: json['qualityToggle'] ?? false,
      sm: json['sm'] ?? true,
      smDyn: json['sm_dyn'] ?? true,
      dynamicThresholding: json['dynamic_thresholding'] ?? false,
      varietyPlus: json['variety_plus'] ?? false,
      controlNetStrength: json['controlnet_strength'] is int
          ? (json['controlnet_strength'] as int).toDouble()
          : json['controlnet_strength'] ?? 1.0,
      legacy: json['legacy'] ?? false,
      addOriginalImage: json['add_original_image'] ?? false,
      uncondScale: json['uncond_scale'] is int
          ? (json['uncond_scale'] as int).toDouble()
          : json['uncond_scale'] ?? 1.0,
      cfgRescale:
          (json['cfg_rescale'] as num?)?.toDouble() ?? defaultCfgRescale,
      noiseSchedule: json['noise_schedule'] ?? 'native',
      negativePrompt: json['negative_prompt'] ?? defaultUC,
      autoPosition: json['auto_position'] ?? true,
      legacyUc: json['legacy_uc'] ?? false,
      deliberateEulerAncestralBug:
          json['deliberate_euler_ancestral_bug'] as bool?,
      preferBrownian: json['prefer_brownian'] as bool?,
    );
  }

  int loadJson(Map<String, dynamic> json) {
    int loadCount = 0;
    if (json.containsKey('sampler') || json.containsKey('noise_schedule')) {
      clearImportedSamplerOverrides();
    }
    if (json['model'] is String && (json['model'] as String).isNotEmpty) {
      model = json['model'] as String;
      loadCount++;
    }
    if (json['sizes'] is List) {
      final importedSizes = (json['sizes'] as List)
          .whereType<Map<String, dynamic>>()
          .map(GenerationSize.fromJson)
          .toList();
      if (importedSizes.isNotEmpty) {
        sizes = importedSizes;
        loadCount++;
      }
    }
    if (json.containsKey('width') && json.containsKey('height')) {
      final width = json['width'];
      final height = json['height'];
      if (width is num && height is num) {
        sizes = [
          GenerationSize(width: width.toInt(), height: height.toInt()),
        ];
        loadCount += 2;
      }
    }
    if (json.containsKey('scale')) {
      final value = json['scale'];
      if (value is num) {
        scale = value.toDouble();
        loadCount++;
      }
    }
    if (json.containsKey('sampler')) {
      sampler = json['sampler'];
      loadCount++;
    }
    if (json.containsKey('steps')) {
      final value = json['steps'];
      if (value is num) {
        steps = value.toInt();
        loadCount++;
      }
    }
    if (json.containsKey('n_samples')) {
      final value = json['n_samples'];
      if (value is num) {
        nSamples = value.toInt();
        loadCount++;
      }
    }
    if (json.containsKey('ucPreset')) {
      ucPreset = json['ucPreset'];
      loadCount++;
    }
    if (json.containsKey('qualityToggle')) {
      qualityToggle = json['qualityToggle'];
      loadCount++;
    }
    if (json.containsKey('sm')) {
      sm = json['sm'];
      loadCount++;
    }
    if (json.containsKey('sm_dyn')) {
      smDyn = json['sm_dyn'];
      loadCount++;
    }
    if (json.containsKey('dynamic_thresholding')) {
      dynamicThresholding = json['dynamic_thresholding'];
      loadCount++;
    }
    if (json.containsKey('controlnet_strength')) {
      controlNetStrength = json['controlnet_strength'] is int
          ? (json['controlnet_strength'] as int).toDouble()
          : json['controlnet_strength'];
      loadCount++;
    }
    if (json.containsKey('legacy')) {
      legacy = json['legacy'];
      loadCount++;
    }
    if (json.containsKey('add_original_image')) {
      addOriginalImage = json['add_original_image'];
      loadCount++;
    }
    if (json.containsKey('uncond_scale')) {
      uncondScale = json['uncond_scale'] is int
          ? (json['uncond_scale'] as int).toDouble()
          : json['uncond_scale'];
      loadCount++;
    }
    if (json.containsKey('cfg_rescale')) {
      final value = json['cfg_rescale'];
      if (value is num) {
        cfgRescale = value.toDouble();
        loadCount++;
      }
    }
    if (json.containsKey('noise_schedule')) {
      noiseSchedule = json['noise_schedule'];
      loadCount++;
    }
    if (json.containsKey('deliberate_euler_ancestral_bug')) {
      deliberateEulerAncestralBug =
          json['deliberate_euler_ancestral_bug'] as bool?;
      loadCount++;
    }
    if (json.containsKey('prefer_brownian')) {
      preferBrownian = json['prefer_brownian'] as bool?;
      loadCount++;
    }
    if (json.containsKey('negative_prompt')) {
      negativePrompt = json['negative_prompt'];
      loadCount++;
    }
    if (json.containsKey('seed')) {
      final importedSeed = json['seed'];
      if (importedSeed is num) {
        seed = importedSeed.toInt();
        randomSeed = false;
        loadCount++;
      }
    } else if (json['random_seed'] is bool) {
      randomSeed = json['random_seed'] as bool;
      loadCount++;
    }
    if (json.containsKey('use_coords')) {
      autoPosition = !(json['use_coords'] as bool);
      loadCount++;
    }
    if (json.containsKey('uc')) {
      negativePrompt = json['uc'];
      loadCount++;
    }
    if (json['variety_plus'] is bool) {
      varietyPlus = json['variety_plus'] as bool;
      loadCount++;
    }
    if (json['legacy_uc'] is bool) {
      legacyUc = json['legacy_uc'] as bool;
      loadCount++;
    }
    if (json['auto_position'] is bool) {
      autoPosition = json['auto_position'] as bool;
      loadCount++;
    }
    return loadCount;
  }

  void clearImportedSamplerOverrides() {
    deliberateEulerAncestralBug = null;
    preferBrownian = null;
  }
}
