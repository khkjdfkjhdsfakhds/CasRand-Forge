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

class ApiRequest {
  final String endpoint;
  final String proxy;
  final Map<String, String> headers;
  final Map<String, dynamic> payload;
  final GenerationDiagnosticContext? diagnosticContext;

  /// Checked after asynchronous preparation and before every physical POST.
  /// Already-sent requests continue receiving their response when this is false.
  final bool Function()? shouldSend;

  const ApiRequest({
    required this.endpoint,
    required this.proxy,
    required this.headers,
    required this.payload,
    this.diagnosticContext,
    this.shouldSend,
  });
}
