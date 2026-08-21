import 'dart:typed_data';

import 'package:nai_casrand/data/services/generated_image_storage.dart';

class InfoCardContent {
  final String title;
  final String info;
  final Map<String, dynamic> additionalInfo;

  final Uint8List? _imageBytes;
  final GeneratedImageArtifact? imageArtifact;

  Uint8List? get imageBytes => imageArtifact?.previewBytes ?? _imageBytes;
  GeneratedImageFile? get currentImageFile => imageArtifact?.currentFile;
  GeneratedImageFile? get originalImageFile => imageArtifact?.originalPngFile;

  /// Anlas consumed by this generation, exact or locally estimated.
  final int? anlasCost;

  /// Whether [anlasCost] comes from the local NovelAI pricing formula rather
  /// than a completed balance reconciliation.
  final bool anlasCostIsEstimated;

  /// Anlas remaining on the token after this generation, null when unknown.
  final int? anlasRemaining;

  /// Exact total consumed by the completed batch for this token. This is
  /// attached to the last result after the background balance refresh.
  final int? batchAnlasCost;

  /// Label of the API token that produced this result (multi-token mode).
  final String? tokenLabel;

  const InfoCardContent({
    required this.title,
    required this.info,
    required this.additionalInfo,
    Uint8List? imageBytes,
    this.imageArtifact,
    this.anlasCost,
    this.anlasCostIsEstimated = false,
    this.anlasRemaining,
    this.batchAnlasCost,
    this.tokenLabel,
  }) : _imageBytes = imageBytes;

  InfoCardContent copyWith({
    int? anlasCost,
    bool? anlasCostIsEstimated,
    int? anlasRemaining,
    int? batchAnlasCost,
  }) {
    return InfoCardContent(
      title: title,
      info: info,
      additionalInfo: additionalInfo,
      imageBytes: _imageBytes,
      imageArtifact: imageArtifact,
      anlasCost: anlasCost ?? this.anlasCost,
      anlasCostIsEstimated: anlasCostIsEstimated ?? this.anlasCostIsEstimated,
      anlasRemaining: anlasRemaining ?? this.anlasRemaining,
      batchAnlasCost: batchAnlasCost ?? this.batchAnlasCost,
      tokenLabel: tokenLabel,
    );
  }

  factory InfoCardContent.fromEmpty() => const InfoCardContent(
        title: '',
        info: '',
        additionalInfo: {},
      );
}
