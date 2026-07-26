import 'dart:typed_data';

class InfoCardContent {
  final String title;
  final String info;
  final Map<String, dynamic> additionalInfo;

  final Uint8List? imageBytes;
  final String? imageFilePath;

  /// Anlas consumed by this generation (balance diff), null when unknown.
  final int? anlasCost;

  /// Anlas remaining on the token after this generation, null when unknown.
  final int? anlasRemaining;

  /// Label of the API token that produced this result (multi-token mode).
  final String? tokenLabel;

  const InfoCardContent({
    required this.title,
    required this.info,
    required this.additionalInfo,
    this.imageBytes,
    this.imageFilePath,
    this.anlasCost,
    this.anlasRemaining,
    this.tokenLabel,
  });

  factory InfoCardContent.fromEmpty() => const InfoCardContent(
        title: '',
        info: '',
        additionalInfo: {},
      );
}
