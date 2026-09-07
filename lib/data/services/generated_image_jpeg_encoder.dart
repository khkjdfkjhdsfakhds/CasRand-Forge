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

    final metadataJson = await _extractCompactMetadata(image, pngBytes);
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
    final jpegBytes = metadataJson == null
        ? Uint8List.fromList(jpeg)
        : _addCompatibilityMetadata(
            Uint8List.fromList(jpeg),
            jsonDecode(metadataJson),
          );

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
          (reopenedExif?.imageIfd.imageDescription ?? '') !=
              _descriptionFromMetadata(metadataJson) ||
          (reopenedExif?.imageIfd.software ?? '') !=
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

Future<String?> _extractCompactMetadata(
  img.Image image,
  Uint8List pngBytes,
) async {
  String? stealthMetadata;
  try {
    stealthMetadata = await ImageService().extractMetadata(image);
  } catch (_) {
    // A damaged optional stealth channel must not hide valid PNG text data.
  }

  final candidates = <String?>[
    stealthMetadata,
    extractNovelAiMetadataFromPngText(pngBytes),
  ];
  for (final metadata in candidates) {
    if (metadata == null || metadata.trim().isEmpty) continue;
    final decoded = _parseNovelAiMetadataCandidate(metadata);
    if (decoded != null) return _compactAsciiJson(decoded);
  }
  return null;
}

