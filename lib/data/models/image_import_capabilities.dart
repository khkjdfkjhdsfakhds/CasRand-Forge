enum ImageImportAction {
  imageToImage,
  inpaint,
  vibeTransfer,
  preciseReference,
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
}
