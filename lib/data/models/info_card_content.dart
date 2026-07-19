import 'dart:typed_data';

class InfoCardContent {
  final String title;
  final String info;
  final Map<String, dynamic> additionalInfo;

  final Uint8List? imageBytes;
  final String? imageFilePath;

  const InfoCardContent({
    required this.title,
    required this.info,
    required this.additionalInfo,
    this.imageBytes,
    this.imageFilePath,
  });

  factory InfoCardContent.fromEmpty() => const InfoCardContent(
        title: '',
        info: '',
        additionalInfo: {},
      );
}
