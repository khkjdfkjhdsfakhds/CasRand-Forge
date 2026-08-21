import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'image_service.dart';

/// The terminal result of an asynchronous PNG-to-JPEG conversion.
///
/// A transparent input is represented as a normal result with a
/// [transparencyUnsupported] status instead of being flattened or throwing.
enum GeneratedImageJpegEncodingStatus {
  encoded,
  transparencyUnsupported,
  invalidPng,
  metadataTooLarge,
  verificationFailed,
  failed,
}

/// Immutable data returned by [GeneratedImageJpegEncoder].
class GeneratedImageJpegEncodingResult {
  static const int jpegQuality = 92;
  static const int maxExifUserCommentBytes = 60000;

  const GeneratedImageJpegEncodingResult({
    required this.status,
    required this.jpegBytes,
    required this.width,
    required this.height,
    required this.hasTransparency,
    required this.metadataJson,
    this.errorMessage,
    this.performedInBackgroundIsolate = false,
    this.workerIsolateDebugName,
  });

  /// Convenience constructor for fakes and storage adapters that already
  /// completed an encoding operation.
  const GeneratedImageJpegEncodingResult.encoded({
    required Uint8List jpegBytes,
    required int width,
    required int height,
    String? metadataJson,
    bool hasTransparency = false,
    String? errorMessage,
    bool performedInBackgroundIsolate = false,
    String? workerIsolateDebugName,
  }) : this(
          status: GeneratedImageJpegEncodingStatus.encoded,
          jpegBytes: jpegBytes,
          width: width,
          height: height,
          hasTransparency: hasTransparency,
          metadataJson: metadataJson,
          errorMessage: errorMessage,
          performedInBackgroundIsolate: performedInBackgroundIsolate,
          workerIsolateDebugName: workerIsolateDebugName,
        );

  final GeneratedImageJpegEncodingStatus status;
  final Uint8List? jpegBytes;
  final int width;
  final int height;
  final bool hasTransparency;
  final String? metadataJson;
  final String? errorMessage;
  final bool performedInBackgroundIsolate;
  final String? workerIsolateDebugName;

  bool get isSuccess =>
      status == GeneratedImageJpegEncodingStatus.encoded && jpegBytes != null;
}

/// Public seam for injecting JPEG encoding into generated-image storage.
abstract interface class GeneratedImageJpegEncoder {
  Future<GeneratedImageJpegEncodingResult> encode(Uint8List pngBytes);
}

/// JPEG encoder that keeps decoding, metadata extraction, and encoding off the
/// caller isolate. The result is verified by decoding the candidate JPEG before
/// it is returned.
class IsolateGeneratedImageJpegEncoder implements GeneratedImageJpegEncoder {
  const IsolateGeneratedImageJpegEncoder();

  @override
  Future<GeneratedImageJpegEncodingResult> encode(Uint8List pngBytes) async {
    final raw = await Isolate.run<Map<String, Object?>>(
      () => _encodePngInBackground(pngBytes),
    );
    return _resultFromRaw(raw);
  }
}

GeneratedImageJpegEncodingResult _resultFromRaw(Map<String, Object?> raw) {
  final bytes = raw['jpegBytes'];
  return GeneratedImageJpegEncodingResult(
    status: GeneratedImageJpegEncodingStatus.values[raw['status']! as int],
    jpegBytes: bytes is Uint8List
        ? bytes
        : bytes is List<int>
            ? Uint8List.fromList(bytes)
            : null,
    width: raw['width']! as int,
    height: raw['height']! as int,
    hasTransparency: raw['hasTransparency']! as bool,
    metadataJson: raw['metadataJson'] as String?,
    errorMessage: raw['errorMessage'] as String?,
    performedInBackgroundIsolate:
        raw['performedInBackgroundIsolate'] as bool? ?? false,
    workerIsolateDebugName: raw['workerIsolateDebugName'] as String?,
  );
}

