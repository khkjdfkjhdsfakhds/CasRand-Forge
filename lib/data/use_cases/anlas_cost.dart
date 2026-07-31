import 'dart:math';

/// Anlas cost model, mirroring NovelAI's own calculation.
///
/// Opus (tier 3+) covers one generated sample per request for free while the
/// request stays within the 1 MP / 28-step window. This applies to text-to-
/// image, img2img, infill, and Enhance requests alike.
const int opusTier = 3;
const int opusFreeMaxArea = 1024 * 1024;
const int opusFreeMaxSteps = 28;

const double _stepCoefficient = 2951823174884865e-21;
const double _stepPerStepCoefficient = 5753298233447344e-22;
const double _smMultiplier = 1.2;
const double _smDynMultiplier = 1.4;

/// Anlas per Precise Reference, per image.
const int preciseReferenceAnlas = 5;

/// Vibe transfers beyond this count cost extra.
const int freeVibeCount = 4;
const int extraVibeAnlas = 2;

class AnlasCost {
  /// Total Anlas the request will consume.
  final int anlas;

  /// True when Opus covers the request entirely.
  final bool isFreeUnderOpus;

  /// Cost of a single image before the Opus allowance.
  final int perImageAnlas;

  const AnlasCost({
    required this.anlas,
    required this.isFreeUnderOpus,
    required this.perImageAnlas,
  });
}

/// Whether a request falls inside the Opus free window.
bool fitsOpusFreeWindow({
  required int width,
  required int height,
  required int steps,
}) {
  return width * height <= opusFreeMaxArea && steps <= opusFreeMaxSteps;
}

/// Estimates the Anlas cost of one request.
///
/// [action] is 'generate', 'img2img' or 'infill'. [strength] is the img2img
/// strength or the inpaint `inpaintImg2ImgStrength`; it scales the cost.
/// [tier] is the subscription tier — pass null when unknown, which assumes
/// no Opus allowance.
AnlasCost estimateAnlasCost({
  required int width,
  required int height,
  required int steps,
  String action = 'generate',
  int nSamples = 1,
  double strength = 1.0,
  bool sm = false,
  bool smDyn = false,
  int? tier,
  bool subscriptionActive = false,
  int preciseReferenceCount = 0,
  int vibeCount = 0,
}) {
  final area = width * height;
  final smMultiplier = smDyn
      ? _smDynMultiplier
      : sm
          ? _smMultiplier
          : 1.0;
  final baseSteps =
      (_stepCoefficient * area + _stepPerStepCoefficient * area * steps)
              .ceil() *
          smMultiplier;
  final strengthMultiplier =
      (action == 'infill' || action == 'img2img') ? strength : 1.0;
  final perImage = max((baseSteps * strengthMultiplier).ceil(), 2);

  final free = subscriptionActive &&
      (tier ?? 0) >= opusTier &&
      fitsOpusFreeWindow(width: width, height: height, steps: steps);
  final freeImages = free ? 1 : 0;
  final int imageCost = perImage * max(nSamples - freeImages, 0);
  final int preciseCost =
      max(0, preciseReferenceCount) * preciseReferenceAnlas * nSamples;
  final int vibeCost =
      max(0, vibeCount - freeVibeCount) * extraVibeAnlas * nSamples;
  final int total = imageCost + preciseCost + vibeCost;

  return AnlasCost(
    anlas: total,
    isFreeUnderOpus: free && total == 0,
    perImageAnlas: perImage,
  );
}

/// Total cost of a multi-tile request, where each tile is its own request.
AnlasCost estimateBatchAnlasCost({
  required List<({int width, int height})> tiles,
  required int steps,
  String action = 'infill',
  double strength = 1.0,
  bool sm = false,
  bool smDyn = false,
  int? tier,
  bool subscriptionActive = false,
  int nSamples = 1,
}) {
  var total = 0;
  var allFree = tiles.isNotEmpty;
  var perImage = 0;
  for (final tile in tiles) {
    final cost = estimateAnlasCost(
      width: tile.width,
      height: tile.height,
      steps: steps,
      action: action,
      strength: strength,
      sm: sm,
      smDyn: smDyn,
      tier: tier,
      subscriptionActive: subscriptionActive,
      nSamples: nSamples,
    );
    total += cost.anlas;
    perImage = max(perImage, cost.perImageAnlas);
    if (!cost.isFreeUnderOpus) allFree = false;
  }
  return AnlasCost(
    anlas: total,
    isFreeUnderOpus: allFree && total == 0,
    perImageAnlas: perImage,
  );
}

/// Director Tools are billed per image, scaled by pixel count. Background
/// removal costs noticeably more than the rest and carries a flat base fee.
///
/// Measured against the live API (the docs do not publish these numbers):
/// bg-removal 384→14, 512→20, 1024→65; every other tool 512→5, 1024→20.
const int directorToolUnitPixels = 512 * 512;
const double directorToolAnlasPerUnit = 5;
const double bgRemovalAnlasPerUnit = 15;
const double bgRemovalBaseAnlas = 5;

/// Anlas a Director Tool run will consume. Unlike generation, Opus grants no
/// free allowance here.
int estimateDirectorToolAnlas({
  required String tool,
  required int width,
  required int height,
}) {
  if (width <= 0 || height <= 0) return 0;
  final units = (width * height) / directorToolUnitPixels;
  final raw = tool == 'bg-removal'
      ? bgRemovalBaseAnlas + bgRemovalAnlasPerUnit * units
      : directorToolAnlasPerUnit * units;
  return max(1, raw.ceil());
}