Map<String, dynamic>? _parseNovelAiMetadataCandidate(String metadata) {
  try {
    final decoded = jsonDecode(metadata);
    if (decoded is! Map<String, dynamic>) return null;
    return isNovelAiGenerationMetadata(decoded) ? decoded : null;
  } catch (_) {
    // Try the other metadata carrier before treating metadata as absent.
    return null;
  }
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

/// Adds the metadata mirrors used by generic image readers. The complete
/// NovelAI bundle remains in EXIF UserComment; XMP/IPTC only carry searchable
/// descriptive fields so no reader has to reconstruct the generation JSON.
Uint8List _addCompatibilityMetadata(
  Uint8List jpeg,
  Object? decodedMetadata,
) {
  if (decodedMetadata is! Map) return jpeg;
  final title = _stringField(decodedMetadata['Title']) ?? '';
  final description = _stringField(decodedMetadata['Description']) ?? '';
  final software = _stringField(decodedMetadata['Software']) ?? 'NovelAI';
  final source = _stringField(decodedMetadata['Source']) ?? software;
  final comment = _stringField(decodedMetadata['Comment']) ?? '';
  final negativePrompt = _negativePrompt(comment);
  final compatibilityFields = _fitXmpFields({
    'title': _truncateForCompatibility(title),
    'description': _truncateForCompatibility(description),
    'software': _truncateForCompatibility(software),
    'source': _truncateForCompatibility(source),
    'negativePrompt': _truncateForCompatibility(negativePrompt),
  });
  final iptcFields = _fitIptcFields({
    'title': _truncateForCompatibility(title),
    'description': _truncateForCompatibility(description),
    'source': _truncateForCompatibility(source),
    'negativePrompt': _truncateForCompatibility(negativePrompt),
  });
  final xmp = _xmpPacket(
    title: compatibilityFields['title']!,
    description: compatibilityFields['description']!,
    software: compatibilityFields['software']!,
    source: compatibilityFields['source']!,
    negativePrompt: compatibilityFields['negativePrompt']!,
  );
  final iptc = _iptcResource(
    title: iptcFields['title']!,
    description: iptcFields['description']!,
    source: iptcFields['source']!,
    negativePrompt: iptcFields['negativePrompt']!,
  );
  return _insertJpegSegments(jpeg, [
    _jpegAppSegment(0xe1, <int>[
      ...utf8.encode('http://ns.adobe.com/xap/1.0/\u0000'),
      ...utf8.encode(xmp),
    ]),
    _jpegAppSegment(0xed, iptc),
  ]);
}

String _truncateForCompatibility(String value) {
  const maxBytes = 12000;
  return _truncateUtf8(value, maxBytes);
}

String _truncateUtf8(String value, int maxBytes) {
  final bytes = utf8.encode(value);
  if (bytes.length <= maxBytes) return value;
  var end = maxBytes;
  while (end > 0) {
    try {
      return utf8.decode(bytes.sublist(0, end), allowMalformed: false);
    } on FormatException {
      end--;
    }
  }
  return '';
}

Map<String, String> _fitXmpFields(Map<String, String> fields) {
  var fitted = Map<String, String>.from(fields);
  const xmpIdentifier = 'http://ns.adobe.com/xap/1.0/\u0000';
  const maxAppPayloadBytes = 0xffff - 2;
  for (var attempt = 0; attempt < 32; attempt++) {
    final packet = _xmpPacket(
      title: fitted['title']!,
      description: fitted['description']!,
      software: fitted['software']!,
      source: fitted['source']!,
      negativePrompt: fitted['negativePrompt']!,
    );
    final packetBytes =
        utf8.encode(xmpIdentifier).length + utf8.encode(packet).length;
    if (packetBytes <= maxAppPayloadBytes) return fitted;

    final previous = fitted;
    fitted = {
      for (final entry in previous.entries)
        entry.key: _truncateUtf8(
            entry.value, (utf8.encode(entry.value).length * 3) ~/ 4)
    };
    if (fitted.entries.every((entry) => entry.value == previous[entry.key])) {
      break;
    }
  }

  // The fixed XMP packet is comfortably below the segment limit; this
  // fallback makes that guarantee explicit if the fields were pathological.
  return {
    for (final entry in fitted.entries) entry.key: '',
  };
}

Map<String, String> _fitIptcFields(Map<String, String> fields) {
  var fitted = Map<String, String>.from(fields);
  const maxAppPayloadBytes = 0xffff - 2;
  for (var attempt = 0; attempt < 32; attempt++) {
    final payload = _iptcResource(
      title: fitted['title']!,
      description: fitted['description']!,
      source: fitted['source']!,
      negativePrompt: fitted['negativePrompt']!,
    );
    if (payload.length <= maxAppPayloadBytes) return fitted;

    final previous = fitted;
    fitted = {
      for (final entry in previous.entries)
        entry.key: _truncateUtf8(
            entry.value, (utf8.encode(entry.value).length * 3) ~/ 4)
    };
    if (fitted.entries.every((entry) => entry.value == previous[entry.key])) {
      break;
    }
  }
  return {
    for (final entry in fitted.entries) entry.key: '',
  };
}

String _negativePrompt(String comment) {
  try {
    final value = jsonDecode(comment);
    if (value is! Map) return '';
    final direct = value['negative_prompt'];
    if (direct is String) return direct;
    for (final key in const ['v4_negative_prompt', 'negative_prompt']) {
      final nested = value[key];
      if (nested is Map) {
        final caption = nested['caption'];
        if (caption is Map && caption['base_caption'] is String) {
          return caption['base_caption'] as String;
        }
      }
    }
  } catch (_) {
    // Metadata remains valid even when the optional negative prompt is absent.
  }
  return '';
}

String _xmlEscape(String value) {
  final output = StringBuffer();
  for (final codePoint in value.runes) {
    // XML 1.0 excludes most C0 controls. The authoritative JSON remains
    // untouched; only the best-effort XMP mirror drops invalid XML scalars.
    final valid = codePoint == 0x9 ||
        codePoint == 0xa ||
        codePoint == 0xd ||
        (codePoint >= 0x20 && codePoint <= 0xd7ff) ||
        (codePoint >= 0xe000 && codePoint <= 0xfffd) ||
        (codePoint >= 0x10000 && codePoint <= 0x10ffff);
    if (!valid) continue;
    switch (codePoint) {
      case 0x26:
        output.write('&amp;');
      case 0x3c:
        output.write('&lt;');
      case 0x3e:
        output.write('&gt;');
      case 0x22:
        output.write('&quot;');
      case 0x27:
        output.write('&apos;');
      default:
        output.writeCharCode(codePoint);
    }
  }
  return output.toString();
}

String _xmpPacket({
  required String title,
  required String description,
  required String software,
  required String source,
  required String negativePrompt,
}) {
  final safeTitle = _xmlEscape(title);
  final safeDescription = _xmlEscape(description);
  final safeSoftware = _xmlEscape(software);
  final safeSource = _xmlEscape(source);
  final safeNegative = _xmlEscape(negativePrompt);
  return '''<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" rdf:about="">
<dc:title><rdf:Alt><rdf:li xml:lang="x-default">$safeTitle</rdf:li></rdf:Alt></dc:title>
<dc:description><rdf:Alt><rdf:li xml:lang="x-default">$safeDescription</rdf:li></rdf:Alt></dc:description>
<xmp:CreatorTool>$safeSoftware</xmp:CreatorTool>
<photoshop:Source>$safeSource</photoshop:Source>
<photoshop:Instructions>$safeNegative</photoshop:Instructions>
</rdf:Description>
</rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>''';
}

List<int> _iptcResource({
  required String title,
  required String description,
  required String source,
  required String negativePrompt,
}) {
  final datasets = <int>[];
  void add(int dataset, String value) {
    final bytes = utf8.encode(value);
    if (bytes.isEmpty || bytes.length > 0x7fff) return;
    datasets
      ..add(0x1c)
      ..add(2)
      ..add(dataset)
      ..add((bytes.length >> 8) & 0xff)
      ..add(bytes.length & 0xff)
      ..addAll(bytes);
  }

  // IPTC record 1:90 declares UTF-8; record 2 mirrors common caption fields.
  datasets.addAll([0x1c, 1, 90, 0, 3, 0x1b, 0x25, 0x47]);
  add(5, title);
  add(115, source);
  add(120, description);
  add(40, negativePrompt);

  final resource = <int>[0x38, 0x42, 0x49, 0x4d, 0x04, 0x04, 0, 0];
  resource
    ..add((datasets.length >> 24) & 0xff)
    ..add((datasets.length >> 16) & 0xff)
    ..add((datasets.length >> 8) & 0xff)
    ..add(datasets.length & 0xff)
    ..addAll(datasets);
  if (datasets.length.isOdd) resource.add(0);
  return <int>[...utf8.encode('Photoshop 3.0\u0000'), ...resource];
}

List<int> _jpegAppSegment(int marker, List<int> payload) {
  final length = payload.length + 2;
  if (length > 0xffff) {
    throw StateError('JPEG metadata segment exceeds the JPEG limit.');
  }
  return <int>[
    0xff,
    marker,
    (length >> 8) & 0xff,
    length & 0xff,
    ...payload,
  ];
}

Uint8List _insertJpegSegments(Uint8List jpeg, List<List<int>> segments) {
  final bytes = <int>[0xff, 0xd8];
  for (final segment in segments) {
    bytes.addAll(segment);
  }
  bytes.addAll(jpeg.skip(2));
  return Uint8List.fromList(bytes);
}
