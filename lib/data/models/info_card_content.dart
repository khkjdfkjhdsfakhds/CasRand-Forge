import 'dart:typed_data';

import 'package:nai_casrand/data/services/generated_image_storage.dart';
import 'package:nai_casrand/data/models/opus_usage.dart';

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

  /// Opus V5 generation allowance after this image. While settlement is in
  /// progress this is a projection of the most recent server snapshot.
  final OpusUsage? opusUsage;
  final bool opusUsageIsEstimated;
  final bool opusUsageSettling;

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
    this.opusUsage,
    this.opusUsageIsEstimated = false,
    this.opusUsageSettling = false,
  }) : _imageBytes = imageBytes;

  InfoCardContent copyWith({
    int? anlasCost,
    bool? anlasCostIsEstimated,
    int? anlasRemaining,
    int? batchAnlasCost,
    OpusUsage? opusUsage,
    bool? opusUsageIsEstimated,
    bool? opusUsageSettling,
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
      opusUsage: opusUsage ?? this.opusUsage,
      opusUsageIsEstimated: opusUsageIsEstimated ?? this.opusUsageIsEstimated,
      opusUsageSettling: opusUsageSettling ?? this.opusUsageSettling,
    );
  }

  factory InfoCardContent.fromEmpty() => const InfoCardContent(
        title: '',
        info: '',
        additionalInfo: {},
      );
}
