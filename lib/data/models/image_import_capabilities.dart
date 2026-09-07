enum ImageImportAction {
  imageToImage,
  inpaint,
  vibeTransfer,
  preciseReference,
}

class GenerationReferenceUsage {
  final bool usesLegacyVibes;
  final bool usesModernVibes;
  final bool usesPreciseReferences;
  final int vibeCount;
  final int preciseReferenceCount;

  const GenerationReferenceUsage({
    required this.usesLegacyVibes,
    required this.usesModernVibes,
    required this.usesPreciseReferences,
    required this.vibeCount,
    required this.preciseReferenceCount,
  });

  static const none = GenerationReferenceUsage(
    usesLegacyVibes: false,
    usesModernVibes: false,
    usesPreciseReferences: false,
    vibeCount: 0,
    preciseReferenceCount: 0,
  );
}

/// The image-import actions supported by one NovelAI generation model.
///
/// UI surfaces and request preparation should use this authority instead of
/// repeating model-name checks, so an action is never offered when generation
/// cannot consume it.
class ImageImportCapabilities {
  final Set<ImageImportAction> actions;
  final bool isV4Family;
  final bool isV5Family;

  const ImageImportCapabilities._(
    this.actions, {
    required this.isV4Family,
    required this.isV5Family,
  });

  factory ImageImportCapabilities.forModel(String model) {
    final isV5 = model.startsWith('nai-diffusion-5-');
    final isV45 = model.startsWith('nai-diffusion-4-5-');
    return ImageImportCapabilities._(
      Set.unmodifiable({
        ImageImportAction.imageToImage,
        ImageImportAction.inpaint,
        if (!isV5) ImageImportAction.vibeTransfer,
        if (isV45) ImageImportAction.preciseReference,
      }),
      isV4Family: model.startsWith('nai-diffusion-4-'),
      isV5Family: isV5,
    );
  }

  bool supports(ImageImportAction action) => actions.contains(action);

  bool get usesLegacyVibe =>
      supports(ImageImportAction.vibeTransfer) && !isV4Family;

  GenerationReferenceUsage resolveReferenceUsage({
    required bool vibeEnabled,
    required bool preciseReferenceEnabled,
    required int legacyVibeCount,
    required int modernVibeCount,
    required int preciseReferenceCount,
  }) {
    if (usesLegacyVibe && vibeEnabled && legacyVibeCount > 0) {
      return GenerationReferenceUsage(
        usesLegacyVibes: true,
        usesModernVibes: false,
        usesPreciseReferences: false,
        vibeCount: legacyVibeCount,
        preciseReferenceCount: 0,
      );
    }
    if (supports(ImageImportAction.preciseReference) &&
        preciseReferenceEnabled &&
        preciseReferenceCount > 0) {
      return GenerationReferenceUsage(
        usesLegacyVibes: false,
        usesModernVibes: false,
        usesPreciseReferences: true,
        vibeCount: 0,
        preciseReferenceCount: preciseReferenceCount,
      );
    }
    if (supports(ImageImportAction.vibeTransfer) &&
        vibeEnabled &&
        modernVibeCount > 0) {
      return GenerationReferenceUsage(
        usesLegacyVibes: false,
        usesModernVibes: true,
        usesPreciseReferences: false,
        vibeCount: modernVibeCount,
        preciseReferenceCount: 0,
      );
    }
    return GenerationReferenceUsage.none;
  }
}
