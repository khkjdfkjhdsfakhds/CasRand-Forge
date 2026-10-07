import 'dart:convert';
import 'dart:typed_data';

import 'package:nai_casrand/data/models/generation_performance_diagnostics.dart';

class ApiResponse {
  final String status;
  final Uint8List data;
  final Map<String, String> headers;
  final DateTime? receivedAt;

  const ApiResponse({
    required this.status,
    required this.data,
    this.headers = const {},
    this.receivedAt,
  });
}

/// One part of a `multipart/form-data` request body.
///
/// Takoma rejects the JSON form of `/ai/augment-image` and expects the part
/// names its own client sends: a binary `image` part plus a JSON `request`
/// part whose `image` field names that binary part.
class ApiMultipartPart {
  final String field;
  final String? fileName;
  final String contentType;
  final Uint8List bytes;

  const ApiMultipartPart({
    required this.field,
    required this.bytes,
    this.fileName,
    this.contentType = 'application/octet-stream',
  });
}

/// A complete `multipart/form-data` body with a stable boundary.
class ApiMultipartBody {
  ApiMultipartBody({required List<ApiMultipartPart> parts, String? boundary})
      : parts = List.unmodifiable(parts),
        boundary = boundary ?? _nextBoundary();

  final List<ApiMultipartPart> parts;
  final String boundary;

  String get contentType => 'multipart/form-data; boundary=$boundary';

  static int _serial = 0;

  static String _nextBoundary() {
    _serial++;
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    // Lowercase alphanumeric only. Takoma's multipart parser answers HTTP 500
    // to any boundary that contains an uppercase letter, so the generated text
    // must stay in the base36 alphabet.
    return 'casrandformboundary$stamp${_serial.toRadixString(36)}';
  }

  /// Encodes every part with CRLF line endings and a trailing terminator.
  Uint8List encode() {
    final builder = BytesBuilder(copy: false);
    for (final part in parts) {
      final header = StringBuffer()
        ..write('--$boundary\r\n')
        ..write('Content-Disposition: form-data; name="${part.field}"');
      if (part.fileName != null) {
        header.write('; filename="${part.fileName}"');
      }
      header
        ..write('\r\n')
        ..write('Content-Type: ${part.contentType}\r\n\r\n');
      builder.add(utf8.encode(header.toString()));
      builder.add(part.bytes);
      builder.add(const <int>[13, 10]);
    }
    builder.add(utf8.encode('--$boundary--\r\n'));
    return builder.toBytes();
  }
}

class ApiRequest {
  final String endpoint;
  final String proxy;
  final Map<String, String> headers;
  final Map<String, dynamic> payload;

  /// When set, the request is sent as `multipart/form-data` and [payload] is
  /// ignored. Used by relays whose augment endpoint refuses JSON bodies.
  final ApiMultipartBody? multipart;
  final GenerationDiagnosticContext? diagnosticContext;

  /// Checked after asynchronous preparation and before every physical POST.
  /// Already-sent requests continue receiving their response when this is false.
  final bool Function()? shouldSend;

  const ApiRequest({
    required this.endpoint,
    required this.proxy,
    required this.headers,
    this.payload = const <String, dynamic>{},
    this.multipart,
    this.diagnosticContext,
    this.shouldSend,
  });
}
