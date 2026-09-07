import 'dart:math';

import 'package:nai_casrand/data/models/generation_size.dart';

/// Transient Enhance policy. Ordinary generation never applies these overrides.
class EnhanceRequestOptions {
  final bool upscale;
  const EnhanceRequestOptions({this.upscale = false});

  static const maxPixels = 3 * 1024 * 1024;

  /// Website generateEnhance calls voM for each new request, independently
  /// of the seed displayed in generation settings. Preserve its edge values.
  static int nextSeed({Random? random}) =>
      (0x100000000 * (random ?? Random()).nextDouble() - 1).floor();

  static bool supportsMax(String model) =>
      model == 'nai-diffusion-5-full' || model == 'nai-diffusion-5-curated';

  /// The website normalizes conditioning pixels first, then snaps the final
  /// API dimensions to the nearest 64 pixels (ties round upward).
  static GenerationSize apiSize(int width, int height) => GenerationSize(
        width: max(64, (width / 64).round() * 64),
        height: max(64, (height / 64).round() * 64),
      );

  static GenerationSize outputSize(int width, int height) {
    final request = apiSize(width, height);
    width = request.width;
    height = request.height;
    final factor = min(2.0, sqrt(maxPixels / (width * height)));
    return GenerationSize(
      width: (width * factor).floor(),
      height: (height * factor).floor(),
    );
  }

  /// Website billing geometry differs from the returned image dimensions.
  static GenerationSize costSize(int width, int height) {
    if (width < 16 || height < 16) {
      throw ArgumentError('Image is too small for Max');
    }
    // The panel computes billing directly from the source dimensions; the
    // request's later 64-pixel alignment is a separate operation.
    final w = (width ~/ 16) * 32;
    final h = (height ~/ 16) * 32;
    if (w == 0 || h == 0) throw ArgumentError('Image is too small for Max');
    final factor = min(1.0, sqrt(maxPixels / (w * h)));
    var outW = (w * factor / 32).round() * 32;
    var outH = (h * factor / 32).round() * 32;
    if (outW * outH > maxPixels) {
      outW = (w * factor / 32).floor() * 32;
      outH = (h * factor / 32).floor() * 32;
    }
    if (outW < 32 || outH < 32) {
      throw ArgumentError('Aspect ratio is too extreme for Max');
    }
    return GenerationSize(width: outW, height: outH);
  }

  String prompt(String value, String model) {
    if (upscale ||
        !(model.contains('diffusion-4-5') || supportsMax(model)) ||
        value.contains('upscaled, blurry')) {
      return value;
    }
    const suffix = ', -2::upscaled, blurry::,';
    final text =
        RegExp(r'(?:^|\s|[,.:[\]{}、。])text:(?!:)', caseSensitive: false)
            .firstMatch(value);
    if (text == null) return '$value$suffix';
    return value.substring(0, text.start) +
        suffix +
        value.substring(text.start);
  }

  void apply(Map<String, dynamic> parameters, String model) {
    final size =
        apiSize(parameters['width'] as int, parameters['height'] as int);
    parameters['width'] = size.width;
    parameters['height'] = size.height;
    parameters['n_samples'] = 1;
    parameters['color_correct'] = false;
    parameters['extra_noise_seed'] = (parameters['seed'] as int) - 1;
    parameters.remove('add_original_image');
    if (upscale) {
      if (!supportsMax(model)) throw ArgumentError('Max requires a V5 model');
      parameters['upscaled_enhance'] = true;
    } else {
      parameters.remove('upscaled_enhance');
    }
    if (supportsMax(model)) {
      parameters['noise_schedule'] = 'karras';
      parameters.remove('skip_cfg_above_sigma');
      if (parameters['sampler'] == 'k_euler_ancestral') {
        parameters['deliberate_euler_ancestral_bug'] = false;
        parameters['prefer_brownian'] = true;
      }
    }
  }
}