Future<Map<String, Object?>> _encodePngInBackground(Uint8List pngBytes) async {
  final workerDebugName = Isolate.current.debugName;
  try {
    final image = img.decodePng(pngBytes);
    if (image == null) {
      return _rawResult(
        status: GeneratedImageJpegEncodingStatus.invalidPng,
        width: 0,
        height: 0,
        hasTransparency: false,
        errorMessage: 'Input bytes are not a readable PNG.',
        workerDebugName: workerDebugName,
      );
    }

    final metadataJson = await _extractCompactMetadata(image);
    final hasTransparency = _hasVisibleTransparency(image);
    if (hasTransparency) {
      return _rawResult(
        status: GeneratedImageJpegEncodingStatus.transparencyUnsupported,
        width: image.width,
        height: image.height,
        hasTransparency: true,
        metadataJson: metadataJson,
        errorMessage:
            'transparent PNG cannot be converted to JPEG without flattening.',
        workerDebugName: workerDebugName,
      );
    }

    if (metadataJson != null &&
        utf8.encode(metadataJson).length >
            GeneratedImageJpegEncodingResult.maxExifUserCommentBytes) {
      return _rawResult(
        status: GeneratedImageJpegEncodingStatus.metadataTooLarge,
        width: image.width,
        height: image.height,
        hasTransparency: false,
        metadataJson: metadataJson,
        errorMessage: 'NovelAI metadata exceeds the JPEG EXIF size limit.',
        workerDebugName: workerDebugName,
      );
    }

    final exif = img.ExifData();
    if (metadataJson != null) {
      final decoded = jsonDecode(metadataJson);
      if (decoded is Map<String, dynamic>) {
        // EXIF UserComment values start with an 8-byte charset code.
        // NovelAI's website parses JPEG metadata with a standards-compliant
        // EXIF reader (exifr) and reports the field as "Undefined" when this
        // prefix is missing, so the raw JSON must be written after the
        // standard "ASCII\0\0\0" marker.
        exif.exifIfd.userComment = _exifAsciiUserComment(metadataJson);
        exif.imageIfd.imageDescription =
            _asciiExifString(_stringField(decoded['Description']));
        exif.imageIfd.software =
            _asciiExifString(_stringField(decoded['Software']));
      }
    }
    image.exif = exif;

    final jpeg = img.encodeJpg(
      image,
      quality: GeneratedImageJpegEncodingResult.jpegQuality,
      chroma: img.JpegChroma.yuv444,
    );
    final jpegBytes = Uint8List.fromList(jpeg);

    final reopened = img.decodeJpg(jpegBytes);
    if (reopened == null ||
        reopened.width != image.width ||
        reopened.height != image.height) {
      return _rawResult(
        status: GeneratedImageJpegEncodingStatus.verificationFailed,
        width: image.width,
        height: image.height,
        hasTransparency: false,
        metadataJson: metadataJson,
        errorMessage: 'Encoded JPEG could not be decoded at the source size.',
        workerDebugName: workerDebugName,
      );
    }
    if (metadataJson != null) {
      final reopenedExif = img.decodeJpgExif(jpegBytes);
      if (reopenedExif?.exifIfd.userComment !=
              _exifAsciiUserComment(metadataJson) ||
          reopenedExif?.imageIfd.imageDescription !=
              _descriptionFromMetadata(metadataJson) ||
          reopenedExif?.imageIfd.software !=
              _softwareFromMetadata(metadataJson)) {
        return _rawResult(
          status: GeneratedImageJpegEncodingStatus.verificationFailed,
          width: image.width,
          height: image.height,
          hasTransparency: false,
          metadataJson: metadataJson,
          errorMessage:
              'JPEG NovelAI EXIF metadata failed round-trip verification.',
          workerDebugName: workerDebugName,
        );
      }
    }

    return _rawResult(
      status: GeneratedImageJpegEncodingStatus.encoded,
      jpegBytes: jpegBytes,
      width: image.width,
      height: image.height,
      hasTransparency: false,
      metadataJson: metadataJson,
      workerDebugName: workerDebugName,
    );
  } catch (error) {
    return _rawResult(
      status: GeneratedImageJpegEncodingStatus.failed,
      width: 0,
      height: 0,
      hasTransparency: false,
      errorMessage: '$error',
      workerDebugName: workerDebugName,
    );
  }
}

Map<String, Object?> _rawResult({
  required GeneratedImageJpegEncodingStatus status,
  required int width,
  required int height,
  required bool hasTransparency,
  String? metadataJson,
  Uint8List? jpegBytes,
  String? errorMessage,
  String? workerDebugName,
}) =>
    {
      'status': status.index,
      'jpegBytes': jpegBytes,
      'width': width,
      'height': height,
      'hasTransparency': hasTransparency,
      'metadataJson': metadataJson,
      'errorMessage': errorMessage,
      'performedInBackgroundIsolate': true,
      'workerIsolateDebugName': workerDebugName,
    };

bool _hasVisibleTransparency(img.Image image) {
  if (!image.hasAlpha) return false;
  for (final pixel in image) {
    // NovelAI stealth metadata may use an alpha value of 254 for an opaque
    // pixel. Treat that established representation as effectively opaque.
    if (pixel.a.toInt() < 254) return true;
  }
  return false;
}

Future<String?> _extractCompactMetadata(img.Image image) async {
  final raw = await ImageService().extractMetadata(image);
  if (raw == null || raw.trim().isEmpty) return null;
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return null;
  return _compactAsciiJson(decoded);
}

String? _stringField(Object? value) => value is String ? value : null;

/// The EXIF UserComment charset marker required by the specification and by
/// NovelAI's official JPEG metadata reader.
const String _exifUserCommentAsciiPrefix = 'ASCII\u0000\u0000\u0000';

String _exifAsciiUserComment(String metadataJson) =>
    '$_exifUserCommentAsciiPrefix$metadataJson';

String? _asciiExifString(String? value) =>
    value == null ? null : _escapeNonAscii(value);

String _descriptionFromMetadata(String metadataJson) {
  final decoded = jsonDecode(metadataJson);
  return _asciiExifString(
        _stringField(decoded is Map ? decoded['Description'] : null),
      ) ??
      '';
}

String _softwareFromMetadata(String metadataJson) {
  final decoded = jsonDecode(metadataJson);
  return _asciiExifString(
        _stringField(decoded is Map ? decoded['Software'] : null),
      ) ??
      '';
}

String _compactAsciiJson(Object? value) {
  final compact = jsonEncode(value);
  return _escapeNonAscii(compact);
}

String _escapeNonAscii(String value) {
  final output = StringBuffer();
  for (final codePoint in value.runes) {
    if (codePoint <= 0x7f) {
      output.writeCharCode(codePoint);
    } else if (codePoint <= 0xffff) {
      output.write('\\u${codePoint.toRadixString(16).padLeft(4, '0')}');
    } else {
      final scalar = codePoint - 0x10000;
      final high = 0xd800 + (scalar >> 10);
      final low = 0xdc00 + (scalar & 0x3ff);
      output
        ..write('\\u${high.toRadixString(16).padLeft(4, '0')}')
        ..write('\\u${low.toRadixString(16).padLeft(4, '0')}');
    }
  }
  return output.toString();
}
